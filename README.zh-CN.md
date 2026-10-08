# SyncPilot

[Resilio Sync](https://www.resilio.com/individuals/)（`rslsync`）的 Linux 原生桌面壳——在桌面窗口内嵌**官方 Resilio Web UI**，界面与操作流程和官方 Windows/macOS 客户端完全一致，并补齐 Linux 缺的部分：守护进程管理、开机自启、崩溃看护和官方二进制首次运行安装。

[![release](https://img.shields.io/github/v/release/turinglambdaai/syncpilot)](https://github.com/turinglambdaai/syncpilot/releases/latest) ![platform](https://img.shields.io/badge/platform-Linux-lightgrey) ![built with](https://img.shields.io/badge/built%20with-Rivet-9333ea) [![License](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)

[English](README.md) · **中文** · 🌐 [syncpilot.jrtx.site](https://syncpilot.jrtx.site/)


- **暂无托盘图标**——关闭窗口即退出（不隐藏到托盘）；等 rivet 托盘契约（[turinglambdaai/rivet#118](https://github.com/turinglambdaai/rivet/issues/118)）
- **暂无应用内更新**——新版本请到 release 页获取；rivet 更新流（签名 manifest）落地后将替代旧的 deb/AppImage 更新器

## 安装

从 [Releases](https://github.com/turinglambdaai/syncpilot/releases) 下载 `syncpilot-<版本>-linux-x64.tar.gz`，解压后运行 `RivetHost`（Ubuntu 24.04+ 自带所需的 GTK 4 / WebKitGTK 6.0；其余依赖已捆绑或属系统基础库）。

若未检测到官方 `rslsync` 二进制（自动探测覆盖 `~/.local/bin`、`/usr/bin`、`/usr/local/bin`、`/opt/resilio-sync` 和 `$PATH`），SyncPilot 会在首次启动时提供从 Resilio CDN 一键下载（sha256 校验，装入 `~/.local/bin`）；也可以自行安装后在**设置**里指定路径。

## 从源码构建

Linux（或 WSL2），需要 Racket CS 9.x、CMake 和 GTK4/WebKitGTK 6.0 开发包：

```bash
raco pkg install --auto --no-docs https://github.com/turinglambdaai/rivet.git
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

Racket 后端生成 `rslsync.conf`（Web UI 仅环回、随机凭据、不写 API key——rslsync 3.x 会拒绝本地生成的 key），以前台方式启动官方二进制。窗口通过第二个环回监听加载官方 Web UI——该代理自动注入 basic-auth 凭据，界面与官方逐像素一致，守护进程也永不响应未认证请求。所有 Resilio Sync 流量（P2P、tracker、relay）由官方二进制自行处理；SyncPilot 不碰你的密钥与文件。

## 状态

CI 在 ubuntu-24.04 上构建宿主并对真实链路做集成冒烟：`initialize` 拉起 checksum 锁定的 rslsync 守护进程、其 Web UI 监听 `127.0.0.1:38889`、认证注入代理对 `/gui/` 正常应答。守护进程侧客户端对接 Web UI 的 **action API**，已在 rslsync 3.1.2 上实测验证——协议事实见 [docs/api-verified.md](docs/api-verified.md)。

## 许可

[AGPL-3.0](LICENSE)。与 Resilio, Inc. 无关。"Resilio Sync" 是其各自所有者的商标。
