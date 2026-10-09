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

- The artifact downloader does not follow 302 redirects yet
  (`get-pure-port` in `download-with-progress!`,
  `racket/syncpilot/updater.rkt`); upstream rivet#153 fixed only rivet's own
  downloader. Tracked as [#1](https://github.com/turinglambdaai/syncpilot/issues/1).
- No deb/rpm/AppImage packaging — updates swap only the extracted app
  directory.
