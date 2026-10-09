#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
TAG="${1:-}"

fail() {
  echo "release preflight: $*" >&2
  exit 1
}

[[ -n "$VERSION" ]] || fail "VERSION is empty"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] || \
  fail "VERSION '$VERSION' is not a supported semantic version"

if [[ -n "$TAG" ]]; then
  TAG_VERSION="${TAG#v}"
  [[ "$TAG_VERSION" == "$VERSION" ]] || \
    fail "tag '$TAG' does not match VERSION '$VERSION'"
fi

# The Rivet app manifest carries the product version on this tree.
RIVET_RKTD_VERSION="$(sed -n 's/.*(version . "\([^"]*\)").*/\1/p' "$ROOT/rivet.rktd" | head -n1)"
[[ "$RIVET_RKTD_VERSION" == "$VERSION" ]] || \
  fail "rivet.rktd version '$RIVET_RKTD_VERSION' does not match VERSION '$VERSION'"

# The updater embeds the release identity for the update feed (v0.6.1
# shipped with version.rkt still declaring 0.6.0 — this gate exists so
# that cannot happen again).
grep -qF "(define app-version \"$VERSION\")" "$ROOT/racket/syncpilot/version.rkt" || \
  fail "racket/syncpilot/version.rkt app-version does not match VERSION '$VERSION'"

echo "release preflight: version $VERSION is aligned (VERSION == rivet.rktd == updater identity)"
