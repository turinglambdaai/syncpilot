#!/usr/bin/env bash
# Probe the real rslsync API on loopback using throwaway credentials and an
# isolated storage dir. Tries every candidate endpoint/method/body from the
# SyncPilot client (src-tauri/src/api.rs) and dumps full responses into
# verify-report.txt. Share that report so the Rust client can be aligned to
# facts.
#
# Usage:  bash scripts/verify-api.sh
#         RSLSYNC=~/.local/bin/rslsync bash scripts/verify-api.sh
set -u

PORT="${PORT:-48889}"
BASE="http://127.0.0.1:$PORT"
WORK="$(mktemp -d /tmp/syncpilot-verify.XXXXXX)"
REPORT="$WORK/verify-report.txt"
JAR="$WORK/cookies.txt"

say()  { printf '%s\n' "$*"; }
both() { printf '%s\n' "$*" | tee -a "$REPORT"; }

# ---- locate binary ----------------------------------------------------------
BIN="${RSLSYNC:-}"
if [ -z "$BIN" ]; then
  BIN="$(command -v rslsync || true)"
fi
if [ -z "$BIN" ] && [ -x "$HOME/.local/bin/rslsync" ]; then
  BIN="$HOME/.local/bin/rslsync"
fi
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  say "rslsync not found. install it first:  bash scripts/install-rslsync.sh"
  say "or point at it:  RSLSYNC=/path/to/rslsync bash scripts/verify-api.sh"
  exit 1
fi

# ---- throwaway credentials --------------------------------------------------
LOGIN="probe"
PASS="$(head -c 18 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 20)"
APIKEY="$(head -c 30 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 44)"
SHARE_A="$WORK/share-a"; mkdir -p "$SHARE_A"
SHARE_B="$WORK/share-b"; mkdir -p "$SHARE_B"

cat > "$WORK/rslsync.conf" <<EOF
{
  "device_name": "syncpilot-probe",
  "storage_path": "$WORK/storage",
  "webui": {
    "listen": "127.0.0.1:$PORT",
    "login": "$LOGIN",
    "password": "$PASS",
    "api_key": "$APIKEY"
  },
  "shared_folders": []
}
EOF

# ---- start daemon -----------------------------------------------------------
both "# SyncPilot rslsync API verification"
both "# binary: $BIN ($("$BIN" --version 2>/dev/null | head -1))"
both "# workdir: $WORK"
both "# (probe credentials are throwaway)"
both ""

"$BIN" --nodaemon --config "$WORK/rslsync.conf" >/dev/null 2>&1 &
PID=$!
cleanup() {
  kill "$PID" >/dev/null 2>&1
  wait "$PID" 2>/dev/null
  # leave the report; tell the user where it is
}
trap cleanup EXIT

say "waiting for $BASE ..."
UP=0
for _ in $(seq 1 60); do
  if curl -s -o /dev/null --max-time 2 "$BASE/"; then UP=1; break; fi
  if ! kill -0 "$PID" 2>/dev/null; then
    say "rslsync exited early — dumping storage dir logs if any:"
    ls -la "$WORK/storage" 2>/dev/null
    exit 1
  fi
  sleep 0.5
done
if [ "$UP" != "1" ]; then
  say "daemon did not come up on :$PORT"
  exit 1
fi
say "daemon is up. probing..."
both "## daemon up on :$PORT"
both ""

# ---- helpers ----------------------------------------------------------------
# probe <label> <curl args...> — prints HTTP code + body, appends to report
probe() {
  local label="$1"; shift
  local body code
  body="$WORK/last-body"
  code="$(curl -s -o "$body" -w '%{http_code}' --max-time 8 "$@")" || code="ERR"
  {
    echo "== $label"
    echo "HTTP $code"
    head -c 900 "$body" 2>/dev/null
    echo; echo
  } | tee -a "$REPORT"
  printf '%s' "$code"
}

FID=""

# ---- 0. unauthenticated behavior -------------------------------------------
probe "GET / (root)" "$BASE/"
probe "GET /api/v2/client (no auth)" "$BASE/api/v2/client"
probe "GET /api/v2/folders (X-API-Key)" -H "X-API-Key: $APIKEY" "$BASE/api/v2/folders"
probe "GET /api/v2/folders (no auth)" "$BASE/api/v2/folders"

# ---- 1. auth candidates -----------------------------------------------------
say "--- auth candidates"
C1=$(probe "POST /api/v2/token form (user/password)" -c "$JAR.t1" \
  -d "user=$LOGIN" -d "password=$PASS" "$BASE/api/v2/token")
C2=$(probe "POST /api/v2/token json username/password" -c "$JAR.t2" \
  -H "Content-Type: application/json" -d "{\"username\":\"$LOGIN\",\"password\":\"$PASS\"}" "$BASE/api/v2/token")
C3=$(probe "POST /api/v2/token json user/password" -c "$JAR.t3" \
  -H "Content-Type: application/json" -d "{\"user\":\"$LOGIN\",\"password\":\"$PASS\"}" "$BASE/api/v2/token")
C4=$(probe "GET /api/v2/token basic auth" -c "$JAR.t4" -u "$LOGIN:$PASS" "$BASE/api/v2/token")
C5=$(probe "POST /api/v2/auth/login form (2.x style)" -c "$JAR.t5" \
  -d "username=$LOGIN" -d "password=$PASS" "$BASE/api/v2/auth/login")

AUTH_JAR=""
for i in 1 2 3 4 5; do
  eval "code=\$C$i"
  case "$code" in 2??) AUTH_JAR="$JAR.t$i"; break ;; esac
done
if [ -n "$AUTH_JAR" ]; then
  cp "$AUTH_JAR" "$JAR"
  both "## RESULT: auth works via candidate $i (cookie jar copied to cookies.txt)"
else
  both "## RESULT: no auth candidate returned 2xx — credentials/API-key only?"
fi
both ""

# ---- 2. data endpoints ------------------------------------------------------
say "--- data endpoints"
probe "GET /api/v2/folders (with session cookie)" -b "$JAR" "$BASE/api/v2/folders"
probe "GET /api/v2/client (with session cookie)" -b "$JAR" "$BASE/api/v2/client"
probe "GET /api/v2/users" -b "$JAR" "$BASE/api/v2/users"
probe "GET /api/v2/owner" -b "$JAR" "$BASE/api/v2/owner"
probe "GET /api/v2/secret" -b "$JAR" "$BASE/api/v2/secret"
probe "POST /api/v2/secret" -b "$JAR" -H "Content-Type: application/json" -d '{}' "$BASE/api/v2/secret"
probe "GET /api/v2/client/settings" -b "$JAR" "$BASE/api/v2/client/settings"
probe "GET /api/v2/client/settings/advanced" -b "$JAR" "$BASE/api/v2/client/settings/advanced"
probe "GET /api/v2/events (2s)" -b "$JAR" --max-time 2 "$BASE/api/v2/events"

# ---- 3. add a folder, inspect shape ----------------------------------------
say "--- add folder"
C_ADD=$(probe "POST /api/v2/folders json {dir}" -b "$JAR" \
  -H "Content-Type: application/json" -d "{\"dir\":\"$SHARE_A\"}" "$BASE/api/v2/folders")
case "$C_ADD" in
  2??) ;;
  *) probe "POST /api/v2/folders json {path}" -b "$JAR" \
       -H "Content-Type: application/json" -d "{\"path\":\"$SHARE_B\"}" "$BASE/api/v2/folders" ;;
esac

FOLDERS_JSON="$WORK/folders.json"
curl -s -b "$JAR" "$BASE/api/v2/folders" -o "$FOLDERS_JSON" || true
if command -v python3 >/dev/null 2>&1; then
  FID="$(python3 -c '
import json,sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit()
def walk(o):
    if isinstance(o, dict):
        if "id" in o and ("dir" in o or "path" in o or "secret" in o):
            print(o["id"]); raise SystemExit
        for v in o.values(): walk(v)
    elif isinstance(o, list):
        for v in o: walk(v)
walk(d)
' "$FOLDERS_JSON" 2>/dev/null | head -1)"
else
  FID="$(grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' "$FOLDERS_JSON" | head -1 | sed 's/.*: *"//;s/"//')"
fi

if [ -n "$FID" ]; then
  both "## folder id: $FID"
  say "--- folder sub-endpoints (fid=$FID)"
  probe "GET /api/v2/folders/{fid}" -b "$JAR" "$BASE/api/v2/folders/$FID"
  probe "GET /api/v2/folders/{fid}/peers" -b "$JAR" "$BASE/api/v2/folders/$FID/peers"
  probe "GET /api/v2/folders/{fid}/users" -b "$JAR" "$BASE/api/v2/folders/$FID/users"
  probe "GET /api/v2/folders/{fid}/knownhosts" -b "$JAR" "$BASE/api/v2/folders/$FID/knownhosts"
  probe "GET /api/v2/folders/{fid}/files" -b "$JAR" "$BASE/api/v2/folders/$FID/files"
  probe "PATCH /api/v2/folders/{fid} {paused:true}" -b "$JAR" -X PATCH \
    -H "Content-Type: application/json" -d '{"paused":true}' "$BASE/api/v2/folders/$FID"
  probe "PATCH /api/v2/folders/{fid} {paused:false}" -b "$JAR" -X PATCH \
    -H "Content-Type: application/json" -d '{"paused":false}' "$BASE/api/v2/folders/$FID"
  probe "POST /api/v2/folders/{fid}/link" -b "$JAR" \
    -H "Content-Type: application/json" -d '{"permissions":2,"timelimit":"60","askapproval":0}' \
    "$BASE/api/v2/folders/$FID/link"
  probe "DELETE /api/v2/folders/{fid}" -b "$JAR" -X DELETE "$BASE/api/v2/folders/$FID"
else
  both "## no folder id found — add-folder candidates failed, check bodies above"
fi

# ---- 4. shutdown ------------------------------------------------------------
say "--- shutdown"
probe "POST /api/v2/client/shutdown" -b "$JAR" -H "Content-Type: application/json" -d '{}' "$BASE/api/v2/client/shutdown"

both ""
both "## report end — share this whole file"
say ""
say "report: $REPORT"
say "paste the report back (or open an issue with it) so api.rs can be aligned."
