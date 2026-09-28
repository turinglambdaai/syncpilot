# Changelog

All notable changes to SyncPilot are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning: [SemVer](https://semver.org/).

## [Unreleased]

### Fixed

- Generated `rslsync.conf` now sets `"agree_to_EULA": "yes"` — rslsync 3.x exits immediately without it, so app-spawned daemons never started on 3.1.2
- The conf no longer writes an `api_key`: rslsync 3.x validates keys against Resilio-issued signed keys and refuses to start on a locally generated one
- `AppSettings::load` no longer forks credentials on first run: it used to persist one random password and return a second, leaving the app unable to authenticate to its own daemon until the next launch (verified live on a fresh install)

### Changed

- API client rewritten from the `/api/v2` REST surface (which only accepts Resilio-issued keys) to the Web UI action API the official client uses: `POST /gui/token.html` for a CSRF token + `GET /gui/?token=…&action=…` with HTTP basic auth. Verified live against rslsync 3.1.2; transcript in `docs/api-verified.md`
- Speed limits use the verified `setsettings&ulrate/dlrate` shape (KB/s, `-1` = unlimited); read-back via `settings`
- Live transfer rates come from the speed charts (`getchartdata`, DOWNSPEED=1 / UPSPEED=2 per the official Web UI); daemon version is cached from `action=version`
- Pause/resume controls removed — rslsync 3.x exposes no global or per-folder pause action
- `scripts/verify-api.sh` rewritten to probe the action API (token, envelope errors, charts, license, folder lifecycle, settings round-trip, shutdown)

### Added

- 3.x licensing gate surfaced to the UI: overview banner with daemon activation state (`getlicenseinfo.allowed_to_sync`) and a one-click free-trial start (`starttrialperiod`)

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
