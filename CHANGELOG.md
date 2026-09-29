# Changelog

All notable changes to SyncPilot are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning: [SemVer](https://semver.org/).

## [Unreleased]

### Fixed

- A foreign daemon holding SyncPilot's port is no longer adopted: port probing now distinguishes compatible / foreign / absent, and a credentials mismatch (e.g. a leftover systemd service) surfaces as an actionable error on the boot page instead of a silently unusable session
- The boot page shows the actual failure reason and retries only on click, so real errors can no longer loop behind an auto-retry

- Generated `rslsync.conf` now sets `"agree_to_EULA": "yes"` — rslsync 3.x exits immediately without it, so app-spawned daemons never started on 3.1.2
- The conf no longer writes an `api_key`: rslsync 3.x validates keys against Resilio-issued signed keys and refuses to start on a locally generated one
- `AppSettings::load` no longer forks credentials on first run: it used to persist one random password and return a second, leaving the app unable to authenticate to its own daemon until the next launch (verified live on a fresh install)

## [0.2.0] - 2026-09-28

### Changed

- **The main window now embeds the official Resilio Web UI** — interface and interaction flow are exactly the official ones (including 3.x activation and identity setup, which the official UI owns). SyncPilot's own UI shrinks to a boot page (daemon handoff + first-run rslsync install) and a native settings window (tray → SyncPilot Settings…)
- The official UI is served through a loopback auth-injecting proxy (`src-tauri/src/proxy.rs`): the webview never sees a basic-auth prompt, the daemon port never serves an unauthenticated request
- API client slimmed to daemon lifecycle calls (ping / version / shutdown); folder, peer, transfer and license parsing is gone — the official UI talks to the daemon itself
- Removed pause/resume controls and the custom overview/folder/add views; `api_key` removed from app settings

### Added

- In-app updates via `tauri-plugin-updater`: signed updater artifacts in CI (`createUpdaterArtifacts`), `latest.json` static manifest assembled per release (`scripts/gen-update-manifest.py`), release-check key via `TAURI_SIGNING_PRIVATE_KEY` secrets
- First-run install of the official rslsync binary straight from Resilio's CDN into `~/.local/bin` (sha256-pinned, `scripts/install-rslsync.sh` logic ported to Rust) — no separate manual download step
- Tray menu entry "SyncPilot Settings…" opening a dedicated settings window

### Removed

- The custom sidebar/overview/folder-detail interface, replaced by the official Web UI

## [0.1.0] - 2026-09-28
