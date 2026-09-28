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
credentials, loopback port 48889) and probes the Web UI action API —
token handshake, info/settings, speed charts, license state, folder
lifecycle, settings round-trip, shutdown — dumping full responses into a
`verify-report.txt`.

The Rust client speaks the same **action API** the official Web UI uses
(`POST /gui/token.html` + `GET /gui/?token=…&action=…` with basic auth),
verified live against rslsync 3.1.2. See [docs/api-verified.md](api-verified.md)
for the protocol facts, including two conf requirements (mandatory
`agree_to_EULA`, no local `api_key`) and the 3.x license gate that makes
folder operations no-ops until the daemon is activated. If the report
shows a mismatch on your build, attach it to a GitHub issue — the client
is fixed from facts, not guesses.

## 3. Run the app

```bash
npm run tauri dev
```

First Rust build takes a few minutes. The SyncPilot window opens, spawns the
rslsync daemon from `~/.local/bin/rslsync` (change it in the tray →
SyncPilot Settings… window), then hands the window over to the **official
Resilio Web UI** served through the auth-injecting loopback proxy.

To build installers: `TAURI_SIGNING_PRIVATE_KEY=/path/to/key npm run tauri
build` (deb / rpm / AppImage + signed `.AppImage.sig` updater artifacts).
Without the signing key env the bundle step fails — set a throwaway key for
local builds, the real one only lives in the release environment.

## Layout

```
src/               frontend (vanilla TS + Vite): boot page (daemon handoff,
                   first-run rslsync install) + settings window page
src-tauri/src/     Rust backend:
  proxy.rs         loopback auth-injecting reverse proxy serving the
                   official Web UI to the webview without login prompts
  api.rs           minimal rslsync client (ping/version/shutdown) for the
                   Web UI action API (see docs/api-verified.md)
  manager.rs       daemon lifecycle: spawn/adopt/supervise/stop
  rslsync_install.rs first-run download of the official rslsync binary
                   (sha256-pinned, into ~/.local/bin)
  rslsync_config.rs generates rslsync.conf (loopback, random credentials,
                   EULA acceptance, no api_key)
  settings.rs      app-side settings
  commands.rs      Tauri command layer invoked from the frontend
  autostart.rs     XDG autostart entry
scripts/           setup-dev-ubuntu.sh / install-rslsync.sh / verify-api.sh
                   / gen-update-manifest.py (updater latest.json)
.github/workflows  CI (fmt, clippy, test, frontend build) and the release
                   pipeline (tag v* → deb/rpm/AppImage, x64 + arm64, signed
                   updater artifacts + latest.json)
```

## In-app updates

`tauri-plugin-updater` checks
`releases/latest/download/latest.json` on GitHub Releases. The release
workflow signs AppImage artifacts with `TAURI_SIGNING_PRIVATE_KEY`
(repo secret) and assembles `latest.json` with
`scripts/gen-update-manifest.py`. The public key lives in
`plugins.updater.pubkey` in `src-tauri/tauri.conf.json` — **rotate it
together with the signing key**.

## Notes

- The daemon crash watchdog and adopt-already-running logic can be exercised
  by `kill -9`-ing the rslsync process (watch it restart with backoff) or by
  starting your own rslsync on the configured port (watch SyncPilot adopt it).
- GNOME needs the AppIndicator extension for the tray icon; KDE and most
  other desktops show it natively.
- CI runs the same checks locally available: `cargo fmt --check`,
  `cargo clippy --all-targets -- -D warnings`, `cargo test`, `npm run build`.
