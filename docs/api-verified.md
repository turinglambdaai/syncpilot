# rslsync Web UI API — verified against 3.1.2 (Linux)

Transcript of the live verification that drove the rewrite of
`src-tauri/src/api.rs`. Facts below were probed with
`scripts/verify-api.sh` against the official `rslsync` 3.1.2 binary on
Ubuntu; anything still uncertain is marked so.

## Protocol (all verified)

- Transport: the Web UI server on `127.0.0.1:<port>` speaks **HTTP basic
  auth** (`WWW-Authenticate: Basic realm="Resilio Sync"`). Every request
  must carry the credentials; there is no login endpoint.
- CSRF token: `POST /gui/token.html?t=<ms>` returns
  `<html><div id='token' style='display:none;'>TOKEN</div></html>` — the
  official Web UI extracts `>([^<]+)<`; so do we. The token is **bound to
  the HTTP session**: it must be requested and used with the same cookie
  jar (the client keeps a cookie store). A valid token presented without
  its session cookie answers `invalid request` like a stale one.
- Action call: `GET /gui/?token=<TOK>&action=<name>&<params>&t=<ms>`.
  A stale/missing token answers **HTTP 400** with body `invalid request`;
  refresh the token and retry once. Wrong credentials answer **HTTP 401**
  with an empty body.
- Success envelope: `{"status":200,"value":…}`. Exceptions: `getsyncfolders`
  replies `{"folders":[…],"status":200}` and `adddir` replies
  `{"path":"…"}` — no `value` wrapper.
- Error envelopes: business errors answer **HTTP 500** with
  `{"error":"…message…","status":500}`; some actions (e.g. `addlink`)
  answer HTTP 200 with the error **nested inside `value`**
  (`{"status":200,"value":{"error":205,"message":"SE_SM_NO_IDENTITY"}}`).
- Speed charts: `getchartdata&type=N&from=0&to=0` →
  `{"value":[{"time":…,"value":…},…]}`, newest first. Chart types from the
  official Web UI code: `DOWNSPEED:1, UPSPEED:2, CPU:0`.

## Conf-file requirements (3.x)

- `"agree_to_EULA": "yes"` is **mandatory** — without it the daemon exits
  immediately (this broke the app-spawned daemon on 3.1.2).
- Do **not** set `webui.api_key`: the 3.x binary validates it against
  Resilio-issued keys (signed, versioned, revocation-checked — the binary
  strings include `API: invalid key size/signature/version` and
  `/check_api_key.php`). Any locally generated key is rejected **at
  startup**. Without the field the daemon starts fine and the action API
  authenticates via basic auth.
- No `api_key` at all also works on the 2.x-era Web UI, so this stays
  compatible if the client is ever pointed at an older daemon.

## Action surface (verified responses)

| action | params | verified response |
|---|---|---|
| `version` | — | `{"value":"3.1.2 (1076)"}` |
| `getsysteminfo` | — | `value.hostname/os/username/…` |
| `getappinfo` | — | `value.branding/install/placeholders_enabled` |
| `getlicenseinfo` | — | `value.allowed_to_sync/valid/can_use_trial/…` |
| `settings` | — | `value.dlrate/-1=unlimited, ulrate, devicename, listeningport, webui_port, …` |
| `setsettings` | `ulrate`, `dlrate` (KB/s, `-1` = unlimited) | `{"status":200}`; read-back round-trips |
| `getsessionstats` | — | `value.max_speed/transferred/total_transferred` (`down`/`up`) |
| `getchartdata` | `type`, `from`, `to` | `value: [{time,value},…]` |
| `getsyncfolders` | `discovery=1` | `{"folders":[…],"status":200}` |
| `getsyncjobs` | — | `value.jobs` |
| `getpeersstat` | — | `value: []` (no peers connected) |
| `secret` | — | `value.secret/readonlysecret/canencrypt/secrettype` |
| `adddir` | `dir` (must NOT exist) | `{"path":"…/"}` |
| `addsyncfolder` | `path` | `{"error":700,"message":"SE_NO_LICENSE"}` when locked |
| `addlink` | `link` | nested `{"error":205,"message":"SE_SM_NO_IDENTITY"}` when locked |
| `parselink` | `link` | HTTP 500 `{"error":"invalid link"}` for a bad key |
| `knownhosts` | `id` (folder id) | folder-scoped peers; `{"error":"can't find folder by folderid"}` otherwise |
| `removefolder` | `folderid` | unverified shape (no folder available to remove) |
| `starttrialperiod` | — | `{"status":200}`; flips `allowed_to_sync` to true |
| `shutdown` | — | `{"status":200}`; daemon exits |

Not present in the 3.x action set (extracted from the official Web UI
bundle): **global pause/resume and per-folder pause**. The GUI's pause
controls are removed/disabled accordingly.

## 3.x licensing gate (important product behavior)

Fresh daemon: `getlicenseinfo → {"allowed_to_sync":false,"can_use_trial":true}`.
While locked:

- `adddir` answers `{"path":…}` but the folder never registers (silent
  no-op — no `.sync` dir created, `getsyncfolders` stays empty);
- `addlink`/`addsyncfolder` fail with `SE_SM_NO_IDENTITY` /
  `SE_NO_LICENSE`;
- `starttrialperiod` activates a 14-day trial and `allowed_to_sync`
  becomes true.

Even after activation, adding folders from a fresh daemon still requires
the account **identity** setup the official UI performs; a headless
`adddir` may still not register. SyncPilot therefore surfaces license
state (`license_state` command → banner on the overview page) instead of
guessing. Joining an existing share with a valid key after activation is
the flow expected to work (`addlink` + `dir`).

## Open questions (to re-verify with an activated daemon)

- Exact `getsyncfolders` item field names (`id` vs `folderid`, `ispaused`…).
- `knownhosts` item shape for a folder with real peers.
- `removefolder` success shape.
- Whether `adddir` registers once the daemon has a full account identity
  (the 14-day trial alone was not sufficient on the probe box).
