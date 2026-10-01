#lang racket/base

;; Shared test helpers: loopback HTTP servers standing in for the rslsync
;; Web UI, a controllable upstream echo server for the proxy tests, and a
;; generated fake-daemon executable for the manager/backend tests. Every
;; listener binds an ephemeral port (no fixed ports anywhere).

(require racket/format
         racket/file
         racket/path
         racket/runtime-path
         racket/string
         racket/tcp
         "../syncpilot/httputil.rkt")

(provide start-raw-server!
         start-resilio-mock!
         read-http-request
         respond!
         parse-query
         query-lookup
         header-lookup
         (struct-out req*)
         wait-until
         write-fake-daemon!
         current-racket-path)

;; ------------------------------------------------------------ raw listeners

;; Serve every connection through `handle` on an ephemeral loopback port.
;; Returns (cons port stop!) — stop! closes the listener.
(define (start-raw-server! handle)
  (define listener (tcp-listen 0 16 #f "127.0.0.1"))
  ;; On a listener tcp-addresses yields (local-host local-port remote-host
  ;; remote-port); the local port is the second value.
  (define-values (_host port _rh _rp) (tcp-addresses listener #t))
  (define server-thread
    (thread
     (lambda ()
       (let loop ()
         (with-handlers ([exn:fail? void])
           (define-values (cin cout) (tcp-accept listener))
           (thread (lambda () (with-handlers ([exn:fail? void]) (handle cin cout))))
           (loop))))))
  (cons port
        (lambda ()
          (with-handlers ([exn:fail? void])
            (tcp-close listener))
          (kill-thread server-thread))))

;; ------------------------------------------------------------ request parse

;; Server-side read of one HTTP/1.1 request (head + content-length body).
;; Returns (req* method raw-target headers body).
(struct req* (method target headers body) #:transparent)

(define (read-http-request in)
  (define head-bytes (read-head in))
  (define lines (string-split (bytes->string/latin-1 head-bytes) "\r\n" #:trim? #f))
  (define parts (string-split (car lines) " " #:trim? #t))
  (define headers
    (for/list ([line (in-list (cdr lines))]
               #:when (not (string=? line ""))
               #:do [(define idx (index-of-colon line))]
               #:when idx)
      (cons (string-trim (substring line 0 idx))
            (string-trim (substring line (add1 idx))))))
  (define body
    (for/fold ([acc #""]
               #:result acc)
              ([pair (in-list headers)]
               #:when (string-ci=? (car pair) "content-length"))
      (read-exact-bytes in (string->number (string-trim (cdr pair))))))
  (req* (list-ref parts 0)
        (list-ref parts 1)
        headers
        body))

(define (index-of-colon line)
  (let loop ([i 0])
    (cond
      [(= i (string-length line)) #f]
      [(char=? (string-ref line i) #\:) i]
      [else (loop (add1 i))])))

(define (string-ci=? a b) (string=? (string-downcase a) (string-downcase b)))

(define (respond! cout code body #:set-cookie [set-cookie #f])
  (define head
    (~a "HTTP/1.1 " code " X\r\n"
        (if set-cookie (~a "Set-Cookie: " set-cookie "\r\n") "")
        "Content-Type: application/json\r\n"
        "Content-Length: " (string-utf-8-length body) "\r\n"
        "Connection: close\r\n"
        "\r\n"))
  (display head cout)
  (display body cout)
  (flush-output cout))

(define (parse-query target)
  (define query (let ([i (index-of-char target #\?)])
                  (if i (substring target (add1 i)) "")))
  (for/list ([kv (in-list (string-split query "&"))]
             #:when (not (string=? kv "")))
    (define eq (index-of-char kv #\=))
    (if eq
        (cons (substring kv 0 eq) (substring kv (add1 eq)))
        (cons kv ""))))

(define (index-of-char s c)
  (let loop ([i 0])
    (cond
      [(= i (string-length s)) #f]
      [(char=? (string-ref s i) c) i]
      [else (loop (add1 i))])))

(define (query-lookup params name)
  (for/or ([pair (in-list params)])
    (and (string=? (car pair) name) (cdr pair))))

(define (header-lookup headers name)
  (for/or ([pair (in-list headers)])
    (and (string-ci=? (car pair) name) (cdr pair))))

;; --------------------------------------------------------- resilio API mock

;; A loopback stand-in for rslsync's Web UI server with the verified
;; protocol semantics:
;; - basic auth on every request (401 with an empty body on mismatch);
;; - POST /gui/token.html issues a fresh token each time, bound to a session
;;   cookie (Set-Cookie), and only the newest token is accepted;
;; - GET /gui/?token=…&action=… routes through `routes`
;;   ((action . (code . body))); a stale/missing token answers
;;   400 `invalid request`; unknown actions answer 404 with an envelope.
;; Returns (list port token-count-box token-box) — token-box holds the token
;; the mock currently accepts (tests mutate it to simulate staleness).
(define (start-resilio-mock! #:login [login "u"]
                             #:password [password "p"]
                             #:routes [routes '()])
  (define expected-auth (basic-auth-value login password))
  (define token-box (box "TOK-0"))
  (define cookie-box (box "sess-0"))
  (define token-count (box 0))
  (define (handler cin cout)
    (define request (read-http-request cin))
    (define auth (header-lookup (req*-headers request) "authorization"))
    (cond
      [(not (equal? auth expected-auth))
       (respond! cout 401 "")]
      [else
       (define params (parse-query (req*-target request)))
       (define path
         (let ([i (index-of-char (req*-target request) #\?)])
           (if i (substring (req*-target request) 0 i) (req*-target request))))
       (cond
         [(and (string=? path "/gui/token.html")
               (string=? (req*-method request) "POST"))
          (define n (add1 (unbox token-count)))
          (set-box! token-count n)
          (define token (~a "TOK-" n))
          (set-box! token-box token)
          (define cookie (~a "sess-" n))
          (set-box! cookie-box cookie)
          (respond! cout 200
                    (~a "<html><div id='token' style='display:none;'>" token
                        "</div></html>")
                    #:set-cookie (~a "id=" cookie "; Path=/"))]
         [(and (string=? path "/gui/") (null? params))
          ;; Bare GET /gui/ is the Web UI page itself: 200 with valid auth.
          (respond! cout 200 "{}")]
         [(string=? path "/gui/")
          (define token (query-lookup params "token"))
          (define cookie (header-lookup (req*-headers request) "cookie"))
          (cond
            [(and (string? token)
                  (string=? token (unbox token-box))
                  (string-contains? (or cookie "") (~a "id=" (unbox cookie-box))))
             (define action (query-lookup params "action"))
             (define route (assoc action routes))
             (if route
                 (respond! cout (cadr route) (cddr route))
                 (respond! cout 404
                           "{\"error\":\"unknown action\",\"status\":404}"))]
            [else (respond! cout 400 "invalid request")])]
         [else (respond! cout 404 "not found")])]))
  (define server (start-raw-server! handler))
  (list (car server) token-count token-box))

;; ------------------------------------------------------------------ waiting

;; Poll `thunk` every 50 ms until it returns non-#f (or the deadline
;; passes); returns that value or #f.
(define (wait-until secs thunk)
  (let loop ([deadline (+ (current-inexact-milliseconds) (* 1000 secs))])
    (define v (with-handlers ([exn:fail? (lambda (_) #f)]) (thunk)))
    (cond
      [v v]
      [(> (current-inexact-milliseconds) deadline) #f]
      [else (sleep 0.05) (loop deadline)])))

;; ------------------------------------------------------------- fake daemon

;; The racket executable running the tests — embedded into generated
;; shebang scripts so the fake daemons need nothing from $PATH.
(define (current-racket-path)
  ;; Shebangs must be absolute: exec-file can be a bare "racket" when the
  ;; test runner itself was found on $PATH.
  (define exec (find-system-path 'exec-file))
  (define resolved
    (or (and (complete-path? exec) exec)
        (find-executable-path (path->string exec))
        (find-executable-path "racket")
        exec))
  (path->string (simple-form-path resolved)))

(define-runtime-path fake-daemon-template-file "fake-daemon.py.tmpl")

;; Generate an executable fake daemon from the template file (see
;; fake-daemon.rkt.tmpl for the mode semantics).
(define (write-fake-daemon! path mode [exit-code 3])
  (define template (file->string fake-daemon-template-file))
  (define script (string-replace template "@MODE@" (~a mode)))
  (define script2 (string-replace script "@EXIT-CODE@" (~a exit-code)))
  (define script3
    (string-replace script2
                    "@STOP-FILE@"
                    (path->string (path-replace-extension path #".stop"))))
  (display-to-file script3 path #:exists 'replace)
  (file-or-directory-permissions path #o755)
  path)
