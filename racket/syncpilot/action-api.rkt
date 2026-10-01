#lang racket/base

;; Minimal client for the rslsync Web UI "action" API (3.x, verified facts in
;; docs/api-verified.md — this module ports src-tauri/src/api.rs).
;;
;; Protocol:
;; - HTTP basic auth on EVERY request (there is no login endpoint).
;; - CSRF token from `POST /gui/token.html?t=<epoch-ms>`: the body wraps the
;;   token in HTML (`<div id='token' …>TOKEN</div>`); the token is bound to
;;   the HTTP session, so requests share one cookie jar.
;; - Actions: `GET /gui/?token=<TOK>&action=<name>&<params>&t=<ms>`.
;;   A stale/missing token answers HTTP 400 + `invalid request` — refresh the
;;   token and retry ONCE. Wrong credentials answer 401 with an empty body.
;; - Success envelope: `{"status":200,"value":…}`; `getsyncfolders` replies
;;   `{"folders":[…],"status":200}` and `adddir` replies `{"path":…}` without
;;   a `value` wrapper (the bare object is returned in those cases).
;; - Business errors: HTTP 500 + `{"error":…}`; some actions (addlink) reply
;;   HTTP 200 with the error nested inside `value` (checked by add-link!).

(require json
         racket/match
         racket/string
         "httputil.rkt")

(provide (struct-out resilio-client)
         make-client
         probe-port
         action!
         ;; probe result symbols: 'compatible 'foreign 'unreachable
         version!
         shutdown!
         get-sync-folders!
         add-link!
         add-dir!
         get-chart-data!
         get-license-info!
         start-trial-period!
         set-limits!
         get-peers-stat!
         get-session-stats!
         get-system-info!
         get-app-info!
         secret!
         get-sync-jobs!
         get-speeds!)

(struct resilio-client (port login password cookies token-box lock) #:transparent)

(define token-endpoint "/gui/token.html")
(define action-endpoint "/gui/")

(define (make-client port login password)
  (resilio-client port
                  login
                  password
                  (make-cookie-jar)
                  (box #f)
                  (make-semaphore 1)))

;; ------------------------------------------------------------- token handling

;; The token.html body wraps the token in HTML tags; the official Web UI
;; matches `>([^<]+)<`. Like the Rust client, walk candidate tag pairs from
;; the end and take the first non-empty payload (the trailing </html> pair
;; yields an empty payload and is skipped).
(define (extract-token body)
  (let loop ([candidates (regexp-match* #rx">([^<]+)<" body #:match-select cadr)])
    (cond
      [(null? candidates) #f]
      [(string=? (car candidates) "") (loop (cdr candidates))]
      [else (car candidates)])))

(define (fetch-token! client)
  (define response
    (http-call #:port (resilio-client-port client)
               #:method "POST"
               #:path (string-append token-endpoint "?t=" (number->string (epoch-ms)))
               #:headers (list (cons "Authorization"
                                     (basic-auth-value (resilio-client-login client)
                                                       (resilio-client-password client))))
               #:cookie-jar (resilio-client-cookies client)))
  (cond
    [(= (http-response-status response) 401)
     (error 'resilio "basic auth rejected (check webui credentials)")]
    [(not (<= 200 (http-response-status response) 299))
     (error 'resilio "token request -> HTTP ~a" (http-response-status response))]
    [else
     (define body (bytes->string/utf-8 (http-response-body response)))
     (or (extract-token body)
         (error 'resilio "token response has no token payload: ~a"
                (substring body 0 (min 100 (string-length body)))))]))

(define (token-or-refresh! client force?)
  (call-with-semaphore
   (resilio-client-lock client)
   (lambda ()
     (cond
       [(and (not force?) (unbox (resilio-client-token-box client))) => values]
       [else
        (define token (fetch-token! client))
        (set-box! (resilio-client-token-box client) token)
        token]))))

;; ----------------------------------------------------------- error envelopes

;; Top-level envelope error `{"error":"msg","status":500}`; nested form
;; `{"error":205,"message":"SE_SM_NO_IDENTITY"}` renders as "MSG (205)".
(define (error-message v)
  (and (hash? v)
       (hash-has-key? v 'error)
       (let ([err (hash-ref v 'error)])
         (cond
           [(string? err) err]
           [(number? err)
            (string-append (hash-ref v 'message "unknown error")
                           (format " (~a)" err))]
           [else #f]))))

(define (parse-json-body who action response)
  (with-handlers ([exn:fail? (lambda (e)
                               (error who "action ~a non-JSON response: ~a"
                                      action (exn-message e)))])
    (read-json (open-input-bytes (http-response-body response)))))

;; -------------------------------------------------------------- action calls

;; Run one action and return its `value` payload (or the bare object for
;; actions that reply without a `value` wrapper). Retries once with a fresh
;; token when the daemon reports the current one invalid.
(define (action! client name [params '()])
  (define (call-once token)
    (define query
      (string-append
       action-endpoint
       "?"
       (encode-query (append (list (cons "token" token)
                                   (cons "action" name)
                                   (cons "t" (number->string (epoch-ms))))
                             params))))
    (http-call #:port (resilio-client-port client)
               #:path query
               #:headers (list (cons "Authorization"
                                     (basic-auth-value (resilio-client-login client)
                                                       (resilio-client-password client))))
               #:cookie-jar (resilio-client-cookies client)))
  (let retry ([force-refresh? #f] [attempt 0])
    (define token (token-or-refresh! client force-refresh?))
    (define response (call-once token))
    (define status (http-response-status response))
    (define text (bytes->string/utf-8 (http-response-body response)))
    (cond
      [(and (= status 400) (string-contains? text "invalid request"))
       (set-box! (resilio-client-token-box client) #f)
       (if (zero? attempt)
           (retry #t 1)
           (error 'resilio "~a: daemon keeps rejecting the CSRF token" name))]
      [(= status 401)
       (error 'resilio "basic auth rejected (check webui credentials)")]
      [(not (<= 200 status 299))
       (define v (parse-json-body 'resilio name response))
       (cond
         [(error-message v) => (lambda (msg) (error 'resilio "~a: ~a" name msg))]
         [else (error 'resilio "~a -> HTTP ~a: ~a" name status
                      (substring text 0 (min 200 (string-length text))))])]
      [else
       (define v (parse-json-body 'resilio name response))
       (cond
         [(error-message v) => (lambda (msg) (error 'resilio "~a: ~a" name msg))]
         [(and (hash? v) (hash-has-key? v 'value)) (hash-ref v 'value)]
         [else v])])))

(define (probe-port client)
  (with-handlers ([exn:fail? (lambda (_) 'unreachable)])
    (define response
      (http-call #:port (resilio-client-port client)
                 #:path action-endpoint
                 #:headers (list (cons "Authorization"
                                       (basic-auth-value (resilio-client-login client)
                                                         (resilio-client-password client))))
                 #:timeout-secs 3))
    (define status (http-response-status response))
    (cond
      [(<= 200 status 299) 'compatible]
      [(or (= status 401) (= status 403)) 'foreign]
      [else 'unreachable])))

;; ------------------------------------------------------------- named actions

(define (version! client)
  (define v (action! client "version"))
  (if (string? v) v (format "~a" v)))

(define (shutdown! client)
  (action! client "shutdown")
  (void))

;; `{"folders":[…],"status":200}` — no value wrapper.
(define (get-sync-folders! client)
  (define v (action! client "getsyncfolders" (list (cons "discovery" "1"))))
  (if (hash? v) (hash-ref v 'folders '()) '()))

;; Join a share by key. Errors arrive as HTTP 200 with the error nested
;; inside `value` (`{"status":200,"value":{"error":205,…}}`).
(define (add-link! client link)
  (define v (action! client "addlink" (list (cons "link" link))))
  (define msg (error-message v))
  (when msg (error 'resilio "addlink: ~a" msg))
  v)

;; Create a folder; replies `{"path":"…"}` without a value wrapper.
(define (add-dir! client dir)
  (action! client "adddir" (list (cons "dir" dir))))

;; Chart types from the official Web UI code: CPU 0, DOWNSPEED 1, UPSPEED 2.
;; `from=0&to=0` returns the recent window, newest sample first.
(define (get-chart-data! client type)
  (action! client "getchartdata"
           (list (cons "type" (number->string type))
                 (cons "from" "0")
                 (cons "to" "0"))))

(define (get-license-info! client) (action! client "getlicenseinfo"))

(define (start-trial-period! client) (action! client "starttrialperiod"))

;; ulrate/dlrate are KB/s, -1 = unlimited (server-side interpretation).
(define (set-limits! client up-kb-s down-kb-s)
  (action! client "setsettings"
           (list (cons "ulrate" (number->string up-kb-s))
                 (cons "dlrate" (number->string down-kb-s)))))

(define (get-peers-stat! client) (action! client "getpeersstat"))
(define (get-session-stats! client) (action! client "getsessionstats"))
(define (get-system-info! client) (action! client "getsysteminfo"))
(define (get-app-info! client) (action! client "getappinfo"))
(define (secret! client) (action! client "secret"))
(define (get-sync-jobs! client) (action! client "getsyncjobs"))

;; One getchartdata sample per direction, in bytes/sec (newest first).
;; `action!` already unwraps the `{"value":[…]}` envelope, so `v` is normally
;; the sample list itself; the hash case guards bare-envelope responses.
(define (first-sample v)
  (define samples
    (cond
      [(list? v) v]
      [(and (hash? v) (hash-has-key? v 'value)) (hash-ref v 'value)]
      [else '()]))
  (cond
    [(and (pair? samples) (hash? (car samples))) (hash-ref (car samples) 'value 0)]
    [(and (pair? samples) (number? (car samples))) (car samples)]
    [(number? v) v]
    [else 0]))

(define (get-speeds! client)
  (cons (first-sample (get-chart-data! client 1))
        (first-sample (get-chart-data! client 2))))
