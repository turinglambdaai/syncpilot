# SyncPilot

[Resilio Sync](https://www.resilio.com/individuals/)（`rslsync`）的 Linux 原生桌面壳——在桌面窗口内嵌**官方 Resilio Web UI**，界面与操作流程和官方 Windows/macOS 客户端完全一致，并补齐 Linux 缺的部分：守护进程管理、托盘、开机自启、崩溃看护和应用内更新。

![license](https://img.shields.io/badge/license-AGPL--3.0-blue) ![platform](https://img.shields.io/badge/platform-Linux-lightgrey) ![built with](https://img.shields.io/badge/built%20with-Tauri%202-orange)

[English](README.md) · **中文**

SyncPilot 在原生窗口内运行并管理官方 `rslsync` 守护进程，窗口里显示的就是官方 Resilio Web UI。它仅通过环回地址与守护进程通信——密钥与文件永不离开你的机器。

## 功能

- **官方界面，零偏差**——文件夹、对端、传输、偏好设置、许可激活：每一屏都是官方 Web UI 本身，与你安装的 rslsync 版本严格对应
- **守护进程生命周期**——一键启停，自动接管已在运行的守护进程（systemd、上次会话遗留），崩溃看护与指数退避重启，可选退出后保持运行
- **应用内更新**——每个 Release 产出签名的更新制品（Tauri updater）
- **桌面集成**——托盘快捷操作、关闭时隐藏到托盘、开机自启（XDG autostart）
- **构造即安全**——Web UI 仅绑定 `127.0.0.1`，凭据由应用随机生成，配置文件 `0600` 权限；代理层注入认证，守护进程永不响应未认证请求

## 安装

从 [Releases](https://github.com/turinglambdaai/syncpilot/releases) 下载 `deb`、`rpm` 或 `AppImage`（x86_64 / aarch64）。

若未检测到官方 `rslsync` 二进制（自动探测覆盖 `~/.local/bin`、`/usr/bin`、`/usr/local/bin`、`/opt/resilio-sync` 和 `$PATH`），SyncPilot 会在首次启动时提供从 Resilio CDN 一键下载（sha256 校验，装入 `~/.local/bin`）；也可以自行安装后在 **托盘 → SyncPilot Settings…** 里指定路径。

## 从源码构建

Linux 构建机需要常规 Tauri 依赖（`libwebkit2gtk-4.1-dev`、`libgtk-3-dev`、`libayatana-appindicator3-dev`、`librsvg2-dev`）：

```bash
npm install
npm run tauri build   # 产出 deb / rpm / AppImage
```

## 工作原理

```
┌────────────┐  spawn --nodaemon   ┌───────────────┐
│ SyncPilot  │────────────────────▶│  rslsync      │
│  (Tauri 2) │◀────────────────────│  (official)   │
└────────────┘   /gui/? action API   └───────────────┘
                 127.0.0.1:<port>
```

SyncPilot 生成 `rslsync.conf`（Web UI 仅环回、随机凭据、不写 API key——rslsync 3.x 会拒绝本地生成的 key），以前台方式启动官方二进制。窗口通过第二个环回监听加载官方 Web UI——该代理自动注入 basic-auth 凭据，界面与官方逐像素一致，守护进程也永不响应未认证请求。所有 Resilio Sync 流量（P2P、tracker、relay）由官方二进制自行处理；SyncPilot 不碰你的密钥与文件。

## 状态

客户端对接 Web UI 的 **action API**，已在 rslsync 3.1.2 上实测验证——协议全过程见 [docs/api-verified.md](docs/api-verified.md)（含 3.x 许可门控说明）。字段解析对不同 rslsync 构建保持宽松；如果你的构建上某些数据为空，请带着 `rslsync --version` 提 issue。

## 许可

[AGPL-3.0](LICENSE)。与 Resilio, Inc. 无关。"Resilio Sync" 是其各自所有者的商标。
