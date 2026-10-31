#!/bin/sh
# gt-auto × fbsdk × fcounter 全链路自动化验收（沪 + 深两市场）
#
# 拓扑（每市场一轮）：
#   gt-auto fbsdk 模拟器(真实 Go SDK, cgo) --> fcounter ingress
#   fcounter counter-gw-sse/szse ---------> gt-auto 交易所侧（会话自动应答）
#
# 用例（本仓 e2e/gtauto/ 维护——柜台的发布验收标准，2026-10 自 fcounter 仓迁入）：
#   沪：SDK 发单 -> 交易所收单校验 -> 交易所回受理确认+成交 -> SDK 逐字段校验；撤单拒绝
#   深：同构（SZSE 二进制协议，字段映射独立）
#
# 前置：本仓与 ../fcounter、../fbsdk、../gt-auto 同级检出；Rust + Go 工具链；
#       私有仓 git 凭证（fcounter 构建经 git tag 拉取 fcp / fbsdk）。
# 环境变量：FCOUNTER_DIR / GT_AUTO_DIR / FBSDK_DIR（默认同级检出，可整体覆盖）、
#           E2E_KEEP=1 保留临时工作目录（失败排查/CI 上传报告用）。
set -eu
cd "$(dirname "$0")/.."

FCOUNTER_DIR=${FCOUNTER_DIR:-../fcounter}
GT_AUTO_DIR=${GT_AUTO_DIR:-../gt-auto}
FBSDK_DIR=${FBSDK_DIR:-../fbsdk}
# 统一解析为绝对路径：后续子壳会 cd 进各仓，相对路径会从错误基准解析；
# 缺失检出在此 fail-fast 并给出可操作的提示
for d in "$FCOUNTER_DIR" "$GT_AUTO_DIR" "$FBSDK_DIR"; do
    [ -d "$d" ] || { echo "缺少同级检出：${d}（可用 FCOUNTER_DIR / GT_AUTO_DIR / FBSDK_DIR 覆盖）" >&2; exit 1; }
done
FCOUNTER_DIR=$(cd "$FCOUNTER_DIR" && pwd)
GT_AUTO_DIR=$(cd "$GT_AUTO_DIR" && pwd)
FBSDK_DIR=$(cd "$FBSDK_DIR" && pwd)
E2E_DIR=$PWD  # 用例由本仓维护（e2e/gtauto/）；子壳 cd 后 PWD 会变
WORK=$(mktemp -d /tmp/fcounter-gtauto.XXXXXX)
trap 'kill ${APP_PID:-0} 2>/dev/null || true; [ -n "${E2E_KEEP:-}" ] || rm -rf "$WORK"' EXIT

echo "=== 1/4 构建 fcounter-app ==="
(cd "$FCOUNTER_DIR" && cargo build --release -p counter-app)

echo "=== 2/4 构建 fbsdk-ffi cdylib ==="
(cd "$FBSDK_DIR" && cargo build -p fbsdk-ffi --release)

# 陈旧 install_name 守卫（仅 macOS；Linux 的 ELF NEEDED 用 SONAME 不受影响）：
# cdylib 把构建时的绝对路径烘焙进 install_name，检出目录若在构建后移动过，
# cargo 缓存产物仍指向旧路径，cgo 链接出的二进制运行期 dyld 必炸且报错点
# 离病因极远——对拍后强制重链。
DYLIB="$FBSDK_DIR/target/release/libfbsdk_ffi.dylib"
if [ "$(uname)" = "Darwin" ] && [ -f "$DYLIB" ]; then
    INSTALL_NAME=$(otool -D "$DYLIB" 2>/dev/null | sed -n '2p')
    case "$INSTALL_NAME" in
        "$FBSDK_DIR"/target/release/deps/*) ;;  # 指向本检出，正常
        "")
        ;;
        *)
            echo "cdylib install_name 指向旧检出路径（${INSTALL_NAME}），强制重链"
            (cd "$FBSDK_DIR" && cargo clean -p fbsdk-ffi --release && cargo build -p fbsdk-ffi --release)
            ;;
    esac
fi

echo "=== 3/4 构建 gt-auto（-tags fbsdk）==="
# cgo 链接需 fbsdk-ffi cdylib 的路径（模块缓存内不含 Rust 产物）。
# -rpath 随检出路径进入链接输入：检出搬过位置时 go 构建缓存必然失效重链，
# 否则陈旧二进制会一直引用旧 install_name（go 缓存不感知 dylib 变化）。
(cd "$GT_AUTO_DIR" && CGO_ENABLED=1 \
    CGO_LDFLAGS="-L$FBSDK_DIR/target/release -Wl,-rpath,$FBSDK_DIR/target/release" \
    go build -tags fbsdk -o bin/gt-auto-fcounter ./cmd/gt-auto)

# run_market <标签> <交易所 sse|szse> <gt-auto 监听口> <gt-auto 配置> <用例>
run_market() {
    tag=$1; exch=$2; gt_port=$3; gt_conf=$4; gt_case=$5
    echo "--- [$tag] 启动柜台（gw=${exch}）---"
    cat > "$WORK/counter-$tag.conf" <<CFG
[app]
duration_ms = 0
[ingress]
bind = 127.0.0.1:19401
bindings = 1:1:A123456789
[gw]
exchange = $exch
addr = 127.0.0.1:$gt_port
account = 10002
biz_pbu = 00001
heart_bt_int = 30
[core]
initial_cash = 1000000000000
securities = 600519:100:100:18700000:15300000:0
[wal]
path = $WORK/counter-$tag.wal
CFG

    "$FCOUNTER_DIR/target/release/counter-app" --config "$WORK/counter-$tag.conf" \
        >"$WORK/counter-$tag.out" 2>"$WORK/counter-$tag.err" &
    APP_PID=$!
    for _ in $(seq 1 50); do
        grep -q "M4 启动" "$WORK/counter-$tag.out" 2>/dev/null && break
        sleep 0.1
    done

    RC=0
    (cd "$GT_AUTO_DIR" && ./bin/gt-auto-fcounter \
        --casePath "$E2E_DIR/e2e/gtauto/$gt_case" \
        --config   "$E2E_DIR/e2e/gtauto/$gt_conf" \
        --report   "$WORK/gtauto-report-$tag.json") || RC=$?

    # 停机确定性：TERM -> 2s 宽限 -> KILL（counter 热线程为忙轮询设计，必须确保退出）
    kill "$APP_PID" 2>/dev/null || true
    for _ in $(seq 1 20); do
        kill -0 "$APP_PID" 2>/dev/null || break
        sleep 0.1
    done
    kill -9 "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true

    if [ "$RC" != "0" ]; then
        echo "[$tag] 失败；柜台日志：$WORK/counter-$tag.err；报告：$WORK/gtauto-report-$tag.json" >&2
        return 1
    fi
    echo "[$tag] 验收通过"
}

echo "=== 4/4 两市场验收 ==="
TOTAL=0
run_market sse  sse  19301 gw-auto-fcounter.toml      fcounter_test_case.csv      || TOTAL=1
run_market szse szse 19302 gw-auto-fcounter-szse.toml fcounter_szse_test_case.csv || TOTAL=1

if [ "$TOTAL" = "0" ]; then
    echo "GT-AUTO 全链路验收（沪+深）：PASS"
else
    echo "GT-AUTO 全链路验收：FAIL" >&2
fi
exit "$TOTAL"
