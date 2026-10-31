# SyncPilot

[Resilio Sync](https://www.resilio.com/individuals/)（`rslsync`）的 Linux 原生桌面壳——在桌面窗口内嵌**官方 Resilio Web UI**，界面与操作流程和官方 Windows/macOS 客户端完全一致，并补齐 Linux 缺的部分：守护进程管理、开机自启、崩溃看护和官方二进制首次运行安装。

[![release](https://img.shields.io/github/v/release/turlamai/syncpilot)](https://github.com/turlamai/syncpilot/releases/latest) ![platform](https://img.shields.io/badge/platform-Linux-lightgrey) ![built with](https://img.shields.io/badge/built%20with-Rivet-9333ea) [![CI](https://github.com/turlamai/syncpilot/actions/workflows/ci.yml/badge.svg)](https://github.com/turlamai/syncpilot/actions/workflows/ci.yml) [![License](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)

[English](README.md) · **中文**

SyncPilot 在原生窗口内运行并管理官方 `rslsync` 守护进程，窗口里显示的就是官方 Resilio Web UI。它仅通过环回地址与守护进程通信——控制通道位于本地；官方守护进程会将配置的文件同步给对端。
SyncPilot 以 [Rivet](https://github.com/turlamai/rivet) 构建：一份 Racket 领域核心（守护进程管理、conf 生成、认证注入代理、设置）通过类型化 RPC 驱动第一方 GTK4 宿主——宿主只做渲染与交互，业务全部在后端。

## 开始使用

AGPL-3.0 许可的免费 Linux 维护项目。Resilio 的独立许可和服务限制仍适用；SyncPilot 不设付费层。 仅支持 Linux。官方 rslsync 二进制及其条款独立于 SyncPilot；Windows/macOS 移植不是当前交付。

[安装、首次使用、隐私与备份恢复](docs/USER-GUIDE.zh-CN.md) · [English](docs/USER-GUIDE.md)

## 功能

- **官方界面，零偏差**——文件夹、对端、传输、偏好设置、许可激活：每一屏都是官方 Web UI 本身，与你安装的 rslsync 版本严格对应
- **守护进程生命周期**——一键启停，自动接管已在运行的守护进程（systemd、上次会话遗留），崩溃看护与指数退避重启，可选退出后保持运行
- **首次运行安装 rslsync**——未检测到官方二进制时，从 Resilio CDN 下载（sha256 校验）装入 `~/.local/bin`
- **在线更新**——每天后台静默检查一次 Ed25519 签名的发布 manifest（key id `syncpilot-2026-10`）；下载前必先询问，校验签名字节数与 SHA-256 后交给你验证过的 tar.gz——rslsync 数据绝不被触碰
- **桌面集成**——托盘常驻、关闭隐藏到托盘、开机自启（XDG autostart）、单实例唤起
- **构造即安全**——Web UI 仅绑定 `127.0.0.1`，凭据由应用随机生成，配置文件 `0600` 权限；后端代理层注入认证，守护进程永不响应未认证请求
- **原地升级**——数据路径与格式和 0.4.x 逐字节一致（`~/.local/share/site.jrtx.syncpilot`）；设置、设备身份与守护进程配置原样保留

## 诚实缺口

- **更新不自动替换**——更新器会下载并通过签名校验新 tar.gz，但应用更新仍是手动步骤、按安装形态各不相同：tar.gz/zip 解压覆盖，deb/rpm 安装新包，AppImage 替换文件

## 安装

从 [Releases](https://github.com/turlamai/syncpilot/releases/latest) 获取安装包。每次发布都为 **x64** 与 **arm64** 提供完整矩阵：

| 格式 | 文件（每版本） | 说明 |
|---|---|---|
| deb | `syncpilot-<版本>-linux-amd64.deb` · `…-arm64.deb` | 安装到 `/opt/syncpilot`，带桌面入口与图标 |
| rpm | `syncpilot-<版本>-linux-x86_64.rpm` · `…-aarch64.rpm` | 与 deb 同一载荷 |
| AppImage | `syncpilot-<版本>-linux-x64.AppImage` · `…-arm64.AppImage` | 自带 GTK4 依赖闭包——比构建镜像更老的发行版也能跑 |
| tar.gz | `syncpilot-<版本>-linux-x64.tar.gz` · `…-arm64.tar.gz` | 解压运行 `RivetHost`；也是应用内更新器下载并校验的更新载荷 |
| 便携 zip | `syncpilot-<版本>-linux-x64.zip` · `…-arm64.zip` | 与 tar.gz 同布局 |

每个文件都带 `.sha256` 校验文件，另有每个架构的合并 `SHA256SUMS`、CycloneDX SBOM 与第三方声明，以及应用内更新器消费的 Ed25519 签名 `update-stable.json` manifest。Ubuntu 24.04+ 自带所需的 GTK 4 / WebKitGTK 6.0；其余依赖已捆绑或属系统基础库。

若未检测到官方 `rslsync` 二进制（自动探测覆盖 `~/.local/bin`、`/usr/bin`、`/usr/local/bin`、`/opt/resilio-sync` 和 `$PATH`），SyncPilot 会在首次启动时提供从 Resilio CDN 一键下载（sha256 校验，装入 `~/.local/bin`）；也可以自行安装后在**设置**里指定路径。

## 更新

SyncPilot 有应用内更新器，完整契约见 [docs/UPDATE.zh-CN.md](docs/UPDATE.zh-CN.md)。简述：

- **每天静默检查一次**签名的 `update-stable.json` feed（启动时后台自动检查，24 小时节流；UI 里手动检查不受限），
- 有可用更新时**应用内下载**，先对照签名 manifest 校验大小与 SHA-256 再交付，
- **应用更新是手动步骤、按安装形态各不相同**：tar.gz/zip 解压覆盖应用目录，deb/rpm 安装新包，AppImage 替换文件——rslsync 数据与设置绝不被触碰。各形态交接与恢复手册见 [docs/UPDATE.zh-CN.md](docs/UPDATE.zh-CN.md)。

## 从源码构建

Linux（或 WSL2），需要 Racket CS 9.x、CMake 和 GTK4/WebKitGTK 6.0 开发包：

```bash
raco pkg install --auto --no-docs https://github.com/turlamai/rivet.git
raco rivet build        # 生成客户端 + 编译后端 bundle + 构建宿主
raco rivet dev          # 开发循环：改动后自动重建重启
raco test racket/       # 领域核心测试
```

细节与手编步骤见 [linux/README.md](linux/README.md)。

## 工作原理

```
┌────────────────────────────┐  spawn --nodaemon  ┌───────────────┐
│ GTK4 宿主（RivetHost）      │───────────────────▶│  rslsync      │
│  启动页 / Web 视图          │◀───────────────────│  （官方）      │
│  ┌──────────────────────┐  │                    └───────────────┘
│  │ Racket 后端（CS）     │  │   环回认证注入代理
│  │  manager · conf      │  │      （临时端口）
│  │  proxy · settings    │  │  ┌───────────────┐
│  └──────────────────────┘  │▶ │  官方 Web UI   │
│       类型化 RPC（RVT1）    │  └───────────────┘
└────────────────────────────┘
```

Racket 后端生成 `rslsync.conf`（Web UI 仅环回、随机凭据、不写 API key——rslsync 3.x 会拒绝本地生成的 key），以前台方式启动官方二进制。窗口通过第二个环回监听加载官方 Web UI——该代理自动注入 basic-auth 凭据，界面与官方逐像素一致，守护进程也永不响应未认证请求。所有 Resilio Sync 流量（P2P、tracker、relay）由官方二进制自行处理；文件传输及外部发现、中继流量由该守护进程负责。

## 状态

CI 在 ubuntu-24.04 上构建宿主并对真实链路做集成冒烟：`initialize` 拉起 checksum 锁定的 rslsync 守护进程、其 Web UI 监听 `127.0.0.1:38889`、认证注入代理对 `/gui/` 正常应答。守护进程侧客户端对接 Web UI 的 **action API**，已在 rslsync 3.1.2 上实测验证——协议事实见 [docs/api-verified.md](docs/api-verified.md)。

## 许可

[AGPL-3.0](LICENSE)。与 Resilio, Inc. 无关。"Resilio Sync" 是其各自所有者的商标。
