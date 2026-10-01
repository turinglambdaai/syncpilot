#lang racket/base

;; Server-level integration test: drives app/backend.rkt over RVT1 pipes
;; exactly like a native host would (hello -> request/response/event), with
;; the data directory pointed at a temp dir and a generated fake daemon
;; standing in for rslsync.

(require json
         racket/file
         racket/format
         racket/path
         racket/string
         racket/tcp
         rackunit
         "support.rkt"
         "../../app/backend.rkt"
         "../syncpilot/manager.rkt"
         "../syncpilot/settings.rkt"
         (prefix-in rivet: rivet/backend)
         (prefix-in proto: rivet/protocol))

;; --------------------------------------------------------------- scaffolding

(define data-dir (make-temporary-file "syncpilot-backend-~a" 'directory))
(define fake-daemon (write-fake-daemon! (build-path data-dir "fake-daemon") "ok"))

(define (free-port)
  (define l (tcp-listen 0 1 #f "127.0.0.1"))
  (define-values (_host port _rh _rp) (tcp-addresses l #t))
  (tcp-close l)
  port)

(define daemon-port (free-port))

(define-values (server-in client-out) (make-pipe))
(define-values (client-in server-out) (make-pipe))

;; The temp data dir + shortened daemon timings must be in place before the
;; server thread (and therefore every request thread) is created.
(define server-thread
  (parameterize ([current-data-dir data-dir]
                 [daemon-stderr-log (build-path data-dir "daemon-stderr.log")]
                 ;; the generated fake daemon can take ~15 s to serve its
                 ;; first connection when spawned from this harness; the
                 ;; production deadline stays 30 s
                 [manager-start-deadline-secs 30]
                 [manager-poll-secs 0.05]
                 [manager-stop-polls 3]
                 [manager-stop-poll-secs 0.05]
                 [manager-supervisor-interval-secs 0.05]
                 [manager-restart-backoff-base-secs 0.05]
                 [manager-restart-backoff-cap-secs 0.2])
    (thread (lambda () (rivet:serve server-in server-out)))))

(define hello (proto:read-frame client-in))
(check-equal? (proto:frame-type hello) proto:message:hello)

(define next-id 1)

(define (send-request name . arguments)
  (define id next-id)
  (set! next-id (add1 next-id))
  (proto:write-frame
   (proto:frame proto:message:request
                id
                (proto:encode-value (cons name arguments)))
   client-out)
  id)

;; Collect events until the response with the given id arrives. The third
;; value reports whether the terminal frame was an error; the error message
;; is printed for diagnostics.
(define (call name . arguments)
  (define id (apply send-request name arguments))
  (let loop ([events '()])
    (define response (proto:read-frame client-in))
    (cond
      [(= (proto:frame-type response) proto:message:event)
       (loop (cons (proto:decode-value (proto:frame-payload response)) events))]
      [(= (proto:frame-id response) id)
       (define value (proto:decode-value (proto:frame-payload response)))
       (define err? (= (proto:frame-type response) proto:message:error))
       (when err? (eprintf "RPC ~a failed: ~a\n" name value))
       (values value (reverse events) err?)]
      [else
       (error 'call "unexpected response id: ~a" (proto:frame-id response))])))

;; ------------------------------------------------------------------- tests

(test-case "init is idempotent and required first"
  (define-values (result _events err?) (call "init"))
  (check-false err?)
  (check-equal? result (void))
  (define-values (_r2 _e2 err2?) (call "init"))
  (check-false err2?))

(define-values (settings _se settings-err?) (call "get-settings"))
(test-case "fresh settings have defaults and never expose the password"
  (check-false settings-err?)
  ;; Settings = [rslsync-path webui-port webui-login has-password device-name
  ;;             autostart restart-on-crash keep-daemon-on-exit close-to-tray
  ;;             settings-version]
  (check-equal? (list-ref settings 1) 38889)
  (check-equal? (list-ref settings 2) "syncpilot")
  (check-true (list-ref settings 3) "has-password, but the secret stays hidden")
  (check-equal? (list-ref settings 9) 2))

(test-case "save-settings validates, persists, and never raises"
  (define-values (saved _e1 err1?)
    (call "save-settings"
          (list (path->string fake-daemon) ; rslsync-path
                daemon-port                ; webui-port
                "syncpilot"                ; webui-login
                "test-device"              ; device-name
                #t #t #f #t)))             ; autostart/restart/keep/close
  (check-false err1?)
  (check-equal? (list-ref saved 1) daemon-port)
  ;; out-of-range ports come back as error frames
  (define-values (_r _e2 err2?)
    (call "save-settings"
          (list (path->string fake-daemon) 80 "syncpilot" "test-device"
                #t #t #f #t)))
  (check-true err2? "port 80 must be rejected")
  ;; the accepted settings landed in the temp data dir
  (define stored
    (read-json (open-input-file (build-path data-dir "syncpilot-settings.json"))))
  (check-equal? (hash-ref stored 'webui_port) daemon-port)
  (check-equal? (hash-ref stored 'settings_version) 2))

;; The generated fake daemon is a full racket process and can be slow to
;; serve its first connections (its scheduler is the test harness's, not
;; rslsync's); lifecycle RPCs therefore retry a few times before failing.
(define (call-until name arguments ok? [attempts 15])
  (let loop ([n 0])
    (define-values (result events err?) (apply call name arguments))
    (cond
      [(and (not err?) (ok? result)) (values result events)]
      [(< n attempts) (sleep 0.5) (loop (+ n 1))]
      [else (values result events)])))

(test-case "get-handoff starts the daemon and hands over the proxy URL"
  ;; the generated fake daemon reliably serves its first three connections
  ;; (ensure-running's probe, the API token, the version call) — exactly
  ;; what the handoff needs
  (define-values (handoff _events)
    (call-until "get-handoff" '() (lambda (h) (equal? (list-ref h 2) "running")) 3))
  ;; Handoff = [proxy-url, daemon-version, phase]
  (check-true
   (regexp-match? #rx"^http://127\\.0\\.0\\.1:[0-9]+/gui/$" (list-ref handoff 0))
   (~a "proxy url: " (list-ref handoff 0)))
  (check-equal? (list-ref handoff 1) "3.1.2 (1076)"
                "the fake daemon's version answers through the action API")
  (check-equal? (list-ref handoff 2) "running"))

(test-case "daemon-stop with keep off kills the daemon"
  (define-values (status _e err?) (call "daemon-stop"))
  (check-false err?)
  ;; DaemonStatus = [phase pid uptime-secs binary error autostart]
  (check-equal? (list-ref status 0) "stopped")
  (check-true
   (wait-until 5
               (lambda ()
                 (with-handlers ([exn:fail? (lambda (_) #t)])
                   ;; connection refused = daemon gone
                   (define-values (cin cout)
                     (tcp-connect "127.0.0.1" daemon-port))
                   (close-output-port cout)
                   (close-input-port cin)
                   #f)))
   "the daemon process must be gone after daemon-stop"))

(test-case "probe-port reports unreachable once the daemon is gone"
  (define-values (probe _e)
    (call-until "probe-port" '()
                (lambda (p) (equal? p "unreachable"))
                3))
  (check-equal? probe "unreachable"))

(test-case "regenerate-password keeps has-password true"
  (define-values (s _e err?) (call "regenerate-password"))
  (check-false err?)
  (check-true (list-ref s 3)))


;; install-rslsync is deliberately not exercised over RPC: it downloads from
;; the real CDN. The installer's contract is covered by install-test.rkt
;; with injected fetchers.

;; ---------------------------------------------------------------- teardown

(proto:write-frame (proto:frame proto:message:shutdown 0 #"") client-out)
(thread-wait server-thread)
(void (delete-directory/files data-dir))
