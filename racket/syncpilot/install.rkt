#lang racket/base

;; First-run installer for the official rslsync binary (port of
;; src-tauri/src/rslsync_install.rs).
;;
;; SyncPilot does not bundle or redistribute Resilio's binary; on a fresh
;; machine without rslsync this downloads it straight from Resilio's CDN into
;; ~/.local/bin, verifying the pinned sha256 checksum before install. Same
;; source and checksums as scripts/install-rslsync.sh.

(require file/untgz
         net/url
         racket/file
         racket/path
         racket/port
         racket/string
         "httputil.rkt")

(provide pinned-sha-x64
         pinned-sha-arm64
         stable-url-x64
         stable-url-arm64
         default-install-dir
         install-official-binary!
         verify-sha256
         extract-rslsync)

(define stable-url-x64
  "https://download-cdn.resilio.com/stable/linux/x64/0/resilio-sync_x64.tar.gz")
(define stable-url-arm64
  "https://download-cdn.resilio.com/stable/linux/arm64/0/resilio-sync_arm64.tar.gz")

;; Pinned checksums from the AUR rslsync PKGBUILD for Resilio stable 3.1.2;
;; re-pin when Resilio ships a new stable (same policy as
;; scripts/install-rslsync.sh). Copied verbatim from rslsync_install.rs.
(define pinned-sha-x64
  "3cfedd41b3d21e2ae5fae58ca2114704d1ea4e4bab896796323c4a15c570f0f0")
(define pinned-sha-arm64
  "cdc30638d4a1909fb16685d25924216af70c2758160ffa74822d371f574fe136")

(define (default-install-dir)
  (build-path (find-system-path 'home-dir) ".local" "bin"))

;; (string . string): CDN flavor tag ("x64"/"arm64") paired with the pinned
;; digest. #f on architectures Resilio does not publish.
(define (arch-tag)
  (case (system-type 'arch)
    [(x86_64) (cons "x64" pinned-sha-x64)]
    [(aarch64 arm64) (cons "arm64" pinned-sha-arm64)]
    [else #f]))

;; SHA-256 mismatch is a hard stop: the binary is executed, not inspected.
;; Uppercase hex in a pinned constant still matches.
(define (verify-sha256 bytes expected)
  (define actual (sha256-hex bytes))
  (unless (string=? actual (string-downcase expected))
    (error 'install
           "checksum mismatch: expected ~a, got ~a — the pinned Resilio stable may have moved; re-pin or install manually"
           expected
           actual))
  (void))

;; Pull the single `rslsync` executable out of the tar.gz payload and return
;; its bytes (parity with the Rust extract_rslsync: nested paths like
;; `sub/dir/rslsync` and `resilio-sync/rslsync` both match).
(define (extract-rslsync gz-bytes)
  (define tmp (make-temporary-file "syncpilot-extract-~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (call-with-input-bytes
       gz-bytes
       (lambda (in)
         (untgz in
                #:dest tmp
                #:filter (lambda (path . _)
                           (equal? (file-name-from-path path)
                                   (string->path "rslsync"))))))
      (define found
        (for/list ([path (in-directory tmp)]
                   #:when (and (file-exists? path)
                               (equal? (file-name-from-path path)
                                       (string->path "rslsync"))))
          path))
      (when (null? found)
        (error 'install "archive does not contain an `rslsync` binary"))
      (file->bytes (car found)))
    (lambda ()
      (with-handlers ([exn:fail? void])
        (delete-directory/files tmp)))))

;; Default fetcher: plain GET against the CDN (HTTPS via net/url; the tests
;; inject a fetcher instead of touching the network).
(define (http-fetch url)
  (with-deadline
   300
   'install-fetch
   (lambda ()
     (define-values (in status)
       (get-pure-port/headers (string->url url) #:status? #t))
     (dynamic-wind
       void
       (lambda ()
         (define body (port->bytes in))
         (define code
           (let* ([line (bytes->string/utf-8 status)]
                  [parts (string-split line " " #:trim? #t)])
             (and (>= (length parts) 2) (string->number (list-ref parts 1)))))
         (unless (and code (<= 200 code 299))
           (error 'install "download failed: HTTP ~a from ~a" (or code "?") url))
         body)
       (lambda () (close-input-port in))))))

;; Download, verify and install. Returns the installed binary path.
;; Transient CDN/network failures are common enough to retry a couple of
;; times before surfacing an error to the user (3 attempts, 2s/4s backoff).
(define (install-official-binary!
         #:fetcher [fetcher #f]
         #:install-dir [install-dir (default-install-dir)]
         #:sleep [sleep-proc (lambda (secs) (sleep secs))]
         #:arch [arch (arch-tag)])
  (define fetch (or fetcher http-fetch))
  (unless arch
    (error 'install "unsupported architecture: ~a" (system-type 'arch)))
  (define url
    (format "https://download-cdn.resilio.com/stable/linux/~a/0/resilio-sync_~a.tar.gz"
            (car arch) (car arch)))
  (define expected (cdr arch))
  (define payload
    (let loop ([attempt 1] [last-error #f])
      (cond
        [(> attempt 3)
         (error 'install
                "~a — check your network connection and retry, or install Resilio Sync manually"
                last-error)]
        [else
         (with-handlers
             ([exn:fail?
               (lambda (e)
                 ;; 2s after the first failure, then 4s (old Rust: 2*attempt).
                 (sleep-proc (* 2 attempt))
                 (loop (add1 attempt) (exn-message e)))])
           (fetch url))])))
  (verify-sha256 payload expected)
  (define binary (extract-rslsync payload))
  (make-directory* install-dir)
  (define target (build-path install-dir "rslsync"))
  (with-output-to-file target
    (lambda () (write-bytes binary))
    #:exists 'replace)
  (file-or-directory-permissions target #o755)
  target)
