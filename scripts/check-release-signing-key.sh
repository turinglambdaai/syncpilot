#!/usr/bin/env bash
# Release gate: the Ed25519 private key must correspond to the public key
# embedded in shipped SyncPilot clients. Never print or commit key material.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY="${1:?usage: check-release-signing-key.sh <private-key.der>}"
[[ -s "$KEY" ]] || { echo "error: missing Ed25519 signing key" >&2; exit 1; }

EXPECTED="$(sed -n '/^(define update-public-key-b64/{n;s/^[[:space:]]*"\([^"]*\)".*/\1/p;}' "$ROOT/racket/syncpilot/version.rkt")"
[[ -n "$EXPECTED" ]] || { echo "error: embedded update public key missing" >&2; exit 1; }

PUBLIC_DER="$(mktemp)"
trap 'rm -f "$PUBLIC_DER"' EXIT
if ! openssl pkey -inform DER -in "$KEY" -pubout -outform DER -out "$PUBLIC_DER" >/dev/null 2>&1; then
  echo "error: invalid Ed25519 release signing private key" >&2
  exit 1
fi
# Ed25519 SubjectPublicKeyInfo is 44 bytes (RFC 8410).
[[ "$(wc -c < "$PUBLIC_DER" | tr -d '[:space:]')" == 44 ]] || {
  echo "error: release signing key is not Ed25519" >&2; exit 1; }
ACTUAL="$(openssl base64 -A -in "$PUBLIC_DER")"
[[ "$ACTUAL" == "$EXPECTED" ]] || {
  echo "error: release signing key does not match shipped SyncPilot updater" >&2
  exit 1
}
echo "release-signing: Ed25519 private key matches embedded client trust key"
