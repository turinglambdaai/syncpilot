#lang racket/base

;; Daemon manager tests against generated fake daemons: adoption of a
;; compatible daemon, the foreign-port refusal, spawn + start wait (with
;; shortened deadline), exit-code reporting, graceful stop, keep-alive
;; detach, and both supervisor outcomes (restart with backoff / crashed).
;; All listeners use ephemeral ports; timing knobs are parameters.

(require rackunit
         racket/file
         racket/string
         racket/format
         racket/path
         racket/tcp
         "support.rkt"
         "../syncpilot/action-api.rkt"
         "../syncpilot/conf.rkt"
         "../syncpilot/manager.rkt"
         "../syncpilot/settings.rkt")

;; --------------------------------------------------------------- utilities

(define (free-port)
  (define l (tcp-listen 0 1 #f "127.0.0.1"))
  (define-values (_host port _rh _rp) (tcp-addresses l #t))
  (tcp-close l)
  port)

(define (probe3 port login password)
  (with-handlers ([exn:fail? (lambda (_) 'unreachable)])
    (probe-port (make-client port login password))))

(define (make-test-manager dir port binary-path
                           #:restart-on-crash [restart-on-crash #t]
                           #:keep [keep #f])
  (make-manager dir
                (app-settings (path->string binary-path) port "syncpilot" "pw"
                              "test-device" #t restart-on-crash keep #t 2)))

(define events (box '()))
(define (record-events! m)
  (set-manager-notify!
   m
   (lambda (st)
     (set-box! events (cons (daemon-status-phase st) (unbox events))))))

(define (run-with-timing thunk
                          #:deadline [deadline 5]
                          #:poll [poll 0.05]
                          #:stop-polls [stop-polls 3]
                          #:stop-poll [stop-poll 0.05]
                          #:supervisor [supervisor 0.05]
                          #:backoff-base [backoff-base 0.05]
                          #:backoff-cap [backoff-cap 0.2])
  (parameterize ([manager-start-deadline-secs deadline]
                 [manager-poll-secs poll]
                 [manager-stop-polls stop-polls]
                 [manager-stop-poll-secs stop-poll]
                 [manager-supervisor-interval-secs supervisor]
                 [manager-restart-backoff-base-secs backoff-base]
                 [manager-restart-backoff-cap-secs backoff-cap])
    (thunk)))

;; ------------------------------------------------------------- binary lookup

(test-case "find-binary resolves the explicit setting first"
  (define dir (make-temporary-file "syncpilot-mgr-~a" 'directory))
  (define script (write-fake-daemon! (build-path dir "fake-daemon") "ok"))
  (define m (make-test-manager dir (free-port) script))
  (check-equal? (find-binary m) script)
  ;; Without an explicit path, an empty well-known list and an empty PATH
  ;; must find nothing — regardless of what the test machine has installed.
  (define m2 (make-test-manager dir (free-port) script))
  (set-box! (manager-settings-box m2)
            (struct-copy app-settings (manager-settings m2) [rslsync-path ""]))
  (check-false (parameterize ([current-well-known-binary-paths '()]
                              [current-path-env #f])
                 (find-binary m2)))
  (delete-directory/files dir))

;; ------------------------------------------------------------ adopt + refuse

(test-case "a compatible daemon already on the port is adopted, not spawned"
  (define dir (make-temporary-file "syncpilot-mgr-~a" 'directory))
  (define script (write-fake-daemon! (build-path dir "fake-daemon") "ok"))
  (define port (free-port))
  (define settings (app-settings (path->string script) port "syncpilot" "pw"
                                 "test-device" #t #t #t #t 2))
  (define conf (write-conf! dir settings))
  (define-values (proc so si se)
    (subprocess #f #f #f (path->string script) "--nodaemon" "--config" (path->string conf)))
  (check-true (wait-until 5 (lambda () (eq? (probe3 port "syncpilot" "pw") 'compatible)))
              "fake daemon must come up")
  (define m (make-test-manager dir port script))
  (record-events! m)
  (run-with-timing (lambda () (ensure-running! m)))
  (define st (manager-status m))
  (check-eq? (daemon-status-phase st) 'running)
  (check-false (daemon-status-pid st) "adopted daemons have no child handle")
  (check-false (daemon-status-error st))
  ;; Cleanup: detach-like stop, then crash the fake daemon via its stop file.
  (stop! m)
  (display-to-file "stop" (path-replace-extension script #".stop") #:exists 'replace)
  (check-true (wait-until 5 (lambda () (eq? (probe3 port "syncpilot" "pw") 'unreachable)))
              "the adopted daemon must exit via its stop file")
  (subprocess-wait proc)
  (delete-directory/files dir))

(test-case "a foreign daemon on the port is reported, never adopted"
  (define dir (make-temporary-file "syncpilot-mgr-~a" 'directory))
  (define script (write-fake-daemon! (build-path dir "fake-daemon") "foreign"))
  (define port (free-port))
  (define settings (app-settings (path->string script) port "syncpilot" "pw"
                                 "test-device" #t #t #t #t 2))
  (define conf (write-conf! dir settings))
  (define-values (proc so si se)
    (subprocess #f #f #f (path->string script) "--nodaemon" "--config" (path->string conf)))
  (check-true (wait-until 5 (lambda () (eq? (probe3 port "syncpilot" "pw") 'foreign))))
  (define m (make-test-manager dir port script))
  (check-exn
   (lambda (e)
     (and (string-contains? (exn-message e) (~a "Port " port))
          (string-contains? (exn-message e) "different credentials")))
   (lambda () (run-with-timing (lambda () (ensure-running! m)))))
  (check-eq? (daemon-status-phase (manager-status m)) 'failed)
  (subprocess-kill proc #t)
  (subprocess-wait proc)
  (delete-directory/files dir))

;; --------------------------------------------------------------- spawn paths

(test-case "unreachable port spawns the daemon and waits for it"
  (define dir (make-temporary-file "syncpilot-mgr-~a" 'directory))
  (define script (write-fake-daemon! (build-path dir "fake-daemon") "ok"))
  (define port (free-port))
  (define m (make-test-manager dir port script))
  (record-events! m)
  (run-with-timing (lambda () (ensure-running! m)))
  (define st (manager-status m))
  (check-eq? (daemon-status-phase st) 'running)
  (check-true (exact-positive-integer? (daemon-status-pid st)))
  (check-equal? (daemon-status-binary st) (path->string script))
  (check-true (file-exists? (conf-path dir))
              "the conf must be written before every spawn")
  ;; The fake daemon derived its port from the conf: stop and verify the
  ;; manager killed the child (keep_daemon_on_exit = #f here).
  (stop! m)
  (check-eq? (daemon-status-phase (manager-status m)) 'stopped)
  (check-true (wait-until 5 (lambda () (eq? (probe3 port "syncpilot" "pw") 'unreachable)))
              "stop must kill the daemon when keep_daemon_on_exit is off")
  (delete-directory/files dir))

(test-case "keep_daemon_on_exit detaches instead of killing"
  (define dir (make-temporary-file "syncpilot-mgr-~a" 'directory))
  (define script (write-fake-daemon! (build-path dir "fake-daemon") "ok"))
  (define port (free-port))
  (define m (make-test-manager dir port script #:keep #t))
  (run-with-timing (lambda () (ensure-running! m)))
  (stop! m)
  (check-eq? (daemon-status-phase (manager-status m)) 'stopped)
  (check-eq? (probe3 port "syncpilot" "pw") 'compatible
             "a detached daemon keeps running")
  ;; End the detached daemon via its stop file.
  (display-to-file "stop" (path-replace-extension script #".stop") #:exists 'replace)
  (check-true (wait-until 5 (lambda () (eq? (probe3 port "syncpilot" "pw") 'unreachable))))
  (delete-directory/files dir))

(test-case "startup timeout is reported with the configured deadline"
  (define dir (make-temporary-file "syncpilot-mgr-~a" 'directory))
  (define script (write-fake-daemon! (build-path dir "fake-daemon") "never"))
  (define m (make-test-manager dir (free-port) script))
  (check-exn
   (lambda (e) (string-contains? (exn-message e) "daemon did not answer within 1s"))
   (lambda ()
     (run-with-timing (lambda () (ensure-running! m)) #:deadline 1 #:poll 0.05)))
  (check-eq? (daemon-status-phase (manager-status m)) 'failed)
  (delete-directory/files dir))

(test-case "a daemon that exits during startup reports its exit code"
  (define dir (make-temporary-file "syncpilot-mgr-~a" 'directory))
  (define script (write-fake-daemon! (build-path dir "fake-daemon") "exit" 3))
  (define m (make-test-manager dir (free-port) script))
  (check-exn
   (lambda (e) (string-contains? (exn-message e) "rslsync exited with code 3"))
   (lambda () (run-with-timing (lambda () (ensure-running! m)))))
  (check-eq? (daemon-status-phase (manager-status m)) 'failed)
  (delete-directory/files dir))

;; ---------------------------------------------------------------- supervisor

(test-case "crash supervisor restarts with backoff when enabled"
  (define dir (make-temporary-file "syncpilot-mgr-~a" 'directory))
  (define script (write-fake-daemon! (build-path dir "fake-daemon") "ok"))
  (define port (free-port))
  (define m (make-test-manager dir port script #:restart-on-crash #t))
  (run-with-timing (lambda () (ensure-running! m) (start-supervisor! m)))
  (define first-pid (daemon-status-pid (manager-status m)))
  (check-true (exact-positive-integer? first-pid))
  ;; Crash the daemon through its stop file, then remove the file again so
  ;; the supervisor's restart can come up cleanly.
  (display-to-file "stop" (path-replace-extension script #".stop") #:exists 'replace)
  (check-true (wait-until 5 (lambda () (eq? (probe3 port "syncpilot" "pw") 'unreachable)))
              "the fake daemon must exit on its stop file")
  ;; the daemon consumes its own stop file on the way out
  (define stop-path (path-replace-extension script #".stop"))
  (when (file-exists? stop-path) (delete-file stop-path))
  (check-true
   (wait-until 8
               (lambda ()
                 (define st (manager-status m))
                 (and (eq? (daemon-status-phase st) 'running)
                      (daemon-status-pid st)
                      (not (= (daemon-status-pid st) first-pid)))))
   "the supervisor must restart the daemon under a new pid")
  ;; End the restarted daemon for cleanup.
  (display-to-file "stop" (path-replace-extension script #".stop") #:exists 'replace)
  (check-true (wait-until 5 (lambda () (eq? (probe3 port "syncpilot" "pw") 'unreachable))))
  (delete-directory/files dir))

(test-case "crash supervisor reports crashed when restart is disabled"
  (define dir (make-temporary-file "syncpilot-mgr-~a" 'directory))
  (define script (write-fake-daemon! (build-path dir "fake-daemon") "ok"))
  (define port (free-port))
  (define m (make-test-manager dir port script #:restart-on-crash #f))
  (record-events! m)
  (run-with-timing (lambda () (ensure-running! m) (start-supervisor! m)))
  (display-to-file "stop" (path-replace-extension script #".stop") #:exists 'replace)
  (check-true
   (wait-until 8
               (lambda ()
                 (eq? (daemon-status-phase (manager-status m)) 'crashed))))
  (check-equal? (daemon-status-error (manager-status m))
                "daemon exited unexpectedly")
  (check-not-false (member 'crashed (unbox events)) "phase change must be published")
  (delete-directory/files dir))
