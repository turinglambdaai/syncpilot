# Changelog

All notable changes to SyncPilot are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning: [SemVer](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-09-28

### Added

- Daemon lifecycle: start/stop, adopt an already-running rslsync, crash watchdog with exponential backoff, optional keep-running-on-exit
- Folder management: add by share key, create new with generated read & write / read-only keys, per-folder pause/resume, remove (files stay on disk)
- Peer visibility: connection state, sync progress, per-peer transfer speeds
- Global pause/resume and up/down speed limits
- Live transfer-rate graph on the overview page
- Tray icon with quick actions (open, pause/resume syncing, quit), hide-to-tray on close, XDG autostart
- Loopback-only Web UI with app-generated credentials and `0600` rslsync.conf
- CI (fmt/clippy/test) and release pipeline building deb/rpm/AppImage for x86_64 and aarch64
