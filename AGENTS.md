# AGENTS.md

## Authorization decision before implementation

Decision `2026-10-auth-1`: No commercial Permit credentials, Commerce checkout or licensing account. Read the complete [local authorization decision](PRICING.md#authorization-decision-for-implementation) and its Chinese counterpart before commercial, trial, update-eligibility or credential work. Record this decision revision and the source/policy SHAs actually read in the PR/handoff. Refresh at each bounded slice; existing agent conversations do not receive this change automatically. Follow the existing product contract and implementation issue; do not activate a payment gate merely because a plan exists.

指引给 AI agent（及开发者）：如何理解、构建、运行、改动 SyncPilot（Rivet 重建线）。

> 0.5.0 起 main 即本线：一份 Racket 领域核心 + GTK4 单宿主。旧 Tauri 2 栈已从
> 树上删除，行为与文案参照留在 git 历史（v0.4.0 及之前的 tag）。

## 这是什么

SyncPilot 以 Rivet（github.com/turinglambdaai/rivet）构建：一份 Racket 领域核心，
通过 Rivet 类型化 RPC（RVT1 协议）驱动第一方原生 UI 薄壳。

SyncPilot 仅面向 Linux：

| 宿主 | 技术栈 | 目录 | 状态 |
|---|---|---|---|
| Linux | GTK4 + WebKitGTK 6.0 宿主 + 生成客户端 | `linux/` | CI 编译 + 集成冒烟全绿（真守护进程 + 代理链路断言）；详见 `linux/README.md` |

## 快速命令

```bash
# 前置：Racket CS 9.x，rivet 以 link 方式安装
# cd ../rivet && raco pkg install --auto --no-docs --name rivet --link file://$PWD

raco rivet doctor --json   # 工具链自检
raco rivet build           # 生成三端客户端 + 编译后端 bundle + 宿主构建
raco rivet dev             # 开发循环
raco test racket/          # 领域核心测试
raco rivet acceptance --json # Linux 完整产品验收
```

开始修改已有 checkout 前，必须先检查 `git status`，再以 fast-forward-only
方式更新 tracked remote。工作树非干净、分支已分叉或远端不可达时，保留现场并
报告，不得用 stash/reset/清理生成目录掩盖状态。记录本次工作的起始 commit。

`rivet-acceptance.rktd` 是 Linux 产品的可执行完成定义。Agent 不得删除
requirement、放宽断言、以 CLI 代替 GUI 行为或复用旧证据来让结果变绿；required
suite 只要未执行、超时、失败或没有产生本次运行的新证据，就不能称为完成。

## 契约（不要破坏）

- **数据路径与格式与旧版完全一致**（drop-in 迁移）：syncpilot-settings.json / rslsync.conf（0600）/ storage/，目录 ~/.local/share/site.jrtx.syncpilot（Linux）；协议事实见 docs/api-verified.md（必读）
- **i18n 单源**：`shared/i18n/{zh,en}.json`，平台副本必须逐字节一致；zh 为默认
- **RPC 面**：`app/backend.rkt` 的 define-rpc 是宿主唯一数据通道；改签名 = 各端宿主 + 生成客户端同步改
- **宿主只做渲染与交互**：业务一律走 RPC；定时器/调度/HTTP/存储都在 Racket 后端
- **Rivet 改动走上游**：缺能力先提 issue/PR 到 turinglambdaai/rivet
- **平台范围**：SyncPilot 只支持 Linux；不要添加空壳 Windows/macOS 宿主，也不要把未支持平台记作产品缺陷

## 项目结构

```
├── rivet.rktd          Rivet 应用清单
├── app/backend.rkt     Rivet 后端入口（装配领域层）
├── racket/             Racket 领域核心 + tests/
├── shared/i18n/        zh.json / en.json 单源
├── linux/              GTK4 宿主（唯一宿主；详见 linux/README.md）
├── docs/               产品官网（GitHub Pages → syncpilot.jrtx.site）
└── scripts/            gen-c-strings.mjs（i18n → C 头）、install-rslsync.sh
```

## 组合定位（Portfolio placement）

- 当前决策（2026-10-v2）：免费保活。具体价格、免费/付费边界和开卖门禁以本仓 [PRICING.md](PRICING.md) 为唯一权威；旧版收费候选与早鸟方案已被替代。
- 组合归属：[PORTFOLIO](https://github.com/turinglambdaai/turinglambdaai.github.io/blob/master/PORTFOLIO.md)。当前全部产品开发中、没有实际用户；目标定价不表示已经开卖，不因此立即给开发版加收费墙。
- 免费产品不接商业激活；付费层先实现可验证价值，再接 Commerce/Permit。优先完成本仓既有产品审查 issue；不修改现行源码 LICENSE。

## 产品交付与下一步（2026-10-23）

- 家族[交付标准](https://github.com/turinglambdaai/turinglambdaai.github.io/blob/master/docs/PRODUCT-STANDARD.md)与[组合策略](https://github.com/turinglambdaai/turinglambdaai.github.io/blob/master/PORTFOLIO.md)是共用政策；本仓具体行为以 `docs/UPDATE.md` 为准，不复制五库依赖图。
- 当前执行入口：[产品审查 issue](https://github.com/turinglambdaai/syncpilot/issues/10)。Linux 维护模式：只补第三方兼容、鉴权/进程恢复、安装形态的验证更新交接与反馈；不新增平台/云/收费层。
- 开工先检查干净工作树与远端，以 fast-forward-only 更新并记录 SHA；共享文件一次一个写入者，保留其他 checkout 的未提交工作。
- 每次只完成一个可验收切片，记录 owned files、依赖 pin、命令/平台/产物证据和回滚。已实现、已发布、实机验收分别陈述；不修改 requirements 或复用旧证据来制造通过。

## Documentation languages

Public default documentation is English; maintain complete Chinese user paths in `*.zh-CN.md`, with reciprocal links. Update both languages when prices, quotas, installation, recovery, privacy or supported platforms change. API/protocol identifiers and commands remain unchanged; do not maintain a second normative protocol or implementation. Follow the [family language policy](https://github.com/turinglambdaai/turinglambdaai.github.io/blob/master/docs/DOCUMENTATION-LANGUAGES.md). Existing internal notes are not a claim that every document is bilingual.

## Public product documentation

The paired `docs/USER-GUIDE.md` / `docs/USER-GUIDE.zh-CN.md` own the public installation, first-use, data/recovery, privacy and availability path. Keep the homepage and both README entry points aligned with them when behavior changes. Detailed technical contracts and the current implementation queue retain their existing owners. Do not publish target prices, a purchase link or a ready/secure/platform claim before its release evidence exists.
