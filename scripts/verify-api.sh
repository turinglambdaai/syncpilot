#!/usr/bin/env bash
# Probe the real rslsync Web UI "action" API on loopback using throwaway
# credentials and an isolated storage dir, and dump every response into
# verify-report.txt.
#
# The verified protocol (see docs/api-verified.md):
#   POST /gui/token.html               -> CSRF token inside an HTML div
#   GET  /gui/?token=T&action=A&…      -> {"status":200,"value":…} | error
# Every request carries HTTP basic auth. rslsync 3.x additionally requires
# "agree_to_EULA" in the conf and gates folder operations on license state.
#
# Usage:  bash scripts/verify-api.sh
#         RSLSYNC=~/.local/bin/rslsync bash scripts/verify-api.sh
set -u

PORT="${PORT:-48889}"
BASE="http://127.0.0.1:$PORT"
WORK="$(mktemp -d /tmp/syncpilot-verify.XXXXXX)"
REPORT="$WORK/verify-report.txt"

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
NEWDIR="$WORK/new-folder"        # adddir wants a path that does NOT exist yet
# rslsync 3.x refuses to start if storage_path does not exist yet.
mkdir -p "$WORK/storage"

cat > "$WORK/rslsync.conf" <<EOF
{
  "device_name": "syncpilot-probe",
  "storage_path": "$WORK/storage",
  "agree_to_EULA": "yes",
  "webui": {
    "listen": "127.0.0.1:$PORT",
    "login": "$LOGIN",
    "password": "$PASS"
  }
}
EOF

# ---- start daemon -----------------------------------------------------------
both "# SyncPilot rslsync API verification (action API)"
both "# binary: $BIN"
both "# workdir: $WORK"
both "# (probe credentials are throwaway)"
both ""

"$BIN" --nodaemon --config "$WORK/rslsync.conf" >/dev/null 2>&1 &
PID=$!
cleanup() {
  kill "$PID" >/dev/null 2>&1
  wait "$PID" 2>/dev/null
}
trap cleanup EXIT

say "waiting for $BASE ..."
UP=0
for _ in $(seq 1 60); do
  if curl -s -o /dev/null --max-time 2 "$BASE/"; then UP=1; break; fi
  if ! kill -0 "$PID" 2>/dev/null; then
    say "rslsync exited early — a conf field is usually to blame:"
    say "  (agree_to_EULA required on 3.x; do NOT set api_key)"
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

AUTH="$LOGIN:$PASS"
JAR="$WORK/cookies.txt"

# ---- token ------------------------------------------------------------------
TOK="$(curl -s -u "$AUTH" -c "$JAR" -X POST "$BASE/gui/token.html?t=$(date +%s%3N)" \
  | grep -oE ">[^<]+<" | tr -d '><' | tail -1)"
if [ -z "$TOK" ]; then
  both "## RESULT: could not extract CSRF token — check basic-auth credentials"
  exit 1
fi
both "## RESULT: csrf token acquired (${#TOK} chars)"
both ""

# ---- action probe helper ----------------------------------------------------
# act <action> [params...] — GET /gui/?token=…&action=…&params…
act() {
  local action="$1"; shift
  local url="$BASE/gui/?token=$TOK&action=$action&t=$(date +%s%3N)"
  local p
  for p in "$@"; do url="$url&$p"; done
  {
    echo "== action=$action $*"
    curl -s -u "$AUTH" -b "$JAR" --max-time 8 "$url" | head -c 900
    echo; echo
  } | tee -a "$REPORT"
}

# ---- 0. unauthenticated behavior -------------------------------------------
{
  echo "== no auth"
  curl -s -o /dev/null -w 'GET /gui/ -> HTTP %{http_code}\n' "$BASE/gui/"
  curl -s -o /dev/null -w 'bad basic auth  -> HTTP %{http_code}\n' -u "$LOGIN:wrong" "$BASE/gui/token.html"
  curl -s -o /dev/null -w 'missing token   -> HTTP %{http_code}\n' -u "$AUTH" "$BASE/gui/?action=version"
  echo
} | tee -a "$REPORT"

# ---- 1. info & settings -----------------------------------------------------
act "version"
act "getsysteminfo"
act "getappinfo"
act "getlicenseinfo"
act "settings"
act "getsessionstats"

# ---- 2. speed charts (DOWNSPEED=1, UPSPEED=2) -------------------------------
act "getchartdata" "type=1" "from=0" "to=0"
act "getchartdata" "type=2" "from=0" "to=0"

# ---- 3. folder lifecycle ----------------------------------------------------
act "getsyncfolders" "discovery=1"
act "secret"
act "adddir" "dir=$NEWDIR"
act "addsyncfolder" "path=$NEWDIR"
act "addlink" "link=INVALIDKEY"
sleep 3
act "getsyncfolders" "discovery=1"
act "getsyncjobs"
act "getpeersstat"

# 3.x gates folder operations behind license/identity: expect adds to be
# no-ops until the daemon is activated (getlicenseinfo.allowed_to_sync=true
# via account sign-in or starttrialperiod).
act "starttrialperiod"
sleep 2
act "getlicenseinfo"
# First adddir may have created the directory without registering it, so
# retry with a fresh one.
rm -rf "$NEWDIR"
act "adddir" "dir=$NEWDIR"
sleep 3
act "getsyncfolders" "discovery=1"

# ---- 4. settings round-trip -------------------------------------------------
act "setsettings" "ulrate=1000" "dlrate=2000"
act "settings"

# ---- 5. shutdown ------------------------------------------------------------
act "shutdown"
for _ in $(seq 1 10); do
  kill -0 "$PID" 2>/dev/null || break
  sleep 0.5
done
if kill -0 "$PID" 2>/dev/null; then
  both "## daemon still running after shutdown action"
  kill "$PID" 2>/dev/null
else
  both "## daemon exited after shutdown action (expected)"
fi

both ""
both "## report end — share this whole file"
say ""
say "report: $REPORT"
