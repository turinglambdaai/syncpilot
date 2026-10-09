#lang racket/base

;; Online update support for SyncPilot, built on rivet/distribution — the
;; family pattern (payback): the backend verifies and downloads the signed
;; update artifact; the native host owns installation. A check downloads and
;; verifies the Ed25519-signed channel manifest; the actual tar.gz download
;; runs on a background thread with progress published to a state box that
;; the UI polls through the `update-state` RPC (RVT1 events are thread-local,
;; so a background thread cannot emit them directly).
;;
;; SyncPilot-specific rule: an update swaps ONLY the app install. The
;; daemon's state (~/.local/share/site.jrtx.syncpilot minus this module's
;; updates/ folder, rslsync.conf, storage/) is never touched — the updater
;; writes under <data-dir>/updates and hands the verified tarball to the host.

;; Note on crypto factories: rivet/distribution pins the provider set to
;; libcrypto at module load and deliberately avoids crypto/all — factory
;; FFIs load at import time and the gmp factory kills embedded runtimes on
;; hosts without libgmp. This module runs inside the embedded CS runtime,
;; so it must not require crypto/all either (tests may, they are headless).

(require crypto
         net/base64
         net/url
         rivet/distribution
         racket/file
         racket/port
         racket/random
         racket/string
         "settings.rkt"
         "version.rkt")

(provide platform-symbol
         architecture-symbol
         installer-extension
         manifest-url
         destination-path
         copy-with-progress!
         update-state-snapshot
         reset-update-state!
         perform-check!
         start-download!
         rollout-bucket)

;; rivet release tooling emits these exact symbols into update manifests
(define (platform-symbol)
  (case (system-type 'os)
    [(macosx) 'macos]
    [(windows) 'windows]
    [else 'linux]))

(define (architecture-symbol)
  (case (system-type 'arch)
    [(aarch64 arm64) 'arm64]
    [else 'x64]))

(define (installer-extension)
  (case (system-type 'os)
    [(macosx) ".dmg"]
    [(windows) ".msi"]
    [else ".tar.gz"]))

(define maximum-download-bytes (* 800 1024 1024))

;; ---------- public key ----------

;; use-all-factories! already ran at module load; the embedded DER is the
;; public half of the update keypair, which never ships.
(define (embedded-public-key)
  (datum->pk-key (base64-string->bytes update-public-key-b64)
                 'SubjectPublicKeyInfo))

;; ---------- shared update state (UI-visible) ----------

;; phase: idle | checking | downloading | downloaded | error
(define update-state
  (box (hasheq 'phase "idle"
               'percent 0
               'message #f
               'downloadedPath #f
               'availableVersion #f)))

(define candidate-box (box #f))
(define worker-thread-box (box #f))

(define (state-set! key value)
  (set-box! update-state (hash-set (unbox update-state) key value)))

(define (update-state-snapshot)
  (unbox update-state))

(define (reset-update-state!)
  (set-box! candidate-box #f)
  (set-box! update-state
            (hasheq 'phase "idle"
                    'percent 0
                    'message #f
                    'downloadedPath #f
                    'availableVersion #f)))

;; ---------- manifest URL ----------

(define (manifest-url settings)
  (define base
    (let ([configured (app-settings-update-base-url settings)])
      (if (and (string? configured) (not (string=? configured "")))
          configured
          default-update-base-url)))
  (string-append (string-trim base "/" #:right? #t)
                 "/update-"
                 (symbol->string app-channel)
                 ".json"))

;; ---------- settings commit seam ----------

;; The updater never touches the manager directly: callers hand in a
;; commit! procedure (app-settings? -> void) that persists. The backend
;; binds it to manager-update-settings!, tests bind it to a local box.

(define (settings-with s #:update-base-url [update-base-url
                                          (app-settings-update-base-url s)]
                       #:last-update-check-at [last-update-check-at
                                               (app-settings-last-update-check-at
                                                s)]
                       #:rollout-bucket [rollout-bucket
                                         (app-settings-rollout-bucket s)])
  (struct-copy app-settings s
               [update-base-url update-base-url]
               [last-update-check-at last-update-check-at]
               [rollout-bucket rollout-bucket]))

;; ---------- check ----------

;; Returns a plain hasheq describing the outcome (the backend maps it onto
;; the typed UpdateCheck record); also stamps last-update-check-at on every
;; completed check so the host's silent daily auto-check stays throttled.
(define (perform-check! settings commit!)
  (reset-update-state!)
  (state-set! 'phase "checking")
  (with-handlers
      ([exn:fail?
        (lambda (e)
          (state-set! 'phase "error")
          (state-set! 'message (exn-message e))
          (hasheq 'status "error" 'message (exn-message e)))])
    (define manifest
      (fetch-update-manifest (manifest-url settings)
                             (embedded-public-key)
                             #:key-id update-key-id))
    (define config
      (updater-config app-identifier
                      app-version
                      app-channel
                      (platform-symbol)
                      (architecture-symbol)
                      (embedded-public-key)
                      update-key-id
                      (rollout-bucket settings commit!)
                      maximum-download-bytes))
    (define candidate (select-update config manifest))
    (commit! (settings-with settings
                            #:last-update-check-at (current-seconds)))
    (cond
      [candidate
       (set-box! candidate-box candidate)
       (define artifact (update-candidate-artifact candidate))
       (state-set! 'phase "idle")
       (state-set! 'availableVersion
                   (update-manifest-version (update-candidate-manifest candidate)))
       (hasheq 'status "available"
               'currentVersion app-version
               'availableVersion
               (update-manifest-version (update-candidate-manifest candidate))
               'build (update-manifest-build (update-candidate-manifest candidate))
               'publishedAt
               (update-manifest-published-at (update-candidate-manifest candidate))
               'installer (symbol->string (update-artifact-installer artifact))
               'sizeBytes (update-artifact-size artifact))]
      [else
       (state-set! 'phase "idle")
       (state-set! 'availableVersion #f)
       (hasheq 'status "up-to-date" 'currentVersion app-version)])))

;; rollout bucket: stable random 0..99 assigned on first check so staged
;; rollouts are sticky per installation
(define (rollout-bucket settings commit!)
  (define existing (app-settings-rollout-bucket settings))
  (cond
    [(and (exact-integer? existing) (<= 0 existing 99)) existing]
    [else
     ;; crypto-random-bytes, not `random`: racket/base's PRNG has a fixed
     ;; seed, which would put every fresh install in the same lockstep bucket
     (define bucket
       (modulo (integer-bytes->integer (crypto-random-bytes 4) #t #t) 100))
     (commit! (settings-with settings #:rollout-bucket bucket))
     bucket]))

;; ---------- download ----------

(define (destination-path data-dir candidate)
  (define version
    (update-manifest-version (update-candidate-manifest candidate)))
  (build-path data-dir
              "updates"
              (string-append app-display-name "-" version
                             (installer-extension))))

;; copy with progress; same limits as rivet's download-update but publishes
;; integer percent changes to the state box while streaming
(define (copy-with-progress! in out total)
  (define buffer (make-bytes 65536))
  (let loop ([done 0] [last-percent -1])
    (define count (read-bytes-avail! buffer in))
    (cond
      [(eof-object? count) done]
      [else
       (write-bytes buffer out 0 count)
       (define next (+ done count))
       (define percent
         (if (> total 0)
             (min 100 (quotient (* next 100) total))
             0))
       (when (> percent last-percent)
         (state-set! 'percent percent))
       (loop next percent)])))

(define (download-with-progress! config candidate destination)
  (define artifact (update-candidate-artifact candidate))
  (define total (update-artifact-size artifact))
  (when (> total (updater-config-maximum-download-bytes config))
    (error 'download-update "signed artifact size exceeds the download limit"))
  (make-parent-directory* destination)
  (define temporary (path-add-extension destination #".partial"))
  (when (file-exists? temporary) (delete-file temporary))
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (when (file-exists? temporary) (delete-file temporary))
                     (raise e))])
    (define in
      (get-pure-port (string->url (update-artifact-url artifact))
                     '("User-Agent: SyncPilot-Updater/1")))
    (dynamic-wind
      void
      (lambda ()
        (call-with-output-file temporary
          #:exists 'truncate/replace
          #:mode 'binary
          (lambda (out) (copy-with-progress! in out total))))
      (lambda () (close-input-port in)))
    ;; size + SHA-256 against the signed manifest before the file is trusted
    (verify-update-artifact! candidate temporary)
    (rename-file-or-directory temporary destination #t)
    destination))

(define (start-download! settings commit! data-dir)
  (define worker (unbox worker-thread-box))
  (when (and worker (thread-running? worker))
    (error 'start-download! "an update download is already running"))
  (define candidate (unbox candidate-box))
  (unless candidate
    (error 'start-download! "no update is available; run a check first"))
  (state-set! 'phase "downloading")
  (state-set! 'percent 0)
  (state-set! 'message #f)
  (define config
    (updater-config app-identifier
                    app-version
                    app-channel
                    (platform-symbol)
                    (architecture-symbol)
                    (embedded-public-key)
                    update-key-id
                    (rollout-bucket settings commit!)
                    maximum-download-bytes))
  (define destination (destination-path data-dir candidate))
  (set-box! worker-thread-box
            (thread
             (lambda ()
               (with-handlers
                   ([exn:fail?
                     (lambda (e)
                       (state-set! 'phase "error")
                       (state-set! 'message (exn-message e)))])
                 (define path
                   (download-with-progress! config candidate destination))
                 (state-set! 'phase "downloaded")
                 (state-set! 'percent 100)
                 (state-set! 'downloadedPath (path->string path)))))))
