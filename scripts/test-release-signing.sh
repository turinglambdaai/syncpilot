#!/usr/bin/env bash
# Offline negative checks; CI never needs the real release signing secret.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

openssl genpkey -algorithm Ed25519 -out "$TMP/untrusted.pem" >/dev/null 2>&1
openssl pkey -in "$TMP/untrusted.pem" -outform DER -out "$TMP/untrusted.der"
if bash "$ROOT/scripts/check-release-signing-key.sh" "$TMP/untrusted.der" >"$TMP/log" 2>&1; then
  echo "error: unrelated Ed25519 key was accepted" >&2; exit 1
fi
grep -q 'does not match shipped SyncPilot updater' "$TMP/log" || {
  echo "error: unrelated key failed for an unexpected reason" >&2; cat "$TMP/log" >&2; exit 1; }
if bash "$ROOT/scripts/check-release-signing-key.sh" "$TMP/missing.der" >"$TMP/log" 2>&1; then
  echo "error: missing release key was accepted" >&2; exit 1
fi
grep -q 'missing Ed25519 signing key' "$TMP/log"
printf 'not a private key' > "$TMP/invalid.der"
if bash "$ROOT/scripts/check-release-signing-key.sh" "$TMP/invalid.der" >"$TMP/log" 2>&1; then
  echo "error: malformed signing key was accepted" >&2; exit 1
fi
grep -q 'invalid Ed25519 release signing private key' "$TMP/log"

grep -q 'github.com/turlamai/syncpilot/releases/latest/download' "$ROOT/racket/syncpilot/version.rkt"
grep -q 'github.com/turlamai/syncpilot/releases/download' "$ROOT/scripts/make-update-manifest.sh"
if grep -q 'turinglambdaai/syncpilot' "$ROOT/racket/syncpilot/version.rkt" "$ROOT/scripts/make-update-manifest.sh"; then
  echo "error: legacy update origin remains" >&2; exit 1
fi
echo "release-signing: missing, malformed and untrusted keys rejected; canonical URLs verified"
