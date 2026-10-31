#!/bin/sh
# 构建内嵌 FB-SDK 的 gt-auto（bin/gt-auto-fcounter）并安装到 ~/go/bin，
# 供本仓 e2e_gt_auto.sh 在无 gt-auto 检出的环境经 PATH 直接使用
#（也可用 GT_AUTO_BIN 显式指定二进制）。
#
# 用法：
#   scripts/install_gt_auto.sh                                      # gt-auto 同级检出时
#   GT_AUTO_DIR=$HOME/workspace/gt-auto scripts/install_gt_auto.sh  # 检出在别处时
#
# 环境变量：GT_AUTO_DIR（默认 ../gt-auto）、FBSDK_DIR（默认 ../fbsdk）、
#           GT_AUTO_INSTALL_DIR（默认 ~/go/bin）。
# 注意：二进制动态链接 fbsdk-ffi cdylib 并记录其路径——fbsdk 检出移动后须重装。
set -eu
cd "$(dirname "$0")/.."

GT_AUTO_DIR=${GT_AUTO_DIR:-../gt-auto}
FBSDK_DIR=${FBSDK_DIR:-../fbsdk}
INSTALL_DIR=${GT_AUTO_INSTALL_DIR:-$HOME/go/bin}
for d in "$GT_AUTO_DIR" "$FBSDK_DIR"; do
    [ -d "$d" ] || { echo "缺少检出：${d}（可用 GT_AUTO_DIR / FBSDK_DIR 覆盖）" >&2; exit 1; }
done
GT_AUTO_DIR=$(cd "$GT_AUTO_DIR" && pwd)
FBSDK_DIR=$(cd "$FBSDK_DIR" && pwd)
CGO_LDFLAGS_FBS="-L$FBSDK_DIR/target/release -Wl,-rpath,$FBSDK_DIR/target/release"

build_binary() {
    (cd "$GT_AUTO_DIR" && CGO_ENABLED=1 CGO_LDFLAGS="$CGO_LDFLAGS_FBS" \
        go build -tags fbsdk -o bin/gt-auto-fcounter ./cmd/gt-auto)
}

echo "=== 1/3 构建 fbsdk-ffi cdylib ==="
(cd "$FBSDK_DIR" && cargo build -p fbsdk-ffi --release)

# 陈旧 install_name 守卫（同 e2e_gt_auto.sh；仅 macOS，ELF 用 SONAME 不受影响）。
# 必须在 go 链接**之前**完成——二进制会把当时读到的 install_name 烘焙进去。
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

echo "=== 2/3 构建 gt-auto-fcounter（-tags fbsdk，检出：${GT_AUTO_DIR}）==="
build_binary

echo "=== 3/3 安装到 $INSTALL_DIR ==="
mkdir -p "$INSTALL_DIR"
cp "$GT_AUTO_DIR/bin/gt-auto-fcounter" "$INSTALL_DIR/"
echo "已安装：$INSTALL_DIR/gt-auto-fcounter"
command -v gt-auto-fcounter >/dev/null 2>&1 || \
    echo "提示：$INSTALL_DIR 不在 PATH 中——将其加入 PATH，或运行验收时以 GT_AUTO_BIN=$INSTALL_DIR/gt-auto-fcounter 指定"
