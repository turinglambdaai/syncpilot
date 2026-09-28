# SyncPilot

[Resilio Sync](https://www.resilio.com/individuals/)（`rslsync`）的 Linux 原生桌面 GUI——把官方 Windows 与 macOS 客户端的桌面体验带给 Linux。

![license](https://img.shields.io/badge/license-AGPL--3.0-blue) ![platform](https://img.shields.io/badge/platform-Linux-lightgrey) ![built with](https://img.shields.io/badge/built%20with-Tauri%202-orange)

[English](README.md) · **中文**

SyncPilot 在干净的桌面应用背后运行并管理官方 `rslsync` 守护进程：文件夹、对端、传输、暂停/恢复、限速和托盘图标。它仅通过环回地址访问 Resilio Sync 本地 Web UI API——密钥与文件永不离开你的机器。

## 功能

- **守护进程生命周期**——一键启停，自动接管已在运行的守护进程（systemd、上次会话遗留），崩溃看护与指数退避重启，可选退出后保持运行
- **文件夹**——按分享密钥添加或新建（读&写 / 只读密钥），逐文件夹暂停/恢复，移除（文件保留在磁盘）
- **对端**——连接状态、同步进度条、逐对端传输速率
- **传输**——全局暂停/恢复、上下行限速、实时速率图
- **桌面集成**——托盘快捷操作、关闭时隐藏到托盘、开机自启（XDG autostart）
- **构造即安全**——Web UI 仅绑定 `127.0.0.1`，凭据由应用随机生成，配置文件 `0600` 权限

## 安装

从 [Releases](https://github.com/turinglambdaai/syncpilot/releases) 下载 `deb`、`rpm` 或 `AppImage`（x86_64 / aarch64）。

系统里还需要官方 Resilio Sync 二进制：从 resilio.com 下载 `resilio-sync`，或在 **Settings → Daemon** 里指定路径（自动探测覆盖 `/usr/bin`、`/usr/local/bin`、`/opt/resilio-sync` 和 `$PATH`）。

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
└────────────┘   REST /api/v2 on   └───────────────┘
                 127.0.0.1:<port>
```

SyncPilot 生成 `rslsync.conf`（Web UI 仅环回、随机凭据、API key），以前台方式启动官方二进制，并完全通过本地 REST API 驱动它。所有 Resilio Sync 流量（P2P、tracker、relay）由官方二进制自行处理；SyncPilot 不碰你的密钥与文件。

## 状态

`v0.1.0` — 首个版本。`/api/v2` 接口基于官方 Web UI 与官方 API sample 逆向整理，字段解析对不同 rslsync 构建保持宽松。如果你的构建上某些数据为空，请带着 `rslsync --version` 提 issue。

## 许可

[AGPL-3.0](LICENSE)。与 Resilio, Inc. 无关。"Resilio Sync" 是其各自所有者的商标。
