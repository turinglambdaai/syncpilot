# SyncPilot

A native desktop shell for [Resilio Sync](https://www.resilio.com/individuals/) (`rslsync`) on Linux — it embeds the **official Resilio Web UI** in a desktop window, so the interface and workflow are exactly the official Windows/macOS client experience, with everything Linux was missing on top: daemon lifecycle, tray, autostart, crash watchdog and in-app updates.

![license](https://img.shields.io/badge/license-AGPL--3.0-blue) ![platform](https://img.shields.io/badge/platform-Linux-lightgrey) ![built with](https://img.shields.io/badge/built%20with-Tauri%202-orange)

**English** · [中文](README.zh-CN.md)

SyncPilot runs and manages the official `rslsync` daemon behind a native window that shows the official Resilio Web UI. It talks to the daemon over loopback only — your keys and files never leave your machine.

## Features

- **Official interface, zero drift** — folders, peers, transfers, preferences, activation: every screen and interaction is the official Web UI, version-matched to your rslsync build. Nothing to re-learn, nothing to re-implement
- **Daemon lifecycle** — one-click start/stop, adopt an already-running daemon (systemd, previous session), crash watchdog with exponential backoff, optional keep-running-on-exit
- **In-app updates** — signed updater artifacts per release (Tauri updater)
- **Desktop integration** — tray icon with quick actions, hide-to-tray on close, launch at login (XDG autostart)
- **Safe by construction** — the Web UI stays bound to `127.0.0.1` with app-generated credentials; the app serves it through a loopback auth-injecting proxy so you never see a login prompt, and the daemon never serves an unauthenticated request

## Install

Grab `deb`, `rpm` or `AppImage` (x86_64 / aarch64) from [Releases](https://github.com/turinglambdaai/syncpilot/releases).

If the official `rslsync` binary is not found (auto-detection covers `~/.local/bin`, `/usr/bin`, `/usr/local/bin`, `/opt/resilio-sync`, `$PATH`), SyncPilot offers to download it from Resilio's CDN on first launch (sha256-pinned, installed to `~/.local/bin`) — or install it yourself and point SyncPilot at it in **tray → SyncPilot Settings…**.

## Building from source

Linux build host with the usual Tauri prerequisites (`libwebkit2gtk-4.1-dev`, `libgtk-3-dev`, `libayatana-appindicator3-dev`, `librsvg2-dev`):

```bash
npm install
npm run tauri build   # produces deb / rpm / AppImage
```

## How it works

```
┌────────────┐  spawn --nodaemon   ┌───────────────┐
│ SyncPilot  │────────────────────▶│  rslsync      │
│  (Tauri 2) │◀────────────────────│  (official)   │
└────────────┐  spawn --nodaemon   ┌───────────────┐
                 loopback auth-injecting
┌────────────┐        proxy          ┌───────────────┐
│ SyncPilot  │────────────────────▶│  official     │
│  webview   │   http://127.0.0.1   │  Web UI       │
└────────────┘                       └───────────────┘
```

SyncPilot generates an `rslsync.conf` (loopback-only Web UI, random credentials, no API key — rslsync 3.x rejects locally generated ones) and launches the official binary in the foreground. The window loads the official Web UI through a second loopback listener that injects the basic-auth credentials, so the interface is pixel-for-pixel the official one and the daemon never serves an unauthenticated request. All Resilio Sync traffic (P2P, trackers, relays) is handled by the official binary itself; SyncPilot never touches your keys or files.

## Developing on Linux

SyncPilot manages a real `rslsync` daemon, so the full stack can only be exercised on Linux (native, VM, or WSL2). See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) — a one-shot `scripts/setup-dev-ubuntu.sh` plus `scripts/verify-api.sh`, which probes the live rslsync API and dumps a report used to keep the Rust client aligned with facts.

## Status

`v0.2.0` — official Web UI embedded, in-app updates, first-run rslsync install. The daemon-facing client (lifecycle only) targets the Web UI action API verified live against rslsync 3.1.2 — protocol facts in [docs/api-verified.md](docs/api-verified.md).

## License

[AGPL-3.0](LICENSE). Not affiliated with Resilio, Inc. "Resilio Sync" is a trademark of its respective owner.
