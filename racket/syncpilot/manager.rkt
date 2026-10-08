#lang racket/base

;; Owns the rslsync child process: spawn, adopt an already-running daemon,
;; supervise with crash backoff, and stop gracefully (port of
;; src-tauri/src/manager.rs).
;;
;; Threading notes:
;; - All state lives under one lock (a semaphore); waits and probes happen
;;   OUTSIDE the lock, like the Rust original held the mutex briefly.
;; - The daemon subprocess is spawned under a dedicated custodian (not the
;;   caller's RPC custodian), so a cancelled RPC or a host teardown of one
;;   request can never kill the daemon.
;; - Phase changes are published through the notify callback (set by the
;;   Rivet backend once the event emitter exists; see the backend wiring).
;;   Until then the notify box stays #f and updates are only visible via
;;   manager-status.

(require racket/file
         racket/format
         racket/path
         racket/string
         "action-api.rkt"
         "conf.rkt"
         "settings.rkt")

(provide (struct-out manager)
         (struct-out daemon-status)
         make-manager
         manager-settings
         manager-update-settings!
         manager-status
         manager-client
         manager-port
         set-manager-notify!
         find-binary
         current-well-known-binary-paths
         current-path-env
         ensure-running!
         stop!
         restart!
         start-supervisor!
         port-conflict-error
         binary-not-found-error
         ;; timing knobs (parameters; tests shrink them)
         manager-start-deadline-secs
         manager-poll-secs
         manager-stop-polls
         manager-stop-poll-secs
         manager-supervisor-interval-secs
         manager-restart-backoff-base-secs
         daemon-stderr-log
         manager-restart-backoff-cap-secs)

;; ------------------------------------------------------------ public shapes

;; phase is one of 'stopped 'starting 'running 'crashed 'failed;
;; pid/uptime-secs/binary/error are #f when not applicable.
(struct daemon-status (phase pid uptime-secs binary error autostart) #:transparent)

(struct child (proc pid) #:transparent)

(struct manager
  (app-dir          ; app data dir: holds rslsync.conf + storage/
   settings-box     ; (box app-settings?)
   daemon-cust      ; owns the daemon subprocess
   inner            ; latest state snapshot
   lock             ; guards inner
   notify-box       ; (box (or/c (daemon-status? . -> . any) #f))
   supervisor-box)  ; #f until the watchdog thread exists
  #:transparent
  #:mutable)

(struct inner-data (phase child started-at manual-stop? error binary) #:transparent)

;; -------------------------------------------------------------------- knobs

(define manager-start-deadline-secs (make-parameter 30))
(define manager-poll-secs (make-parameter 0.5))
(define manager-stop-polls (make-parameter 24))
(define manager-stop-poll-secs (make-parameter 0.25))
(define manager-supervisor-interval-secs (make-parameter 1.0))
(define manager-restart-backoff-base-secs (make-parameter 2))
(define manager-restart-backoff-cap-secs (make-parameter 60))

;; ------------------------------------------------------------------ basics

(define (make-manager app-dir settings)
  (manager app-dir
           (box settings)
           (make-custodian)
           (inner-data 'stopped #f #f #f #f #f)
           (make-semaphore 1)
           (box #f)
           (box #f)))

(define (manager-settings m)
  (unbox (manager-settings-box m)))

;; Persist AND publish (the box is the single source of truth).
(define (manager-update-settings! m s)
  (persist-settings! (manager-app-dir m) s)
  (set-box! (manager-settings-box m) s)
  (manager-notify! m)
  s)

(define (manager-port m)
  (app-settings-webui-port (manager-settings m)))

(define (manager-client m)
  (define s (manager-settings m))
  (make-client (app-settings-webui-port s)
               (app-settings-webui-login s)
               (app-settings-webui-password s)))

(define (set-manager-notify! m proc)
  (set-box! (manager-notify-box m) proc)
  (manager-notify! m))

(define (manager-notify! m)
  (define proc (unbox (manager-notify-box m)))
  (when proc
    (with-handlers ([exn:fail? void])
      (proc (manager-status m)))))

(define (update-inner! m f)
  (call-with-semaphore
   (manager-lock m)
   (lambda ()
     (set-manager-inner! m (f (manager-inner m))))))

(define (locked-phase m)
  (call-with-semaphore (manager-lock m)
    (lambda () (inner-data-phase (manager-inner m)))))

(define (manager-status m)
  (define s (manager-settings m))
  (define i
    (call-with-semaphore (manager-lock m)
      (lambda () (manager-inner m))))
  (daemon-status
   (inner-data-phase i)
   (and (inner-data-child i) (child-pid (inner-data-child i)))
   (and (inner-data-started-at i)
        (inexact->exact
         (floor (/ (- (current-inexact-milliseconds) (inner-data-started-at i))
                   1000))))
   (inner-data-binary i)
   (inner-data-error i)
   (app-settings-autostart-daemon s)))

;; ------------------------------------------------------------- error texts

;; Shared with the backend so hosts can match known error patterns (the old
;; UI matched /binary not found/i to offer the download card).
(define (binary-not-found-error)
  "rslsync binary not found. Install Resilio Sync or set its path in Settings.")

(define (port-conflict-error port)
  (format
   "Port ~a is used by another Resilio Sync daemon with different credentials — often a leftover system service. Quit that daemon, or change SyncPilot's port under tray → SyncPilot Settings…, then retry."
   port))

;; ------------------------------------------------------------ binary lookup

;; The well-known install locations probed between the explicit setting and
;; $PATH. A parameter so tests can run on machines that really do have a
;; rslsync installed (the manager must not see it unless it put it there).
(define current-well-known-binary-paths
  (make-parameter
   (list (build-path (find-system-path 'home-dir) ".local" "bin" "rslsync")
         (string->path "/usr/bin/rslsync")
         (string->path "/usr/local/bin/rslsync")
         (string->path "/opt/resilio-sync/rslsync"))))

;; The PATH string probed after the well-known locations; parameterized for
;; the same reason.
(define current-path-env (make-parameter (getenv "PATH")))

;; Find the rslsync binary: explicit setting, our own install location,
;; well-known paths, then $PATH. ~/.local/bin (where the first-run installer
;; targets) is checked explicitly: desktop-launched apps often run with a
;; session PATH that does not include it.
(define (find-binary m)
  (define explicit (string-trim (app-settings-rslsync-path (manager-settings m))))
  (define candidates
    (append
     (if (string=? explicit "") '() (list (string->path explicit)))
     (current-well-known-binary-paths)
     (let ([path-env (current-path-env)])
       (if (and path-env (not (string=? path-env "")))
           (for/list ([dir (in-list (string-split path-env ":"))]
                      #:when (not (string=? dir "")))
             (build-path (string->path dir) "rslsync"))
           '()))))
  (findf executable-file? candidates))

(define (executable-file? p)
  (and (file-exists? p)
       (memq 'execute (file-or-directory-permissions p))))

;; ------------------------------------------------------------ daemon phases

;; Make sure a daemon answers on our port AND accepts our credentials.
;; Adopts a compatible already-running daemon (e.g. kept from a previous
;; session with keep_daemon_on_exit). A foreign daemon on the port is an
;; explicit error, never adopted: we could not drive it, and it may run as a
;; different user without the user's file permissions. Raises on failure.
(define (ensure-running! m)
  (unless (eq? (locked-phase m) 'running)
    (define probe
      (with-handlers ([exn:fail? (lambda (_) 'unreachable)])
        (probe-port (manager-client m))))
    (case probe
      [(compatible)
       (update-inner! m
                      (lambda (i)
                        (struct-copy inner-data i
                                     [phase 'running]
                                     [manual-stop? #f]
                                     [error #f])))
       (manager-notify! m)]
      [(foreign)
       (fail! m (port-conflict-error (manager-port m)))]
      [(unreachable) (spawn-and-wait! m)]))
  (void))

(define (fail! m message)
  (update-inner! m
                 (lambda (i)
                   (struct-copy inner-data i
                                [phase 'failed]
                                [error message])))
  (manager-notify! m)
  (error 'manager message))

(define (spawn-and-wait! m)
  (define binary
    (or (find-binary m)
        (fail! m (binary-not-found-error))))
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (fail! m (~a "cannot write rslsync.conf: " (exn-message e))))])
    (write-conf! (manager-app-dir m) (manager-settings m)))
  (update-inner! m
                 (lambda (i)
                   (struct-copy inner-data i
                                [phase 'starting]
                                [error #f]
                                [manual-stop? #f])))
  (manager-notify! m)

  (define conf (conf-path (manager-app-dir m)))
  (define child
    (with-handlers ([exn:fail?
                     (lambda (e)
                       (fail! m (~a "failed to launch " (path->string binary)
                                    ": " (exn-message e))))])
      (spawn-child! m binary conf)))
  (update-inner! m
                 (lambda (i)
                   (struct-copy inner-data i
                                [child child]
                                [binary (path->string binary)]
                                [started-at (current-inexact-milliseconds)])))
  (manager-notify! m)

  ;; Poll until the daemon answers, something else takes the port, the
  ;; child dies, or the deadline passes.
  (define deadline-ms
    (+ (current-inexact-milliseconds) (* 1000 (manager-start-deadline-secs))))
  (let wait ()
    (define probe (probe-safe m))
    (cond
      [(eq? probe 'compatible)
       (update-inner! m (lambda (i) (struct-copy inner-data i [phase 'running])))
       (manager-notify! m)]
      [(eq? probe 'foreign)
       (fail! m (port-conflict-error (manager-port m)))]
      [(child-exit-code child)
       => (lambda (code)
            (fail! m (~a "rslsync exited with code " code)))]
      [(> (current-inexact-milliseconds) deadline-ms)
       (fail! m (~a "daemon did not answer within "
                    (manager-start-deadline-secs) "s"))]
      [else
       (sleep (manager-poll-secs))
       (wait)])))

(define (probe-safe m)
  (with-handlers ([exn:fail? (lambda (_) 'unreachable)])
    (probe-port (manager-client m))))

;; Test seam: when set to a path, the daemon's stderr is captured there
;; instead of being discarded. Production code never sets it.
(define daemon-stderr-log (make-parameter #f))

(define (spawn-child! m binary conf)
  (define stderr-file
    (and (daemon-stderr-log)
         (open-output-file (daemon-stderr-log) #:exists 'append)))
  (define-values (proc so si se)
    ;; Dedicated custodian: request cancellation / RPC custodians must never
    ;; kill the daemon. stdout/stderr are discarded (parity: Stdio::null).
    (parameterize ([current-custodian (manager-daemon-cust m)])
      (subprocess #f #f stderr-file
                  (path->string binary)
                  "--nodaemon" "--config" (path->string conf))))
  (when stderr-file (close-output-port stderr-file))
  (with-handlers ([exn:fail? void])
    (close-output-port si)
    (close-input-port so)
    (close-input-port se))
  (child proc (subprocess-pid proc)))

;; subprocess-status yields 'running while alive, else the integer exit code.
(define (child-exit-code child)
  (define status (subprocess-status (child-proc child)))
  (if (eq? status 'running) #f status))

(define (child-dead? child)
  (and child
       (not (eq? (subprocess-status (child-proc child)) 'running))))

;; Stop the daemon gracefully (API shutdown, then kill). With
;; keep_daemon_on_exit the child is detached instead and left running.
(define (stop! m)
  (define keep
    (app-settings-keep-daemon-on-exit (manager-settings m)))
  (update-inner! m (lambda (i) (struct-copy inner-data i [manual-stop? #t])))
  (cond
    [keep
     ;; Detach: drop the handle and forget the daemon (it keeps running).
     (update-inner! m
                    (lambda (i)
                      (struct-copy inner-data i
                                   [child #f]
                                   [phase 'stopped]
                                   [started-at #f])))
     (manager-notify! m)]
    [else
     ;; Best-effort graceful shutdown through the API ...
     (with-handlers ([exn:fail? void])
       (shutdown! (manager-client m)))
     ;; ... then wait for the child to exit (24 x 250 ms) ...
     (let loop ([n 0])
       (define child
         (call-with-semaphore (manager-lock m)
           (lambda () (inner-data-child (manager-inner m)))))
       (cond
         [(or (not child) (child-dead? child)) (void)]
         [(< n (manager-stop-polls))
          (sleep (manager-stop-poll-secs))
          (loop (add1 n))]
         [else
          ;; ... and kill as a last resort.
          (with-handlers ([exn:fail? void])
            (subprocess-kill (child-proc child) #t)
            (subprocess-wait (child-proc child)))]))
     (update-inner! m
                    (lambda (i)
                      (struct-copy inner-data i
                                   [child #f]
                                   [phase 'stopped]
                                   [started-at #f])))
     (manager-notify! m)])
  (void))

(define (restart! m)
  (stop! m)
  (ensure-running! m))

;; ------------------------------------------------------------ crash watchdog

;; Idempotently start the background watchdog: restart the daemon with
;; exponential backoff after a crash (2s → x2 → cap 60s), or flip to the
;; 'crashed phase when restart_on_crash is off.
(define (start-supervisor! m)
  (unless (unbox (manager-supervisor-box m))
    (set-box! (manager-supervisor-box m) #t)
    (thread
     (lambda ()
       (let loop ([backoff-secs (manager-restart-backoff-base-secs)])
         (sleep (manager-supervisor-interval-secs))
         (define crash?
           (call-with-semaphore (manager-lock m)
             (lambda ()
               (define i (manager-inner m))
               (and (eq? (inner-data-phase i) 'running)
                    (not (inner-data-manual-stop? i))
                    (inner-data-child i)
                    (child-dead? (inner-data-child i))))))
         (cond
           [(not crash?) (loop backoff-secs)]
           [else
            (define restart?
              (app-settings-restart-on-crash (manager-settings m)))
            (cond
              [restart?
               (sleep backoff-secs)
               ;; Re-check after the backoff sleep: a stop! may have landed
               ;; in the meantime.
               (define still-crashed?
                 (call-with-semaphore (manager-lock m)
                   (lambda ()
                     (define i (manager-inner m))
                     (and (eq? (inner-data-phase i) 'running)
                          (not (inner-data-manual-stop? i))))))
               (when still-crashed?
                 ;; Reap the dead child and clear the phase so
                 ;; ensure-running! does not bail on a stale running state.
                 (update-inner! m
                                (lambda (i)
                                  (struct-copy inner-data i
                                               [child #f]
                                               [phase 'stopped])))
                 (with-handlers ([exn:fail? void])
                   (ensure-running! m)))
               (loop (min (* backoff-secs 2)
                          (manager-restart-backoff-cap-secs)))]
              [else
               (update-inner! m
                              (lambda (i)
                                (struct-copy inner-data i
                                             [phase 'crashed]
                                             [error "daemon exited unexpectedly"])))
               (manager-notify! m)
               (loop backoff-secs)])])))))
  (void))
