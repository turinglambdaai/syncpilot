#!/usr/bin/env bash
# Build update-stable.json for a release and sign it (the family's
# schema-1 Ed25519 envelope; see scripts/update-keys.sh history in taskly
# and the updater contract in racket/syncpilot/updater.rkt).
#
#   scripts/make-update-manifest.sh <tag> <dist-dir> <key-der-path>
#
#   <tag>            release tag, e.g. v0.7.0 (must match the VERSION file)
#   <dist-dir>       directory containing the release artifacts, i.e. the
#                    names the release pipeline produces:
#                      syncpilot-<ver>-linux-x64.tar.gz
#                      syncpilot-<ver>-linux-arm64.tar.gz
#   <key-der-path>   Ed25519 private key, DER (OneAsymmetricKey) — the raw
#                    form of the UPDATE_ED25519_PRIVATE_KEY_B64 CI secret
#
# Emits <dist-dir>/update-stable.json with one targz artifact per
# architecture and versioned download URLs. rivet 0.6.1's built-in release
# manifest would point at the portable zip, which the SyncPilot updater
# does not consume — the updater fetches the tar.gz payload, so this script
# signs the manifest the updater actually reads. Requires racket with the
# pinned rivet linked (the release publish job installs it).
set -euo pipefail

TAG="${1:?usage: make-update-manifest.sh <tag> <dist-dir> <key-der-path>}"
DIST="${2:?usage: make-update-manifest.sh <tag> <dist-dir> <key-der-path>}"
KEY="${3:?usage: make-update-manifest.sh <tag> <dist-dir> <key-der-path>}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${TAG#v}"
[[ "$VERSION" == "$(tr -d '[:space:]' < "$ROOT/VERSION")" ]] || {
  echo "error: tag $TAG does not match VERSION '$(cat "$ROOT/VERSION")'" >&2; exit 1; }

for artifact in "$DIST/syncpilot-$VERSION-linux-x64.tar.gz" \
                "$DIST/syncpilot-$VERSION-linux-arm64.tar.gz"; do
  [[ -f "$artifact" ]] || { echo "error: missing $artifact" >&2; exit 1; }
done
[[ -f "$KEY" ]] || { echo "error: missing signing key $KEY" >&2; exit 1; }

TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/syncpilot-manifest-XXXXXX")"
SCRIPT="$TMPDIR/make-update-manifest.rkt"
trap 'rm -rf "$TMPDIR"' EXIT

cat > "$SCRIPT" <<RKT
#lang racket/base
(require rivet/distribution
         racket/date
         racket/file
         racket/format)
(define version "$VERSION")
(define base-url "${RELEASE_ASSET_BASE_URL:-https://github.com/turinglambdaai/syncpilot/releases/download/$TAG}")
(define dist (path->complete-path "$DIST"))
(define key-path (path->complete-path "$KEY"))
(define key-id "syncpilot-2026-10")
(define build (hash-ref (file->value (build-path (path->complete-path "$ROOT") "rivet.rktd")) 'build))

(define (artifact architecture file)
  (define path (build-path dist file))
  (unless (file-exists? path)
    (error 'make-update-manifest "missing installer: ~a" path))
  (update-artifact 'linux architecture
                   (string-append base-url "/" file)
                   (sha256-file/hex path)
                   (file-size path)
                   'targz
                   '()))

(define manifest
  (update-manifest "site.jrtx.syncpilot"
                   version
                   build
                   'stable
                   ;; published-at: RFC 3339, second precision, UTC
                   (let ([d (seconds->date (current-seconds) #t)])
                     (format "~a-~a-~aT~a:~a:~aZ"
                             (~r (date-year d) #:min-width 4 #:pad-string "0")
                             (~r (date-month d) #:min-width 2 #:pad-string "0")
                             (~r (date-day d) #:min-width 2 #:pad-string "0")
                             (~r (date-hour d) #:min-width 2 #:pad-string "0")
                             (~r (date-minute d) #:min-width 2 #:pad-string "0")
                             (~r (date-second d) #:min-width 2 #:pad-string "0")))
                   "0.0.0"
                   #f
                   #t
                   100
                   (list (artifact 'x64
                                   (format "syncpilot-~a-linux-x64.tar.gz" version))
                         (artifact 'arm64
                                   (format "syncpilot-~a-linux-arm64.tar.gz" version)))))

;; write-signed-manifest validates the struct against the manifest schema
;; before signing, so a malformed manifest fails the release instead of
;; shipping something every client would reject.
(call-with-output-file (build-path dist "update-stable.json")
  #:exists 'truncate/replace
  (lambda (out)
    (write-signed-manifest manifest
                           (read-ed25519-private-key key-path)
                           key-id
                           out)
    (newline out)))
(printf "manifest: ~a (2 targz artifacts, key-id ~a)\\n"
        (build-path dist "update-stable.json") key-id)
RKT

# rivet must be installed for the signer; the release publish job links a
# checkout at the release pin.
racket "$SCRIPT"
