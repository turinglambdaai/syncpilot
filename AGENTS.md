# AGENTS.md

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

- 轨道与授权：维护模式（免费保活，不再新增投入）；授权形态：AGPL-3.0；商业归属：永久免费——依附第三方 Resilio，无商业前途，仅做兼容性修复。
- 组合归属唯一权威：[PORTFOLIO.md](https://github.com/turinglambdaai/turinglambdaai.github.io/blob/master/PORTFOLIO.md)（turinglambdaai.github.io 仓库）。改归属/授权先改权威档，再同步本节。
- 纪律：价格只进本仓 `PRICING.md`，且收费开始时才发布；README 与产品站不做价格预告。
