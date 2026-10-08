# SyncPilot

A native desktop shell for [Resilio Sync](https://www.resilio.com/individuals/) (`rslsync`) on Linux — it embeds the **official Resilio Web UI** in a desktop window, so the interface and workflow are exactly the official Windows/macOS client experience, with everything Linux was missing on top: daemon lifecycle, autostart, crash watchdog and a first-run installer for the official binary.

[![release](https://img.shields.io/github/v/release/turinglambdaai/syncpilot)](https://github.com/turinglambdaai/syncpilot/releases/latest) ![platform](https://img.shields.io/badge/platform-Linux-lightgrey) ![built with](https://img.shields.io/badge/built%20with-Rivet-9333ea) [![License](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)

**English** · [中文](README.zh-CN.md) · 🌐 [syncpilot.jrtx.site](https://syncpilot.jrtx.site/)


- **No tray icon** yet — close quits instead of hiding to tray; waiting on the rivet tray contract ([turinglambdaai/rivet#118](https://github.com/turinglambdaai/rivet/issues/118))
- **No in-app updates** yet — update when a new release lands; the rivet update flow (signed manifests) will replace the old deb/AppImage updater

## Install

Grab `syncpilot-<version>-linux-x64.tar.gz` from [Releases](https://github.com/turinglambdaai/syncpilot/releases), unpack it, and run `RivetHost` (Ubuntu 24.04+ ships the required GTK 4 / WebKitGTK 6.0; everything else is bundled or base-system).

If the official `rslsync` binary is not found (auto-detection covers `~/.local/bin`, `/usr/bin`, `/usr/local/bin`, `/opt/resilio-sync`, `$PATH`), SyncPilot offers to download it from Resilio's CDN on first launch (sha256-pinned, installed to `~/.local/bin`) — or install it yourself and point SyncPilot at it in **Settings**.

## Building from source

Linux (or WSL2) with Racket CS 9.x, CMake, and the GTK4/WebKitGTK 6.0 dev packages:

```bash
raco pkg install --auto --no-docs https://github.com/turinglambdaai/rivet.git
raco rivet build        # generates clients, compiles the backend bundle, builds the host
raco rivet dev          # develop loop: rebuild + relaunch on change
raco test racket/       # domain-core tests
```

Details and manual CMake steps: [linux/README.md](linux/README.md).

## How it works

```
┌────────────────────────────┐  spawn --nodaemon  ┌───────────────┐
│ GTK4 host (RivetHost)      │───────────────────▶│  rslsync      │
│  boot page / web view      │◀───────────────────│  (official)   │
│  ┌──────────────────────┐  │                    └───────────────┘
│  │ Racket backend (CS)  │  │   loopback auth-injecting
│  │  manager · conf      │  │        proxy (ephemeral port)
│  │  proxy · settings    │  │  ┌───────────────┐
│  └──────────────────────┘  │▶ │  official     │
│       typed RPC (RVT1)     │  │  Web UI       │
└────────────────────────────┘  └───────────────┘
```

The Racket backend generates an `rslsync.conf` (loopback-only Web UI, random credentials, no API key — rslsync 3.x rejects locally generated ones) and launches the official binary in the foreground. The window loads the official Web UI through a second loopback listener that injects the basic-auth credentials, so the interface is pixel-for-pixel the official one and the daemon never serves an unauthenticated request. All Resilio Sync traffic (P2P, trackers, relays) is handled by the official binary itself; SyncPilot never touches your keys or files.

## Status

CI builds the host on ubuntu-24.04 and integration-smokes the real chain: `initialize` spawns the pinned rslsync daemon, its Web UI listens on `127.0.0.1:38889`, and the auth-injecting proxy answers for `/gui/`. The daemon-facing client targets the Web UI action API verified live against rslsync 3.1.2 — protocol facts in [docs/api-verified.md](docs/api-verified.md).

## License

[AGPL-3.0](LICENSE). Not affiliated with Resilio, Inc. "Resilio Sync" is a trademark of its respective owner.
