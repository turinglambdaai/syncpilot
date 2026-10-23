# SyncPilot updates

The contract of SyncPilot's in-app updater (built on `rivet/distribution`).
This page is the single source of truth; the README summarizes it.

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

## Apply (manual)

- **Applying an update is a manual step**: extract the verified
  `syncpilot-<version>-linux-x64.tar.gz` over the app directory and restart
  `RivetHost`. The updater deliberately never self-replaces.
- The updater only ever writes under `<data-dir>/updates`. The daemon's
  state (`~/.local/share/site.jrtx.syncpilot` — `rslsync.conf`, `storage/`,
  settings) is never touched by an update.

## Known gaps

- **Updates don't self-replace** — the verified `tar.gz` lands under
  `<data-dir>/updates`; applying it stays a manual extract over the app
  directory (tar.gz/zip installs), while deb/rpm installs update by simply
  installing the new package. Either way the daemon's state
  (`~/.local/share/site.jrtx.syncpilot`) is never touched.

## 当前交付优先级（2026-10-23）

Linux 维护模式：只补第三方兼容、鉴权/进程恢复、安装形态的验证更新交接与反馈；不新增平台/云/收费层。

执行场景与完成标准见[本仓审查 issue](https://github.com/turinglambdaai/syncpilot/issues/10)及家族[交付标准](https://github.com/turinglambdaai/turinglambdaai.github.io/blob/master/docs/PRODUCT-STANDARD.md)。未完成的跨平台、硬件或真实支付验证仍是显式门禁；本节不表示这些验证已通过。后续一次认领一个切片，证据回填本文件与 issue。
