# Developing SyncPilot on Ubuntu

The GUI manages a real `rslsync` daemon, so Linux is the only place where the
whole stack can be exercised. This guide sets up a Ubuntu 22.04 / 24.04
machine (native, VM, or WSL2) from zero to a running app.

## 0. On Windows and want a local Linux?

```powershell
wsl --install -d Ubuntu
```

(admin PowerShell, reboot once). WSLg gives you the actual GUI window. Then
continue inside the Ubuntu shell.

## 1. One-shot environment setup

```bash
git clone https://github.com/turinglambdaai/syncpilot.git
cd syncpilot
bash scripts/setup-dev-ubuntu.sh
```

The script installs Tauri's system dependencies (`libwebkit2gtk-4.1-dev`,
`libgtk-3-dev`, `libayatana-appindicator3-dev`, `librsvg2-dev`), Rust stable
with rustfmt/clippy, Node.js 22, the official `rslsync` binary (pinned
sha256), then proves the toolchain with `npm run build` and `cargo test`.

Re-run it any time; every step is idempotent.

## 2. Verify the rslsync API surface

```bash
bash scripts/verify-api.sh
```

This starts a throwaway rslsync daemon (isolated storage, random
credentials, loopback port 48889) and probes every endpoint the Rust client
uses — auth candidates, folder CRUD, per-folder peers, settings, shutdown —
dumping the full HTTP responses into a `verify-report.txt`.

The rslsync **3.x** API differs substantially from the 2.x-era endpoints
found in older documentation, and a few method/body shapes in
`src-tauri/src/api.rs` are still marked `[UNVERIFIED]`. If the report shows
a mismatch (empty folder lists, auth rejections), attach the report to a
GitHub issue — the client is fixed from facts, not guesses.

## 3. Run the app

```bash
npm run tauri dev
```

First Rust build takes a few minutes. The SyncPilot window opens, spawns the
rslsync daemon from `~/.local/bin/rslsync` (Settings → Daemon to change),
and talks to it over loopback only.

To build installers: `npm run tauri build` (deb / rpm / AppImage).

## Layout

```
src/               frontend (vanilla TS + Vite): sidebar, overview, folder
                   detail, add-folder wizard, settings
src-tauri/src/     Rust backend:
  api.rs           rslsync REST client — all endpoint paths and lenient
                   response parsing live here
  manager.rs       daemon lifecycle: spawn/adopt/supervise/stop
  rslsync_config.rs generates rslsync.conf (loopback, random credentials)
  settings.rs      app-side settings
  commands.rs      Tauri command layer invoked from the frontend
  autostart.rs     XDG autostart entry
scripts/           setup-dev-ubuntu.sh / install-rslsync.sh / verify-api.sh
.github/workflows  CI (fmt, clippy, test, frontend build) and the release
                   pipeline (tag v* → deb/rpm/AppImage, x64 + arm64)
```

## Notes

- The daemon crash watchdog and adopt-already-running logic can be exercised
  by `kill -9`-ing the rslsync process (watch it restart with backoff) or by
  starting your own rslsync on the configured port (watch SyncPilot adopt it).
- GNOME needs the AppIndicator extension for the tray icon; KDE and most
  other desktops show it natively.
- CI runs the same checks locally available: `cargo fmt --check`,
  `cargo clippy --all-targets -- -D warnings`, `cargo test`, `npm run build`.
