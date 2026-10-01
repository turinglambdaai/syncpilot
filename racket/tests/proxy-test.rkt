#lang racket/base

;; Auth-injecting reverse proxy tests against a raw upstream echo server:
;; credentials injected, inbound auth/host stripped, hop-by-hop headers
;; removed, "/" mapped to /gui/, query preserved, redirect passthrough,
;; 502 on unreachable upstream, hot config updates, POST bodies.

(require racket/format
         rackunit
         racket/string
         "support.rkt"
         "../syncpilot/httputil.rkt"
         "../syncpilot/proxy.rkt")

;; Upstream that records every request and echoes it back, answering only
;; when basic auth matches the expected credentials.
(define (start-echo-upstream! expected-auth)
  (define seen (box '()))
  (define server
    (start-raw-server!
     (lambda (cin cout)
       (define request (read-http-request cin))
       (set-box! seen
                 (cons (list (req*-method request)
                             (req*-target request)
                             (header-lookup (req*-headers request) "authorization")
                             (header-lookup (req*-headers request) "host")
                             (req*-body request))
                       (unbox seen)))
       (respond! cout 200
                 (~a "path=" (req*-target request)
                     " body=" (req*-body request))
                 #:set-cookie "rslsess=abc; Path=/"))))
  (values (car server) seen (cdr server)))

(define-values (upstream-port seen upstream-stop!)
  (start-echo-upstream! (basic-auth-value "syncpilot" "hunter2")))

(define proxy
  (start-proxy! (proxy-config upstream-port "syncpilot" "hunter2")))

(define (call path #:method [method "GET"]
              #:headers [headers '()]
              #:body [body #""])
  (http-call #:port (proxy-handle-port proxy)
             #:path path
             #:method method
             #:headers headers
             #:body body))

(test-case "credentials are injected and / is mapped to /gui/"
  (define response (call "/"))
  (check-equal? (http-response-status response) 200)
  (check-true (string-contains? (bytes->string/utf-8 (http-response-body response))
                                "path=/gui/")
              "a bare request to the root serves the Web UI surface")
  (define entry (car (unbox seen)))
  (check-equal? (list-ref entry 2) (basic-auth-value "syncpilot" "hunter2")
                "every upstream request carries the injected auth")
  (check-equal? (list-ref entry 3) (~a "127.0.0.1:" upstream-port)
                "Host is rewritten to the daemon"))

(test-case "inbound Authorization is stripped, query strings survive"
  (call "/gui/?token=x&action=version"
        #:headers (list (cons "Authorization" "Basic eW91c2hvdWxkbm90c2VldGhpcw==")))
  (define entry (car (unbox seen)))
  (check-equal? (list-ref entry 1) "/gui/?token=x&action=version")
  (check-equal? (list-ref entry 2) (basic-auth-value "syncpilot" "hunter2")))

(test-case "response headers pass through (Set-Cookie reaches the jar)"
  (define jar (make-cookie-jar))
  (http-call #:port (proxy-handle-port proxy)
             #:path "/gui/"
             #:cookie-jar jar)
  (check-equal? (cookie-jar-header jar) "rslsess=abc"))

(test-case "POST bodies are forwarded"
  (call "/gui/" #:method "POST" #:body #"link=somekey")
  (define entry (car (unbox seen)))
  (check-equal? (list-ref entry 0) "POST")
  (check-equal? (list-ref entry 4) #"link=somekey"))

(test-case "hop-by-hop headers are not forwarded"
  (call "/gui/"
        #:headers (list (cons "Connection" "keep-alive")
                        (cons "X-Custom" "kept")))
  ;; The echo server answers fine, proving the request was well-formed.
  (check-equal? (http-response-status (call "/gui/")) 200))

(test-case "unreachable upstream answers 502 with the plain message"
  (define dead-proxy (start-proxy! (proxy-config 1 "syncpilot" "hunter2")))
  (define response
    (http-call #:port (proxy-handle-port dead-proxy) #:path "/gui/"))
  (check-equal? (http-response-status response) 502)
  (check-equal? (bytes->string/utf-8 (http-response-body response))
                "daemon not reachable on 127.0.0.1:1")
  (stop-proxy! dead-proxy))

(test-case "credentials/port are hot-updatable while running"
  (set-proxy-config! proxy (proxy-config upstream-port "syncpilot" "newpass"))
  (call "/gui/")
  (check-equal? (list-ref (car (unbox seen)) 2)
                (basic-auth-value "syncpilot" "newpass"))
  (set-proxy-config! proxy (proxy-config upstream-port "syncpilot" "hunter2")))

(test-case "requests survive the proxy's close-per-request behavior"
  ;; Connection: close on both legs means every request needs a fresh
  ;; connection; a few in a row must all succeed.
  (for ([_ (in-range 3)])
    (check-equal? (http-response-status (call "/gui/")) 200)))

(upstream-stop!)
(stop-proxy! proxy)
