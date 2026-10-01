#lang racket/base

;; Action-API protocol tests against a local fake HTTP server implementing
;; the verified rslsync semantics (token session binding, 401, envelope
;; variants, 400-token retry, business errors). Ports are always ephemeral.

(require rackunit
         racket/string
         racket/tcp
         "support.rkt"
         "../syncpilot/action-api.rkt"
         "../syncpilot/httputil.rkt")

;; -------------------------------------------------------- full protocol mock

(define mock
  (start-resilio-mock!
   #:login "u" #:password "p"
   #:routes
   (list
    (cons "version" (cons 200 "{\"status\":200,\"value\":\"3.1.2 (1076)\"}"))
    (cons "shutdown" (cons 200 "{\"status\":200}"))
    (cons "getsyncfolders" (cons 200 "{\"folders\":[],\"status\":200}"))
    (cons "adddir" (cons 200 "{\"path\":\"/data/newdir/\"}"))
    (cons "addlink"
          (cons 200 "{\"status\":200,\"value\":{\"error\":205,\"message\":\"SE_SM_NO_IDENTITY\"}}"))
    (cons "parselink" (cons 500 "{\"error\":\"invalid link\",\"status\":500}"))
    (cons "getchartdata"
          (cons 200 "{\"value\":[{\"time\":5,\"value\":42},{\"time\":4,\"value\":7}]}")))))

(define client (make-client (list-ref mock 0) "u" "p"))

(test-case "probe: compatible daemon answers on its port"
  (check-eq? (probe-port client) 'compatible))

(test-case "version unwraps the success envelope"
  (check-equal? (version! client) "3.1.2 (1076)"))

(test-case "shutdown passes through"
  (check-true (void? (shutdown! client))))

(test-case "getsyncfolders replies without a value wrapper"
  (check-equal? (get-sync-folders! client) '()))

(test-case "adddir replies with the bare object"
  (check-equal? (add-dir! client "/data/newdir")
                (hasheq 'path "/data/newdir/")))

(test-case "addlink errors nested inside value are surfaced"
  (check-exn
   (lambda (e) (string-contains? (exn-message e) "addlink: SE_SM_NO_IDENTITY (205)"))
   (lambda () (add-link! client "key"))))

(test-case "HTTP 500 envelope errors become exceptions with the message"
  (check-exn
   (lambda (e) (string-contains? (exn-message e) "parselink: invalid link"))
   (lambda () (action! client "parselink" (list (cons "link" "bad"))))))

(test-case "getchartdata returns the newest sample per direction"
  (check-equal? (get-speeds! client) (cons 42 42)))

;; ------------------------------------------------------------- wrong creds

(test-case "wrong credentials answer 401 and are reported"
  (define wrong (make-client (list-ref mock 0) "u" "wrong"))
  (check-eq? (probe-port wrong) 'foreign)
  (check-exn
   (lambda (e)
     (string-contains? (exn-message e) "basic auth rejected (check webui credentials)"))
   (lambda () (version! wrong))))

;; ------------------------------------------------------------- probe cases

(test-case "probe: 403 counts as foreign"
  (define forbidden
    (start-raw-server!
     (lambda (cin cout)
       (read-http-request cin)
       (respond! cout 403 ""))))
  (check-eq? (probe-port (make-client (car forbidden) "u" "p")) 'foreign))

(test-case "probe: closed port is unreachable"
  (define l (tcp-listen 0 1 #f "127.0.0.1"))
  (define-values (_host port _rh _rp) (tcp-addresses l #t))
  (tcp-close l)
  (check-eq? (probe-port (make-client port "u" "p")) 'unreachable))

;; ------------------------------------------------- stale-token retry logic

(test-case "a stale token is refreshed exactly once, then the action retries"
  (define token-count (list-ref mock 1))
  (define mock-token (list-ref mock 2))
  (set-box! (resilio-client-token-box client) #f)
  (version! client) ; warms the cache: TOK-n and its session cookie
  (define count-before (unbox token-count))
  ;; Simulate the daemon dropping the session: only a fresh token works.
  (set-box! mock-token "definitely-not-the-issued-token")
  (check-equal? (version! client) "3.1.2 (1076)")
  (check-equal? (unbox token-count) (+ count-before 1)
                "exactly one token refresh for one stale-token rejection")
  ;; A follow-up action reuses the cached token (no extra refresh).
  (shutdown! client)
  (check-equal? (unbox token-count) (+ count-before 1)))

(test-case "two consecutive stale responses give up with an error"
  ;; Token requests succeed but every action answers `invalid request`.
  (define always-stale
    (start-raw-server!
     (lambda (cin cout)
       (define request (read-http-request cin))
       (if (string-contains? (req*-target request) "token.html")
           (respond! cout 200
                     "<html><div id='token' style='display:none;'>TT</div></html>")
           (respond! cout 400 "invalid request")))))
  (define c (make-client (car always-stale) "u" "p"))
  (check-exn
   (lambda (e)
     (string-contains? (exn-message e) "daemon keeps rejecting the CSRF token"))
   (lambda () (version! c))))
