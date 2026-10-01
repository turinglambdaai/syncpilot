#lang racket/base

;; Loopback reverse proxy that injects the app-generated Web UI credentials
;; (port of src-tauri/src/proxy.rs to raw TCP).
;;
;; The official Resilio Web UI (which hosts embed in a webview) is protected
;; by HTTP basic auth that a webview cannot pre-fill. The proxy adds the
;; `Authorization` header to every request; the user gets the official UI
;; without ever seeing a login prompt, and the real daemon port never serves
;; an unauthenticated request.
;;
;; Implementation notes / v1 simplifications:
;; - Raw TCP + manual HTTP/1.1 head parsing: net/url cannot inject headers
;;   into a pass-through proxy cleanly.
;; - Keep-alive is disabled on both legs (`Connection: close` is forced).
;;   Each client connection serves exactly one request; browsers reopen
;;   connections transparently. Correct and simple; the embedded Web UI does
;;   not require pipelining.
;; - Request and response bodies are buffered (capped at 64 MB, like the old
;;   Rust proxy). Inbound chunked bodies are decoded and re-emitted with an
;;   explicit Content-Length; upstream responses keep their headers minus
;;   hop-by-hop fields and gain a Content-Length.
;; - Upstream redirects are passed through untouched WITH the injected
;;   header — never followed (a followed redirect would lose the auth).
;; - `Expect: 100-continue` is not emulated; the embedded UI does not use it.

(require racket/format
         racket/string
         racket/tcp
         "httputil.rkt")

(provide (struct-out proxy-config)
         (struct-out proxy-handle)
         proxy-handle-base-url
         start-proxy!
         stop-proxy!
         set-proxy-config!
         ;; exposed for tests
         parse-request-head
         read-request-body!
         upstream-request-head
         (struct-out req))

(struct proxy-config (daemon-port login password) #:transparent)
;; daemon-port : exact-integer?  — upstream Web UI port on 127.0.0.1
;; login/password : string?      — injected credentials

(struct proxy-handle (port config-box custodian) #:transparent)

(define (proxy-handle-base-url handle)
  (~a "http://127.0.0.1:" (proxy-handle-port handle)))

;; Hop-by-hop headers that must not be forwarded (RFC 9110 §7.6.1).
(define hop-by-hop-headers
  '("connection" "keep-alive" "proxy-authenticate" "proxy-authorization"
    "te" "trailers" "transfer-encoding" "upgrade"))

(define (hop-by-hop? name)
  (member (string-downcase name) hop-by-hop-headers))

(define (string-ci=? a b) (string=? (string-downcase a) (string-downcase b)))

;; Credentials/port are hot-updatable while the proxy is running (the
;; settings dialog triggers this after every save, like update_config in the
;; Rust implementation).
(define (set-proxy-config! handle config)
  (set-box! (proxy-handle-config-box handle) config)
  (void))

;; ------------------------------------------------------------------ server

;; Spawn the proxy on an ephemeral loopback port. The listener and every
;; connection thread live under one custodian; stop-proxy! tears it all down.
;;
;; exclude-port: the Web UI port the daemon will bind. The proxy itself
;; binds an OS-assigned ephemeral port, and without this guard that port
;; could (rarely) come up as exactly the daemon's port — the proxy would
;; then answer the daemon's probes with 502 and block its bind. Noticed in
;; the integration test; the same theoretical hazard exists in production.
(define (start-proxy! config #:exclude-port [exclude-port #f])
  (define cust (make-custodian))
  (let bind ([try 0])
    (define listener
      (parameterize ([current-custodian cust])
        (tcp-listen 0 16 #f "127.0.0.1")))
    ;; On a listener tcp-addresses yields (local-host local-port remote-host
    ;; remote-port); the ephemeral bound port is the second value.
    (define-values (_host port _rh _rp) (tcp-addresses listener #t))
    (cond
      [(and exclude-port (= port exclude-port) (< try 5))
       (tcp-close listener)
       (bind (+ try 1))]
      [else
       (define handle (proxy-handle port (box config) cust))
       (parameterize ([current-custodian cust])
         (thread
          (lambda ()
            (let loop ()
              (with-handlers ([exn:fail? void])
                (define-values (cin cout) (tcp-accept listener))
                ;; Each connection gets its own thread; one request per
                ;; connection (see the module header on keep-alive).
                (thread (lambda () (serve-connection! handle cin cout))))
              (loop)))))
       handle])))

(define (stop-proxy! handle)
  (custodian-shutdown-all (proxy-handle-custodian handle)))

;; ------------------------------------------------------------ request path

(define (serve-connection! handle cin cout)
  (dynamic-wind
    void
    (lambda ()
      (with-handlers ([exn:fail? void])
        (define config (unbox (proxy-handle-config-box handle)))
        (define head (parse-request-head cin))
        (define body (read-request-body! cin head))
        (forward-request! config head body cout)))
    (lambda ()
      (with-handlers ([exn:fail? void])
        (close-input-port cin)
        (close-output-port cout)))))

(struct req (method raw-path query headers) #:transparent)

(define (parse-request-head in)
  (define head-bytes (read-head in))
  (define lines (string-split (bytes->string/latin-1 head-bytes) "\r\n" #:trim? #f))
  (when (null? lines) (error 'proxy "empty request head"))
  (define parts (string-split (car lines) " " #:trim? #t))
  (unless (>= (length parts) 3)
    (error 'proxy "malformed request line: ~a" (car lines)))
  (define target (list-ref parts 1))
  (define sep (string-index-of target #\?))
  (req (list-ref parts 0)
       (if sep (substring target 0 sep) target)
       (if sep (substring target (add1 sep)) #f)
       (for/list ([line (in-list (cdr lines))]
                  #:when (not (string=? line ""))
                  #:do [(define idx (string-index-of line #\:))]
                  #:when idx)
         (cons (string-trim (substring line 0 idx))
               (string-trim (substring line (add1 idx)))))))

(define (string-index-of s c)
  (let loop ([i 0])
    (cond
      [(= i (string-length s)) #f]
      [(char=? (string-ref s i) c) i]
      [else (loop (add1 i))])))

(define (header-lookup headers name)
  (define lowered (string-downcase name))
  (for/or ([pair (in-list headers)])
    (and (string=? (string-downcase (car pair)) lowered) (cdr pair))))

(define (read-request-body! in head)
  (cond
    [(header-lookup (req-headers head) "transfer-encoding")
     => (lambda (te)
          (unless (member "chunked"
                          (map string-trim (string-split (string-downcase te) ",")))
            (error 'proxy "unsupported transfer encoding: ~a" te))
          (read-chunked in))]
    [(header-lookup (req-headers head) "content-length")
     => (lambda (v)
          (define n (string->number (string-trim v)))
          (unless n (error 'proxy "malformed Content-Length: ~a" v))
          (unless (<= n max-http-body-bytes)
            (error 'proxy "proxy body too large (limit 64 MB)"))
          (read-exact-bytes in n))]
    [else #""]))

;; Build the upstream request head: inject Authorization, strip the inbound
;; one plus hop-by-hop fields and Host, force Connection: close, re-frame
;; the buffered body with an explicit Content-Length.
(define (upstream-request-head config head body-bytes)
  (define authorization
    (basic-auth-value (proxy-config-login config)
                      (proxy-config-password config)))
  (define path
    ;; Everything the app serves lives under /gui/; a bare request to the
    ;; proxy root is served there like the daemon's own redirect would be.
    (if (string=? (req-raw-path head) "/")
        "/gui/"
        (req-raw-path head)))
  (define target
    (if (req-query head)
        (~a path "?" (req-query head))
        path))
  (define forwarded
    (string-join
     (for/list ([pair (in-list (req-headers head))]
                #:unless (hop-by-hop? (car pair))
                #:unless (string-ci=? (car pair) "authorization")
                #:unless (string-ci=? (car pair) "host")
                ;; the body is re-framed below with exactly one
                ;; Content-Length
                #:unless (string-ci=? (car pair) "content-length"))
       (~a (car pair) ": " (cdr pair)))
     "\r\n"))
  (~a (req-method head) " " target " HTTP/1.1\r\n"
      "Host: 127.0.0.1:" (proxy-config-daemon-port config) "\r\n"
      "Authorization: " authorization "\r\n"
      (if (string=? forwarded "") "" (~a forwarded "\r\n"))
      "Content-Length: " (bytes-length body-bytes) "\r\n"
      "Connection: close\r\n"
      "\r\n"))

(define (forward-request! config head body-bytes cout)
  (define daemon-port (proxy-config-daemon-port config))
  (define (daemon-unreachable!)
    (respond-plain! cout 502
                    (~a "daemon not reachable on 127.0.0.1:" daemon-port)))
  (define-values (uin uout)
    (with-handlers ([exn:fail?
                     (lambda (e)
                       (daemon-unreachable!)
                       (raise e))])
      (tcp-connect "127.0.0.1" daemon-port)))
  (dynamic-wind
    void
    (lambda ()
      (with-handlers
          ([exn:fail?
            (lambda (e)
              (unless (exn:break? e) (daemon-unreachable!)))])
        (display (upstream-request-head config head body-bytes) uout)
        (write-bytes body-bytes uout)
        (flush-output uout)
        ;; The whole upstream response is read before anything is written
        ;; back, so a mid-response failure can still surface as 502.
        (define upstream (read-http-response uin))
        (write-response! head upstream cout)))
    (lambda ()
      (with-handlers ([exn:fail? void])
        (close-input-port uin)
        (close-output-port uout)))))

;; Re-emit the upstream response: hop-by-hop headers stripped, framing
;; replaced with Content-Length + Connection: close. HEAD keeps the upstream
;; Content-Length header and carries no body.
(define (write-response! head upstream cout)
  (define is-head? (string-ci=? (req-method head) "HEAD"))
  (define body (if is-head? #"" (http-response-body upstream)))
  (display
   (~a "HTTP/1.1 " (http-response-status upstream) " "
       (if (< (http-response-status upstream) 400) "OK" "Error") "\r\n")
   cout)
  (for ([pair (in-list (http-response-headers upstream))]
        #:unless (hop-by-hop? (car pair))
        #:unless (string-ci=? (car pair) "content-length"))
    (display (~a (title-case-header (car pair)) ": " (cdr pair) "\r\n") cout))
  (display (~a "Content-Length: " (bytes-length body) "\r\n") cout)
  (display "Connection: close\r\n\r\n" cout)
  (unless is-head? (write-bytes body cout))
  (flush-output cout))

;; Re-title lowercased header names for browsers (cosmetic; names are
;; case-insensitive per RFC 9110 §5.1).
(define (title-case-header name)
  (string-join
   (for/list ([word (in-list (string-split name "-"))])
     (if (zero? (string-length word))
         word
         (string-append (string-upcase (substring word 0 1))
                        (substring word 1))))
   "-"))

(define (respond-plain! cout code message)
  (display
   (~a "HTTP/1.1 " code " Error\r\n"
       "Content-Type: text/plain; charset=utf-8\r\n"
       "Content-Length: " (string-utf-8-length message) "\r\n"
       "Connection: close\r\n"
       "\r\n"
       message)
   cout)
  (flush-output cout))
