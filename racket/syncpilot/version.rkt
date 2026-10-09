#lang racket/base

;; Release identity duplicated from rivet.rktd. The packaged app cannot read
;; the project file at runtime, so the updater embeds these constants. Keep
;; them in sync with rivet.rktd — scripts/check-release-version.sh enforces
;; VERSION == rivet.rktd == app-version in CI and at release time (v0.6.1
;; shipped with 0.6.0 here; the gate exists so that cannot recur).

(provide app-version
         app-build
         app-identifier
         app-channel
         app-display-name
         update-key-id
         update-public-key-b64
         default-update-base-url)

(define app-version "0.6.1")
(define app-build 3)
(define app-identifier "site.jrtx.syncpilot")
(define app-channel 'stable)
(define app-display-name "SyncPilot")

(define update-key-id "syncpilot-2026-10")

;; SubjectPublicKeyInfo DER, base64. The private half lives outside the
;; repository (Sync/Keys backup + the CI secret UPDATE_ED25519_PRIVATE_KEY_B64)
;; and never ships. Rotate by shipping a build that trusts the next key
;; before signing releases exclusively with it.
(define update-public-key-b64
  "MCowBQYDK2VwAyEADxqoChWna0Wj18+/tK1VLAmEK4s7uZRu85SZLXqHlMI=")

;; Where the updater looks for the signed channel manifest. The release
;; pipeline pins artifact URLs to the concrete tag; the manifest itself is
;; always fetched from the moving "latest" location.
(define default-update-base-url
  "https://github.com/turinglambdaai/syncpilot/releases/latest/download")
