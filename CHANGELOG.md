# Changelog

All notable changes to SyncPilot are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning: [SemVer](https://semver.org/).

## [Unreleased]

## [0.4.0] - 2026-09-30

### Added

- **In-app updates for deb installs**: when a new version is on the release feed, the Updates card now offers "Download & install…" — the deb is downloaded and verified against the release's published sha256 checksums, then installed via `pkexec dpkg -i`, so the desktop's polkit dialog collects the administrator password once and the app restarts into the new version. Dismissing the dialog or a checksum mismatch installs nothing. AppImage keeps its in-place updater; rpm keeps the release-page fallback
- The download path is exercised against a real release by an ignored network test (`cargo test -- --ignored`)

## [0.3.2] - 2026-09-30

### Fixed

- The settings window's content column hugged the left edge with a dead strip on the right: it reuses the main window's left-flushed `.view.narrow` layout, where it sits beside the sidebar. The sidebar-less settings window now centers the column

## [0.3.1] - 2026-09-30

### Fixed

- The settings window could not scroll: the page is ~1000px tall in a 640px window, `html/body` are `overflow: hidden` (that belongs to the main-window layout) and `#settings-root` had no scroll container of its own — so the Updates card, About and the **Save Settings** button were clipped out of reach entirely. Settings are savable again and "Check for updates" is reachable (found by rendering the page at the real window size, then measuring)
- The updates note no longer races the About section's version lookup: a fast `check_for_updates` response could hit the temporal dead zone on `version` and show `ReferenceError: Cannot access … before initialization` instead of "You are up to date"

## [0.3.0] - 2026-09-30

### Changed

- **Closing the window now hides SyncPilot to the tray instead of quitting, and quitting no longer stops the sync daemon** — matching the official Windows/macOS clients: the window leaves the taskbar while syncing continues, and the tray menu (Open / Settings / Quit) is the explicit way out. Both behaviors remain toggleable in SyncPilot Settings ("Hide to tray on close", "Keep the daemon running after the app exits")
- Settings written by 0.2.x migrate once on first launch after the upgrade to pick up the new defaults; choices made after that migration are never rewritten
- Relaunching SyncPilot while its window is hidden now restores the running instance instead of starting a second one — on GNOME sessions without the AppIndicator extension, where the tray icon cannot appear, the desktop launcher is still a way back to the window

## [0.2.2] - 2026-09-29

### Fixed

- The app now finds an rslsync binary installed at `~/.local/bin` even when the desktop session PATH does not include it (the default on stock GNOME) — previously the first-run download was offered even though the binary from an earlier install was present
- The first-run rslsync download retries transient CDN failures (3 attempts) and the failure message now names the URL and suggests checking the network or installing manually

## [0.2.1] - 2026-09-29

### Fixed

- A foreign daemon holding SyncPilot's port is no longer adopted: port probing now distinguishes compatible / foreign / absent, and a credentials mismatch (e.g. a leftover systemd service) surfaces as an actionable error on the boot page instead of a silently unusable session
- The boot page shows the actual failure reason and retries only on click, so real errors can no longer loop behind an auto-retry

### Added

- The settings window now checks the release feed for updates (manual button plus an automatic check on open); AppImage builds install the update in place and restart, deb/rpm installs are pointed at the release page — this closes the loop on the updater infrastructure shipped in 0.2.0

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
