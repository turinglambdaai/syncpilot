# Changelog

All notable changes to SyncPilot are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning: [SemVer](https://semver.org/).

## [Unreleased]

### Fixed

- **The SHA-256 helper no longer loads an unversioned libcrypto on macOS.**
  `httputil.rkt`'s native SHA-256 shortcut opened bare `libcrypto`; current
  macOS releases make dyld abort the whole process on the unversioned
  `/usr/lib/libcrypto.dylib` stub, which killed every process that merely
  required the module (the test suite included) — the exception handler
  never sees a dyld-level abort. macOS now resolves versioned names only
  (Racket's bundled `libcrypto.3`); Linux keeps the unversioned fallback.
- **The embedded official UI renders again in desktop mode**: the desktop bridge's `callapi` method answered a hardcoded `null` ("no entries are reachable in this UI build") — true for the UI it was written against, false since the daemon's Web UI moved its whole data plane into the desktop bridge (with `window.btsync` present, the UI's jQuery.ajax override routes every `/gui/` and `/api/` request through `callapi` and never speaks HTTP to the proxy, so the stub left the interface with no data at all: a blank window). `callapi` now forwards `{action, params, type}` to the same origin the web view loads — the auth-injecting proxy — over a libsoup session and answers with the daemon's response; transport and HTTP failures surface as `{"error": …}` results rather than rejected promises (a rejection crashes the UI's request wrapper on a missing `.error` field). The request finishes when the daemon answers, so the ~30s core-events long poll passes through untouched.

## [0.8.3] - 2026-10-15

The release-hygiene round: everything below tightens how SyncPilot ships
and reports itself — feedback surfaces and release gates, no change to the
app's own behaviour.

### Added

- **GitHub issue templates** (bug report + feature request) so feedback
  lands structured: the bug form asks for the distro/desktop-environment
  pair, the package shape and the rslsync binary provenance — the three
  facts every Linux-only report needs — and points update failures at the
  now-copyable dialog text. The manual (syncpilot.jrtx.site/guide.html)
  is offered as a contact link before a blank issue.
- **The release ships the signed feed under both names.** Release assets
  carry `update-stable.json` — what shipped since 0.7.0 and what current
  hosts still fetch — plus its byte-identical twin `update-manifest.json`
  (the family-standard feed name; the signature covers the payload, not
  the filename, so both verify). Zero client change this round; the twin
  exists so the feed name can migrate client-side later without
  re-releasing.

### Changed

- **The About card names the issue tracker.** The About text now ends
  with `github.com/turinglambdaai/syncpilot/issues` (zh and en, plain
  text in the i18n single source), beside the existing repo link — a bug
  report starts one glance away from the About card that describes it.
- **Update failure text is selectable.** The update dialogs' message
  label (errors and status alike) is a selectable GTK label, so the exact
  failure text — URLs, errno strings — can be copied out instead of
  retyped.
- **CI single-sources the rivet pin**: both workflows declare a
  workflow-level `RIVET_PIN` env and every `raco pkg install` references
  it, so a rivet bump is one edit per file (the `setup-embed-racket`
  `uses:` pins stay literal — GitHub does not allow expressions there).
  `setup-racket` rides along at v1.15.

### Fixed

- **The release preflight gates the generated client's version stamp.**
  `check-release-version.sh` now reads `kVersion` from
  `linux/GeneratedBackend.hpp` and requires it to equal `VERSION` (the
  GeneratedBackend.swift gate autarx already had, ported) — 0.8.2 shipped
  while the hpp still stamped 0.8.0 and nothing checked it. The stamp was
  corrected after the fact, so this release is the first whose generated
  client matches its version on day one; four gates (VERSION ==
  rivet.rktd == updater identity == generated stamp, plus tag and
  CHANGELOG) now stand between main and a mislabeled release.

## [0.8.2] - 2026-10-14

### Added

- **User manual on the product site** (`docs/guide.html`, linked from the nav as 手册): a five-minute start (per-format install → first-run fetch of the official rslsync binary → the official Web UI → daemon and settings), the core features (daemon start/stop and adoption, the crash watchdog and its status phases, config editing — including why hand edits to `rslsync.conf` never survive a daemon start, the loopback auth-injecting proxy, autostart and tray), and an FAQ (where data lives, root, the honest Linux-only platform story with desktop-environment differences, language and theme, updates — including how 0.7.x installs ride the same `update-stable.json` feed and why 0.6.1-and-earlier must update manually once — and uninstall). Same family mechanism as the landing page: one self-contained file, `data-i18n` keys resolved against a JS dictionary, defaulting to Chinese, with the shared light/dark theme. It cites the real product screenshot; no app functionality changes in this release.

### Changed

- **The site states the real asset matrix**: the hero trust row now lists zip beside deb · rpm · AppImage · tar.gz — the portable zips have shipped in every release since 0.7.0 — and the nav gains the manual link.
- **docs/UPDATE.md caught up with 0.7.0**: its "known gaps" still claimed the artifact downloader ignores 302 redirects (fixed in 0.7.0, [#1](https://github.com/turinglambdaai/syncpilot/issues/1)) and that no deb/rpm/AppImage packaging exists (shipped since 0.7.0/0.8.0). It now states the one gap that remains: updates never self-replace, with the per-format apply path.

## [0.8.1] - 2026-10-14

### Added

- **UI language setting, follow-system by default**: Settings → Desktop gains a language row offering 跟随系统 / Follow system, 简体中文 and English — the entries render in both scripts regardless of the active UI language, so someone facing an all-zh window (what every install got until now: the language variable existed but nothing ever moved it off zh) can still find and read the row. `system` (the new default) resolves from the session locale at startup — zh-family sessions get zh, everything else en — so first impressions match the user's desktop instead of the author's. The choice persists as `language` in syncpilot-settings.json (pre-existing files fall back per the usual serde(default) semantics, no migration stamp needed) and applies on the next launch; saving it toasts the restart hint, same pattern as the port change.
- **Desktop integration bridge for the official UI** (`window.btsync`): the official client injects this object into its embedded web view and the UI routes every desktop behavior through it — double-clicking a synced folder opens the file manager at that folder (until now an explanation dialog appeared instead), adding a folder uses the native directory chooser, share links and docs hand off to the browser, notifications leave the page, and copy buttons reach the real clipboard. A web-process extension defines the object in the page world at document start (UserContentManager user scripts miss the first document on WebKitGTK 2.52), calls ride a custom `syncpilot-bridge://` scheme whose handler does the native work, and the WebKit user agent carries the official `SyncWebKitWebView` marker so the UI's WebKit code path engages.
- **Product site dark theme**: a full dark palette (family keepsake values) driven by `data-theme` on `<html>`, resolved before first paint from `localStorage` or the system preference (no flash), with a `◐` toggle that persists the explicit choice — plus the family warm palette in light mode, replacing the old Apple-blue/`#F5F5F7` look.

### Fixed

- **The first-run rslsync installer works again**: `http-fetch` ran `bytes->string/utf-8` over the status value that `get-pure-port/headers` `#:status? #t` already returns as a string, so every successful 200 response died on a contract violation — the download card failed unconditionally on every machine, with the retry loop dressing it up as a network error ("check your network connection"). The status parsing now accepts the string shape (bytes kept as a guard for older net/url revisions) in a `response-code` helper covered by its own tests.
- **SIGTERM shuts the app down instead of killing the backend under a living window** ([#3](https://github.com/turinglambdaai/syncpilot/issues/3)): OS signals bypass the GTK main loop, so the orderly teardown never ran — `systemd --user stop`, session logout and `killall` all left a zombie window over a dead backend. The rivet shutdown hook is now installed once the embedded runtime finishes booting: installing in `main()` loses the race to the Racket runtime's own SIGTERM handler, which is what kept the hook inert. Teardown is exactly-once across the GTK and signal paths, and each step traces into the host log.
- **README described a tar.gz-only world that ended in 0.7.0**: the "Honest gaps" entry claiming no deb/rpm/AppImage packaging and the Install section's "that tarball is the only artifact — Linux x64 only" were both stale; Install now documents the real per-architecture matrix (deb · rpm · AppImage · tar.gz · zip, x64 + arm64, with `SHA256SUMS`, SBOM, notices and the signed update manifest). The product-site URL is also gone from the README header — the GitHub About field is the single home for it.

### Changed

- **Rivet is consumed as a package, pinned to v0.11.0**: the Linux host CMake no longer hand-copies rivet's 14 platform translation units into its executable list — it `add_subdirectory`s the installed Rivet platform and links `rivet::platform` (the rivet#238 contract taskly already follows), so rivet adding a translation unit needs no downstream change. CI and release install the package from the tag-pinned Git source `https://github.com/turinglambdaai/rivet.git#v0.11.0` and use the `setup-embed-racket` action at `@v0.11.0` — the hold-back form rivet docs/ci.md prescribes for releases (the package catalog has one moving entry per name and no version selector, so catalog floating was never a release pin).
- **Product site defaults to Chinese** (`lang="zh-CN"`) with the family i18n mechanism: `data-i18n` keys resolved against a JS dictionary instead of per-element `data-en`/`data-zh` attributes, `<title>`/meta description following the active language; explicit choice still persists, otherwise the browser locale decides. Still one self-contained file, zero dependencies.

## [0.8.0]

### Added

- **RPM packages for both Linux architectures** (`syncpilot-<version>-<build>-linux-x86_64.rpm`, `...-aarch64.rpm`), built by rivet's native rpmbuild path from the same payload as the deb and AppImage — the Linux set now matches the family benchmark (taskly) format-for-format: deb + rpm + AppImage + tar.gz + zip per architecture. Each rpm ships with a `.sha256` sidecar and rides the same `SHA256SUMS`

## [0.7.0]

### Added

- **Native Linux packaging, two architectures**: releases now ship `deb` and `AppImage` installers beside the `tar.gz` for both `linux-x64` and `linux-arm64` (arm64 builds on GitHub's `ubuntu-24.04-arm` with rivet's cached embeddable Racket CS; the backend's `crypto` dependency is installed into that minimal runtime explicitly). The AppImage carries its own GTK4 dependency closure so it runs on distributions older than the build image; the deb installs under `/opt/syncpilot` with a desktop entry and the branded icon (`assets/icon-512.png`, scaled from the app icon). Every release also publishes a combined `SHA256SUMS`
- The portable zip that rides along with every installer since rivet 0.6.1 is now part of the published asset set too

### Fixed

- **The updater's artifact download follows HTTP redirects** ([#1](https://github.com/turinglambdaai/syncpilot/issues/1)): the hand-rolled `get-pure-port` call saved the empty 302 body GitHub serves before the CDN redirect and failed the signed size/SHA-256 check — the same trap rivet#153 fixed for the manifest fetch, which is why the check succeeded and the download then broke. Covered by a loopback regression test that 302s onto a real payload. Note for 0.6.1 users: the broken downloader ships in your build, so the in-app update to 0.7.0 fails at download — update manually this one time; from 0.7.0 on, auto-update works

### Changed

- CI and release pin rivet to 0.6.1 (`410fc7c`) — the first release line with native Linux `deb`/`AppImage` packaging (`linux-formats` in rivet.rktd) and family-named portable zips
- `update-stable.json` is now signed in the release publish job (`scripts/make-update-manifest.sh`, same Ed25519 key and key id `syncpilot-2026-10`) with one `targz` artifact per architecture and versioned download URLs — same schema-1 manifest contract 0.6.1 clients already verify; rivet 0.6.1's built-in manifest points at the portable zip instead, which the updater does not consume

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
