# Changelog

All notable changes to SyncPilot are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning: [SemVer](https://semver.org/).

## [Unreleased]

## [0.6.1]

### Fixed

- The update check follows HTTP redirects (rivet#153): GitHub release
  assets answer with a 302 to their CDN, so every in-app update check
  failed at signature verification. No app changes; rebuilt on the
  fixed rivet.


## [0.6.0] - 2026-10-09

### Added

- **Online updates (Linux)**: SyncPilot updates itself now, on the family's signed-manifest flow. Once a day (throttled in the backend) it silently checks an Ed25519-signed channel manifest — verified before parsing against the embedded public key (`syncpilot-2026-10`) — and asks before downloading anything. Consent → progress dialog → the verified tar.gz lands under `~/.local/share/site.jrtx.syncpilot/updates/` with an open-folder handoff; applying it stays a manual extract over the app directory, and rslsync state (config, storage, credentials, keys) is never touched by an update. **Check for updates** lives in a new Settings card and bypasses the daily throttle. Downloads enforce the signed byte size and SHA-256 before the file is trusted; release manifests can stage rollouts via a sticky per-install bucket

### Changed

- Releases are built by `raco rivet release` instead of a hand-rolled tar step: the shipped `tar.gz` is the rivet-verified package, accompanied by the signed `update-stable.json` manifest, an SBOM and `THIRD_PARTY_NOTICES.txt` in CI

## [0.5.1] - 2026-10-08

### Added

- **The tray is back**: SyncPilot hosts a `rivet::system::TrayIcon` (StatusNotifierItem + dbusmenu, shipped by rivet f37908f / [#130](https://github.com/turinglambdaai/rivet/pull/130)) with an 打开 / 设置 / 退出 menu (zh/en). Closing the window hides it to the tray instead of quitting — the desktop convention the official clients follow — with the setting honored from day one of the rebuild and the "Hide to tray on close" row in Settings live again (insensitive only on sessions where no tray watcher exists). The tray icon uses the themed `emblem-synchronizing` glyph for now; branded art is a follow-up
- Settings changes now reach the main window live: saving the settings window updates the close-to-tray behavior immediately, no restart needed

### Fixed

- `find-binary`'s well-known probe paths and PATH are injectable parameters, and the manager test that assumed a machine without a real rslsync now passes everywhere (it failed on any machine with `~/.local/bin/rslsync` present)
- The no-WebKit build (`HAVE_WEBKIT` unset) compiles again: the browser-handoff path used the GTK3-only `gtk_get_current_event_time`
- CI pins the rivet dependency to a fixed commit (`RIVET_PKG_SOURCE`) — builds no longer float on rivet main

## [0.5.0] - 2026-10-08

### Changed

- **SyncPilot is rebuilt on [Rivet](https://github.com/turinglambdaai/rivet)**: one Racket domain core (daemon manager, conf generation, auth-injecting proxy, settings, first-run installer) driving a first-party GTK4 + WebKitGTK 6.0 host over typed RPC. The host only renders and interacts — all logic lives in the backend. The previous Tauri 2 stack is removed from the tree; it remains on the v0.4.0 tag for reference
- **Drop-in upgrade**: data paths and formats are byte-identical with 0.4.x (`~/.local/share/site.jrtx.syncpilot`) — settings, device identity and the daemon config carry over untouched
- Distribution is now a plain `tar.gz` (Linux x86_64, Ubuntu 24.04+ for WebKitGTK 6.0); releases are built and launch-smoked by CI, which also integration-smokes the real chain (pinned rslsync spawn, Web UI on `127.0.0.1:38889`, proxy answering for `/gui/`)

### Removed

- The tray icon and hide-to-tray on close: rivet has no Linux tray contract yet ([turinglambdaai/rivet#118](https://github.com/turinglambdaai/rivet/issues/118)); closing the window now quits (the keep-daemon-on-exit setting is honored, so syncing continues in the background)
- The in-app updater (deb pkexec flow and AppImage in-place update): pending the rivet signed-manifest update flow; update via the release page for now

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
