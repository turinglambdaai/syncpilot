#lang racket/base

(require json
         racket/file
         racket/path
         racket/system)

(unless (eq? (system-type 'os) 'unix)
  (error 'syncpilot-acceptance "the product contract is Linux-only"))

(define raco
  (or (find-executable-path "raco")
      (error 'syncpilot-acceptance "raco was not found")))

(unless (system* raco "rivet" "package" "--skip-launch-smoke")
  (error 'syncpilot-acceptance "raco rivet package failed"))

(define output-directory
  (build-path (current-directory) ".rivet" "acceptance" "linux"))
(make-directory* output-directory)
(call-with-output-file (build-path output-directory "package.json")
  #:exists 'truncate/replace
  (lambda (output)
    (write-json
     (hash 'platform "linux"
           'package-verified #t
           'source "raco rivet package --skip-launch-smoke")
     output)
    (newline output)))
