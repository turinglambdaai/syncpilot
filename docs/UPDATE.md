# SyncPilot updates

The contract of SyncPilot's in-app updater (built on `rivet/distribution`).
This page is the single source of truth; the README summarizes it.

**English** · [简体中文](UPDATE.zh-CN.md)

## Feed

- Channel: `stable` — the signed channel manifest is **`update-stable.json`**,
  fetched from the moving
  `https://github.com/turinglambdaai/syncpilot/releases/latest/download`
  location. Artifact URLs *inside* the manifest are pinned to the concrete
  release tag.
- The manifest is **Ed25519-signed** (key id `syncpilot-2026-10`). The public
  key is embedded in the app (`racket/syncpilot/version.rkt`); manifests that
  fail signature verification — or that carry the size/SHA-256 of an
  unsigned file — are rejected before anything is offered or downloaded.
- Each GitHub release also ships a plain `<tarball>.sha256` sidecar for
  manual verification.

## Check

- A **silent auto-check runs once a day** at startup. It is throttled in the
  backend (`app/backend.rkt`): a check younger than 24 hours returns
  `throttled` without touching the network, and every completed check stamps
  `last-update-check-at` into settings.
- A manual check from the UI (`force`) always runs and bypasses the throttle.

## Download

- An available update is downloaded **in-app, on a background thread**, with
  progress surfaced to the UI through the `update-state` RPC.
- Before the download is trusted, its size and SHA-256 are verified against
  the signed manifest.
- Downloads are capped by a maximum-artifact-size guard; the partial file
  (`.partial`) is discarded on any failure.

## Apply — what the updater does, per install format

The updater never installs anything, and no dialog claims it did. It
verifies an update and hands you the verified
`syncpilot-<version>-linux-<arch>.tar.gz` — the dialog shows the file path
(selectable) with an open-folder button and says the next step is yours.
What that step is depends on how SyncPilot was installed:

| Install format | Update handoff |
|---|---|
| **tar.gz / zip** (portable) | Extract the verified tar.gz over the app directory and restart `RivetHost`. |
| **deb** | Download the new `.deb` from the release page and install it over the old one: `sudo apt install ./syncpilot-<version>-linux-amd64.deb`. |
| **rpm** | Same via the package manager: `sudo dnf install ./syncpilot-<version>-linux-x86_64.rpm` (or `zypper in ./…rpm`). |
| **AppImage** | Download the new AppImage from the release page and replace the old file. Release assets carry `.sha256` sidecars — check before swapping. |

For deb, rpm and AppImage installs the in-app verified tar.gz is the update
*signal* — it proves a new version exists and is intact — while the package
manager or the file swap does the replacing. Every release ships `.sha256`
sidecars per asset plus a combined `SHA256SUMS` for exactly this manual
verification.

The updater only ever writes under `<data-dir>/updates`. The daemon's state
(`~/.local/share/site.jrtx.syncpilot` — `rslsync.conf`, `storage/`,
settings) is never touched by an update, and no update path self-replaces
the running app.

## Recovery and failure modes

- **Daemon crash.** With the default `restart-on-crash: true` a watchdog
  restarts the daemon with exponential backoff — 2 s, doubling, capped at
  60 s — while a manual stop is honored and never "restarted". With the
  setting off, the daemon status flips to *crashed* ("daemon exited
  unexpectedly") instead. Evidence: `racket/tests/manager-test.rkt`.
- **Port already taken.** If the configured Web UI port answers with
  different credentials (a leftover system service, another user's daemon),
  SyncPilot refuses to adopt it and fails explicitly: the error names the
  port and both remedies — quit the foreign daemon, or change SyncPilot's
  port under tray → SyncPilot Settings. A daemon SyncPilot cannot
  authenticate is never driven blindly. Evidence: `manager-test.rkt`
  (foreign-daemon cases).
- **rslsync missing / first-run download failure.** The boot page offers the
  sha256-pinned CDN download; it retries transient failures 3 times (2 s,
  4 s backoff) and then shows an actionable error (network hint or manual
  install + Settings path) — a bug in the fetcher can no longer masquerade
  as a network error. Evidence: `racket/tests/install-test.rkt`.
- **Exit and uninstall keep your data.** Everything that matters lives in
  `~/.local/share/site.jrtx.syncpilot` (settings, `rslsync.conf`,
  `storage/`) plus `~/.local/bin/rslsync` when the first-run installer put
  it there. Uninstalling the app (deb/rpm remove, deleting the AppImage or
  the portable directory) removes only the app payload; the data directory
  survives until you delete it yourself. With `keep-daemon-on-exit` the
  daemon detaches and keeps syncing; otherwise it is shut down through its
  API (then killed as a last resort). Evidence: `settings-test.rkt`,
  `manager-test.rkt` (keep/stop paths).
- **Failure text is redacted.** Errors surface ports, paths, HTTP/errno
  strings and remediation — never credentials, tokens or sync
  configuration. The generated `rslsync.conf` (mode 0600) is the only file
  holding the Web UI credentials; the loopback proxy injects them per
  request and does not log headers. Update-dialog text is selectable so it
  can be copied without retyping. Evidence: error-string audit across
  `manager.rkt` / `install.rkt` / `updater.rkt`, `proxy-test.rkt`.

## Trust boundary

SyncPilot's own surface is loopback-only: the daemon binds
`127.0.0.1:<port>` with app-generated credentials, and the proxy that the
web view loads listens on `127.0.0.1` with an ephemeral port, injecting
those credentials per request — the daemon never serves an unauthenticated
request, and nothing but the official rslsync ever touches your keys or
files. SyncPilot itself has no account, no license check, no telemetry and
no update gating: signature verification is the only gate, and it exists to
protect you, not to sell to you.

## Known gaps

- **Updates don't self-replace** — the verified `tar.gz` lands under
  `<data-dir>/updates`; applying it stays a manual step per the matrix
  above. Either way the daemon's state
  (`~/.local/share/site.jrtx.syncpilot`) is never touched.

## 当前交付优先级（2026-10-23）

Linux 维护模式：只补第三方兼容、鉴权/进程恢复、安装形态的验证更新交接与反馈；不新增平台/云/收费层。

执行场景与完成标准见[本仓审查 issue](https://github.com/turinglambdaai/syncpilot/issues/10)及家族[交付标准](https://github.com/turinglambdaai/turinglambdaai.github.io/blob/master/docs/PRODUCT-STANDARD.md)。未完成的跨平台、硬件或真实支付验证仍是显式门禁；本节不表示这些验证已通过。后续一次认领一个切片，证据回填本文件与 issue。

切片 2026-10-24（更新交接 + 恢复文档）：已交付——上文各安装形态交接矩阵、恢复与故障模式、信任边界三节，验证证据见 issue #10 结单评论。
