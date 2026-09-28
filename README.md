# SyncPilot

A native desktop GUI for [Resilio Sync](https://www.resilio.com/individuals/) (`rslsync`) on Linux — the desktop experience the official Windows and macOS clients have, finally on Linux.

![license](https://img.shields.io/badge/license-AGPL--3.0-blue) ![platform](https://img.shields.io/badge/platform-Linux-lightgrey) ![built with](https://img.shields.io/badge/built%20with-Tauri%202-orange)

**English** · [中文](README.zh-CN.md)

SyncPilot runs and manages the official `rslsync` daemon behind a clean desktop app: folders, peers, transfers, speed limits and a tray icon. It talks to the daemon's local Web UI action API over loopback only — your keys and files never leave your machine.

## Features

- **Daemon lifecycle** — start/stop with one click, adopt an already-running daemon (systemd, previous session), crash watchdog with exponential backoff, optional keep-running-on-exit
- **Folders** — add by share key or create new (read & write / read-only keys), remove (files stay on disk). rslsync 3.x gates syncing behind license activation, and SyncPilot surfaces that state with a one-click free trial
- **Peers** — connection state, sync progress bars, per-peer transfer speeds
- **Transfers** — up/down speed limits, live rate graph
- **Desktop integration** — tray icon with quick actions, hide-to-tray on close, launch at login (XDG autostart)
- **Safe by construction** — Web UI bound to `127.0.0.1` with app-generated credentials, config written with `0600`

## Install

Grab `deb`, `rpm` or `AppImage` (x86_64 / aarch64) from [Releases](https://github.com/turinglambdaai/syncpilot/releases).

You also need the official Resilio Sync binary somewhere on the system — download `resilio-sync` from resilio.com (or install via their apt repo), then point SyncPilot at it in **Settings → Daemon** if auto-detection (covered: `/usr/bin`, `/usr/local/bin`, `/opt/resilio-sync`, `$PATH`) does not find it.

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
└────────────┘   /gui/? action API  └───────────────┘
                 127.0.0.1:<port>
```

SyncPilot generates an `rslsync.conf` (loopback-only Web UI, random credentials, no API key — rslsync 3.x rejects locally generated ones), launches the official binary in the foreground, and drives it through the same action API the official Web UI uses (`/gui/?token=…&action=…` with basic auth). All Resilio Sync traffic (P2P, trackers, relays) is handled by the official binary itself; SyncPilot never touches your keys or files.

## Developing on Linux

SyncPilot manages a real `rslsync` daemon, so the full stack can only be exercised on Linux (native, VM, or WSL2). See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) — a one-shot `scripts/setup-dev-ubuntu.sh` plus `scripts/verify-api.sh`, which probes the live rslsync API and dumps a report used to keep the Rust client aligned with facts.

## Status

The client targets the Web UI **action API**, verified live against rslsync 3.1.2 — see [docs/api-verified.md](docs/api-verified.md) for the protocol transcript and the 3.x licensing gate. Field parsing is lenient across rslsync builds; if something renders empty on your build, please open an issue with your `rslsync --version`.

## License

[AGPL-3.0](LICENSE). Not affiliated with Resilio, Inc. "Resilio Sync" is a trademark of its respective owner.
