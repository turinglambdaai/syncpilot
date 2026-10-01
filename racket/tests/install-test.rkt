#lang racket/base

;; First-run installer tests: sha256 pinning, tar.gz extraction of a locally
;; generated fixture, URL shapes, retry/backoff and checksum enforcement —
;; all with an injected fetcher, never touching the network.

(require file/gzip
         rackunit
         racket/file
         racket/string
         racket/format
         racket/port
         "../syncpilot/httputil.rkt"
         "../syncpilot/install.rkt")

;; ------------------------------------------------------------ tar fixtures

;; Hand-build a ustar archive (512-byte header + data blocks + two zero
;; end blocks) so extraction is tested without an external tar binary.
(define (tar-header name size mode)
  (define h (make-bytes 512 0))
  (define (put off bstr) (bytes-copy! h off bstr))
  (put 0 name)
  (put 100 (string->bytes/latin-1 (~a mode)))
  (put 108 #"0000000\0")            ; uid
  (put 116 #"0000000\0")            ; gid
  (put 124 (string->bytes/latin-1 (~r size #:base 8 #:min-width 11 #:pad-string "0")))
  (bytes-set! h 135 0)              ; octal size NUL terminator
  (put 136 #"00000000000\0")        ; mtime
  (put 148 #"        ")             ; checksum placeholder (spaces)
  (bytes-set! h 156 48)             ; typeflag '0' = regular file
  (put 257 #"ustar\0\0")            ; magic + version
  ;; checksum: sum of header bytes with the field treated as spaces
  (define sum (for/fold ([acc 0]) ([b (in-bytes h)]) (+ acc b)))
  (put 148
       (string->bytes/latin-1
        (~a (~r sum #:base 8 #:min-width 6 #:pad-string "0")
            "\0 ")))
  h)

(define (tar-file-entry name content)
  (define data (if (zero? (modulo (bytes-length content) 512))
                   content
                   (bytes-append content (make-bytes (- 512 (modulo (bytes-length content) 512)) 0))))
  (bytes-append (tar-header name (bytes-length content) "0000755") data))

(define (tar-end) (make-bytes 1024 0))

(define (gzipped bs)
  (define out (open-output-bytes))
  (call-with-input-bytes bs
    (lambda (in) (gzip-through-ports in out #"rslsync" 0)))
  (get-output-bytes out))

(define fixture-tar-gz
  (gzipped
   (bytes-append (tar-file-entry #"sub/dir/rslsync" #"HELLO")
                 (tar-file-entry #"sub/dir/readme.txt" #"not the binary")
                 (tar-end))))

;; ---------------------------------------------------------------- checksums

(test-case "sha256 vectors agree across the native and pure implementations"
  (check-equal? (sha256-hex #"") "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
  (check-equal? (sha256-hex #"abc") "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  (check-equal? (sha256-hex (make-bytes 1000000 97))
                "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
  (check-equal? (sha256-pure #"abc")
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  (check-equal? (sha256-pure (make-bytes 10000 42))
                (sha256-hex (make-bytes 10000 42))))

(test-case "checksum verification pins the download"
  (check-equal? (verify-sha256 #"syncpilot test payload"
                               (sha256-hex #"syncpilot test payload"))
                (void))
  ;; Uppercase hex in a pinned constant still matches.
  (check-equal? (verify-sha256 #"payload"
                               (string-upcase (sha256-hex #"payload")))
                (void))
  (check-exn
   (lambda (e) (string-contains? (exn-message e) "checksum mismatch"))
   (lambda () (verify-sha256 #"payload" "deadbeef"))))

;; --------------------------------------------------------------- extraction

(test-case "extracts rslsync from a nested tar.gz path"
  (check-equal? (extract-rslsync fixture-tar-gz) #"HELLO"))

(test-case "archives without an rslsync entry are rejected"
  (define no-binary
    (gzipped (bytes-append (tar-file-entry #"only/readme.txt" #"x") (tar-end))))
  (check-exn
   (lambda (e) (string-contains? (exn-message e) "does not contain an `rslsync` binary"))
   (lambda () (extract-rslsync no-binary))))

(test-case "non-gzip garbage is rejected"
  (check-exn exn:fail? (lambda () (extract-rslsync #"not a gzip"))))

;; ------------------------------------------------------------------ install

(define pinned-payload #"HELLO")

(test-case "pinned constants match the old Rust implementation"
  (check-equal? pinned-sha-x64
                "3cfedd41b3d21e2ae5fae58ca2114704d1ea4e4bab896796323c4a15c570f0f0")
  (check-equal? pinned-sha-arm64
                "cdc30638d4a1909fb16685d25924216af70c2758160ffa74822d371f574fe136")
  (check-equal? stable-url-x64
                "https://download-cdn.resilio.com/stable/linux/x64/0/resilio-sync_x64.tar.gz")
  (check-equal? stable-url-arm64
                "https://download-cdn.resilio.com/stable/linux/arm64/0/resilio-sync_arm64.tar.gz"))

;; Payload content used by the install-flow tests; each case pins its own
;; sha256 via (sha256-hex payload).

;; Fetchers must hand back a tar.gz like the real CDN does.
(define (tar-gz-of payload)
  (gzipped (bytes-append (tar-file-entry #"sub/dir/rslsync" payload)
                         (tar-end))))

(test-case "install with an injected fetcher lands a 0755 binary"
  (define dir (make-temporary-file "syncpilot-install-~a" 'directory))
  (define payload #"#!/bin/sh\necho fake-rslsync\n")
  (define download (tar-gz-of payload))
  (define path
    (install-official-binary!
     #:fetcher (lambda (url) download)
     #:install-dir dir
     ;; The pinned digest covers the downloaded archive, not the payload.
     #:arch (cons "x64" (sha256-hex download))))
  (check-equal? path (build-path dir "rslsync"))
  (check-equal? (file->bytes path) payload)
  (define bits (file-or-directory-permissions path 'bits))
  (check-equal? (bitwise-and bits #o777) #o755)
  (delete-directory/files dir))

(test-case "the fetcher receives the per-arch CDN URL"
  (define seen-urls '())
  (define payload #"BIN")
  (define download (tar-gz-of payload))
  (define (install! arch)
    (install-official-binary!
     #:fetcher (lambda (url)
                 (set! seen-urls (cons url seen-urls))
                 download)
     #:install-dir (make-temporary-file "syncpilot-install-~a" 'directory)
     #:sleep void
     #:arch arch))
  (install! (cons "x64" (sha256-hex download)))
  (install! (cons "arm64" (sha256-hex download)))
  (check-not-false (member stable-url-x64 seen-urls) (format "got: ~a" seen-urls))
  (check-not-false (member stable-url-arm64 seen-urls)))

(test-case "transient failures retry three times with 2s/4s backoff"
  (define attempts (box 0))
  (define sleeps (box '()))
  (define payload #"OK")
  (define download (tar-gz-of payload))
  (define dir (make-temporary-file "syncpilot-install-~a" 'directory))
  (define path
    (install-official-binary!
     #:fetcher (lambda (url)
                 (set-box! attempts (add1 (unbox attempts)))
                 (if (< (unbox attempts) 3)
                     (raise-user-error 'fetch "boom")
                     download))
     #:install-dir dir
     #:sleep (lambda (s) (set-box! sleeps (append (unbox sleeps) (list s))))
     #:arch (cons "x64" (sha256-hex download))))
  (check-equal? (unbox attempts) 3)
  (check-equal? (unbox sleeps) '(2 4))
  (check-true (file-exists? path))
  (delete-directory/files dir))

(test-case "exhausted retries surface a network-agnostic error"
  (define attempts (box 0))
  (check-exn
   (lambda (e)
     (string-contains? (exn-message e)
                       "check your network connection and retry"))
   (lambda ()
     (install-official-binary!
      #:fetcher (lambda (url)
                  (set-box! attempts (add1 (unbox attempts)))
                  (raise-user-error 'fetch "boom"))
      #:sleep void
      #:arch (cons "x64" pinned-sha-x64))))
  (check-equal? (unbox attempts) 3))

(test-case "checksum mismatch is a hard stop"
  (check-exn
   (lambda (e) (string-contains? (exn-message e) "checksum mismatch"))
   (lambda ()
     (install-official-binary!
      #:fetcher (lambda (url) #"tampered")
      #:sleep void
      #:arch (cons "x64" pinned-sha-x64)))))

(test-case "unsupported architectures are rejected"
  (check-exn
   (lambda (e) (string-contains? (exn-message e) "unsupported architecture"))
   (lambda ()
     (install-official-binary!
      #:fetcher (lambda (url) #"x")
      #:sleep void
      #:arch #f))))
