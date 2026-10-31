# fc-e2e — fcounter 全链路验收

基于 [gt-auto](https://github.com/xinchentechnote/gt-auto) 的跨仓端到端测试仓：
以**真实 Go SDK 绑定**（cgo → [fbsdk](https://github.com/xinchentechnote/fbsdk) 的
`fbsdk-ffi` cdylib）驱动 [fcounter](https://github.com/xinchentechnote/fcounter)，
对沪深两市场主链路做消息级黑盒验收。

被测系统（fbsdk / fcounter）与测试工具（gt-auto）各自独立演进，发布验收标准
（用例权威副本 + 编排脚本）收拢在本仓——验收不随任一被测仓的构建/CI 布局变化。

## 覆盖

沪（SSE Binary）与深（SZSE Binary）同构各一轮，每轮两用例：

| 用例 | 步骤 |
|---|---|
| 下单全链路 | SDK 发单 → 交易所收单逐字段校验 → 交易所回受理确认 + 成交回报 → SDK 逐字段校验 |
| 撤单拒绝 | SDK 撤未知订单 → SDK 收撤单拒绝（0x0020） |

隐含契约：受理确认先行、回报序号连续分配、OrdType/ClOrdID 双市场映射。

## 布局

| 路径 | 内容 |
|---|---|
| `e2e/gtauto/` | 验收用例权威副本：CSV 用例 + 模拟器编排 TOML（沪/深各一套，2026-10 自 fcounter 仓迁入） |
| `scripts/e2e_gt_auto.sh` | 全链路编排：构建三仓 → 起柜台 → 沪/深各跑一轮 → 确定性停机 |

## 拓扑（每市场一轮）

```text
gt-auto fbsdk 模拟器(真实 Go SDK, cgo) ──▶ fcounter ingress
fcounter counter-gw-sse/szse ──────────▶ gt-auto 交易所侧（会话自动应答）
```

gt-auto 交易所侧对网关 Logon 自动回 PlatformState Open（counter-gw 登录就绪约定），
会话帧不占用例队列；用例只编排业务报文（发单/收单/受理/成交/撤拒）。

## 运行

前置：本仓与 `../fcounter`、`../fbsdk`、`../gt-auto` 同级检出（目录名可用
`FCOUNTER_DIR` / `FBSDK_DIR` / `GT_AUTO_DIR` 覆盖）；Rust + Go 1.25+ 工具链；
私有仓 git 凭证（fcounter 构建经 git tag 拉取 fcp / fbsdk）。

```sh
./scripts/e2e_gt_auto.sh            # 沪 + 深两轮；两轮全过退出 0
E2E_KEEP=1 ./scripts/e2e_gt_auto.sh # 保留 /tmp/fcounter-gtauto.*（柜台日志 + JSON 报告）
```

## 与 gt-auto 仓 testdata 的关系

[gt-auto `pkg/testcase/testdata/`](https://github.com/xinchentechnote/gt-auto/tree/main/pkg/testcase/testdata)
保留同一套 `fcounter_*` 用例作为**工具自测副本**（无 cgo / 无网络下覆盖用例解析、
配置构造、报文分发）。counter 契约（字段映射/回报语义/拒绝码）变更时：
先改本仓权威副本并对真柜台验证通过，再同步 gt-auto 侧副本。

## CI

[.github/workflows/e2e.yml](.github/workflows/e2e.yml) 将 fcounter / fbsdk / gt-auto
按同级布局检出后执行同一脚本。四仓均为私有仓库：checkout 与 cargo git 依赖都走
secret `XC_READ_TOKEN`（对各仓只读的 fine-grained PAT；cargo 侧依赖 fcounter
`.cargo/config.toml` 的 `git-fetch-with-cli`，缺一即 404）。失败时上传
`/tmp/fcounter-gtauto.*` 下的柜台日志与报告。

## License

MIT，见 [LICENSE](LICENSE)。
