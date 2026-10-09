#lang racket/base

;; Updater tests: platform mapping, manifest URL construction, download
;; progress accounting, the sticky rollout bucket, and the full offline
;; trust chain — craft a manifest, sign it with a throwaway Ed25519 key,
;; verify it, and select updates the same way the live checker does.
;; (fetch-update-manifest itself only accepts HTTPS, so the network half is
;; exercised in production; everything it does with the bytes is tested here.)

(require crypto
         crypto/all
         rackunit
         net/base64
         rivet/distribution
         racket/file
         racket/list
         racket/path
         "../syncpilot/settings.rkt"
         "../syncpilot/updater.rkt"
         "../syncpilot/version.rkt")

(use-all-factories!)

;; The commit seam the backend binds to manager-update-settings!: a box
;; standing in for the manager's settings cell.
(define (make-cell [initial (default-settings)])
  (define cell (box initial))
  (cons cell (lambda (s) (set-box! cell s))))

(test-case "platform symbols match rivet release manifests"
  (case (system-type 'os)
    [(macosx) (check-equal? (platform-symbol) 'macos)]
    [(windows) (check-equal? (platform-symbol) 'windows)]
    [else (check-equal? (platform-symbol) 'linux)])
  (check-not-false (memq (architecture-symbol) '(arm64 x64))))

(test-case "installer extension follows platform"
  ;; SyncPilot ships Linux-only, but dev runs and CI hosts are macOS too
  (check-not-false
   (member (installer-extension) '(".dmg" ".msi" ".tar.gz"))
   "known installer extension"))

(test-case "manifest url joins base and channel"
  (check-equal? (manifest-url (default-settings))
                (string-append default-update-base-url "/update-stable.json"))
  (check-equal?
   (manifest-url (struct-copy app-settings (default-settings)
                              [update-base-url "https://dl.example/sp/"]))
   "https://dl.example/sp/update-stable.json")
  (check-equal?
   (manifest-url (struct-copy app-settings (default-settings)
                              [update-base-url "https://dl.example/sp"]))
   "https://dl.example/sp/update-stable.json")
  ;; an empty override falls back to the embedded default
  (check-equal?
   (manifest-url (struct-copy app-settings (default-settings)
                              [update-base-url ""]))
   (string-append default-update-base-url "/update-stable.json")))

(test-case "download progress copies bytes and reports percent"
  (reset-update-state!)
  (define payload (make-bytes 250000 7))
  (define out (open-output-bytes))
  (copy-with-progress! (open-input-bytes payload) out 250000)
  (check-equal? (bytes-length (get-output-bytes out)) 250000)
  (check-equal? (hash-ref (update-state-snapshot) 'percent) 100)
  ;; percent tracks the declared total, not the end of input
  (reset-update-state!)
  (define short-out (open-output-bytes))
  (copy-with-progress! (open-input-bytes payload) short-out 1000000)
  (check-equal? (hash-ref (update-state-snapshot) 'percent) 25)
  (reset-update-state!))

(test-case "signed manifest verifies and selects updates"
  ;; throwaway keypair: same DER formats the release pipeline uses
  (define priv (generate-private-key 'eddsa '((curve ed25519))))
  (define priv-der (pk-key->datum priv 'OneAsymmetricKey))
  ;; derive the public half through the library: the rkt-private datum
  ;; element order differs between generated and DER-imported keys
  (define pub (datum->pk-key (pk-key->datum priv 'rkt-public) 'rkt-public))
  (define pub-der (pk-key->datum pub 'SubjectPublicKeyInfo))

  (define tmp (make-temporary-file "syncpilot-updater-~a" 'directory))
  (define priv-path (build-path tmp "priv.der"))
  (define manifest-path (build-path tmp "update-stable.json"))
  (call-with-output-file priv-path
    (lambda (o) (write-bytes priv-der o)) #:exists 'truncate/replace)

  (define artifact
    (update-artifact 'linux 'x64
                     "https://example.com/syncpilot/SyncPilot-9.9.9.tar.gz"
                     "0000000000000000000000000000000000000000000000000000000000000000"
                     123456789 'targz '()))
  (define manifest
    (update-manifest app-identifier "9.9.9" 99 'stable
                     "2026-10-09T09:00:00Z" "0.0.0" "0.5.1" #t 100
                     (list artifact)))
  (call-with-output-file manifest-path
    (lambda (o) (write-signed-manifest manifest
                                       (read-ed25519-private-key priv-path)
                                       "test-key" o)
      (newline o)))

  ;; tamper check first: a modified payload must fail verification
  (define signed-bytes (file->bytes manifest-path))
  (define tampered
    (bytes-append
     (subbytes signed-bytes 0 40)
     #"9"
     (subbytes signed-bytes 41)))
  (check-exn exn:fail?
             (lambda ()
               (verify-signed-manifest (open-input-bytes tampered)
                                       (datum->pk-key pub-der 'SubjectPublicKeyInfo)
                                       #:key-id "test-key")))

  (define verified
    (verify-signed-manifest (open-input-bytes signed-bytes)
                            (datum->pk-key pub-der 'SubjectPublicKeyInfo)
                            #:key-id "test-key"))
  (check-equal? (update-manifest-version verified) "9.9.9")

  ;; selection policy: newer version for this app/channel/platform wins
  (define config
    (updater-config app-identifier "0.6.0" 'stable 'linux 'x64
                    (datum->pk-key pub-der 'SubjectPublicKeyInfo)
                    "test-key" 42 800000000))
  (check-true (update-candidate? (select-update config verified)))
  ;; same version: nothing to do
  (check-false (select-update config
                              (struct-copy update-manifest verified
                                           [version "0.6.0"])))
  ;; older version: nothing to do
  (check-false (select-update config
                              (struct-copy update-manifest verified
                                           [version "0.5.1"])))
  ;; other channel is invisible
  (check-false (select-update config
                              (struct-copy update-manifest verified
                                           [channel 'beta])))
  ;; rollout: bucket 42 is excluded when rollout is 42 (bucket >= rollout)
  (check-false (select-update config
                              (struct-copy update-manifest verified
                                           [rollout 42])))
  (check-true (update-candidate?
               (select-update config
                              (struct-copy update-manifest verified
                                           [rollout 43]))))
  ;; other application identity must fail loudly
  (check-exn exn:fail?
             (lambda ()
               (select-update config
                              (struct-copy update-manifest verified
                                           [application-id "com.other.app"]))))

  ;; the destination filename carries the version and the platform installer
  (check-equal?
   (destination-path tmp (update-candidate verified artifact))
   (build-path tmp "updates"
               (string-append "SyncPilot-9.9.9" (installer-extension))))

  (delete-directory/files tmp))

(test-case "embedded public key decodes"
  ;; the shipped key must stay a valid SubjectPublicKeyInfo DER blob
  (check-true
   (pk-key? (datum->pk-key (base64-string->bytes update-public-key-b64)
                           'SubjectPublicKeyInfo))))

(test-case "rollout bucket is sticky and persisted"
  (define cell+commit! (make-cell))
  (define first-bucket
    (rollout-bucket (unbox (car cell+commit!)) (cdr cell+commit!)))
  (check-true (and (exact-integer? first-bucket) (<= 0 first-bucket 99)))
  (check-equal? (app-settings-rollout-bucket (unbox (car cell+commit!)))
                first-bucket
                "the assigned bucket is written back")
  ;; a later check reads the stored bucket: staged rollouts stay sticky
  (check-equal?
   (rollout-bucket (unbox (car cell+commit!)) (cdr cell+commit!))
   first-bucket))

(test-case "artifact verification enforces signed size and hash"
  (define tmp (make-temporary-file "syncpilot-verify-~a" 'directory))
  (define file-path (build-path tmp "installer.tar.gz"))
  (define payload #"syncpilot-installer-bytes")
  (call-with-output-file file-path
    (lambda (o) (write-bytes payload o)) #:exists 'truncate/replace)
  (define (candidate-for sha size)
    ;; the manifest half is not consulted by verification
    (update-candidate #f
                      (update-artifact 'linux 'x64
                                       "https://example.com/x.tar.gz"
                                       sha size 'targz '())))
  (define good
    (candidate-for (sha256-file/hex file-path) (bytes-length payload)))
  (check-equal? (verify-update-artifact! good file-path) file-path)
  (check-exn exn:fail?
             (lambda ()
               (verify-update-artifact!
                (candidate-for (sha256-file/hex file-path)
                               (add1 (bytes-length payload)))
                file-path))
             "size must match the signed manifest")
  (call-with-output-file file-path
    (lambda (o) (write-bytes #"tampered" o)) #:exists 'truncate/replace)
  (check-exn exn:fail?
             (lambda () (verify-update-artifact! good file-path))
             "hash must match the signed manifest"))

(test-case "check error path reports through the state box"
  ;; a settings file whose override is not HTTPS: fetch-update-manifest
  ;; rejects the URL before any network I/O, and perform-check! must fold
  ;; the raise into a structured error result instead of propagating
  (reset-update-state!)
  (define cell+commit!
    (make-cell (struct-copy app-settings (default-settings)
                            [update-base-url "http://localhost:1/sp"])))
  (define result
    (perform-check! (unbox (car cell+commit!)) (cdr cell+commit!)))
  (check-equal? (hash-ref result 'status) "error")
  (check-equal? (hash-ref (update-state-snapshot) 'phase) "error"))

(test-case "identity constants agree with the manifest the pipeline signs"
  (check-equal? app-identifier "site.jrtx.syncpilot")
  (check-equal? app-channel 'stable)
  (check-not-false (regexp-match? #px"^[0-9]+\\.[0-9]+\\.[0-9]+$" app-version)))
