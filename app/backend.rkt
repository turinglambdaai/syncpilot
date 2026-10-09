#lang racket/base

;; SyncPilot Rivet backend: the typed RPC surface hosts drive. Business
;; logic lives in racket/syncpilot/*; this module only wires the domain core
;; (manager, action client, proxy, installer) to the protocol.
;;
;; The `init` RPC is the lifecycle anchor: Rivet threads spawned at module
;; top level have no event emitter, so the supervisor and proxy threads are
;; started lazily from inside init (their event emitter is inherited from
;; the request thread). Hosts call init first, before any other RPC.

(require rivet/backend
         racket/format
         racket/path
         racket/string
         "../racket/syncpilot/action-api.rkt"
         "../racket/syncpilot/install.rkt"
         "../racket/syncpilot/manager.rkt"
         "../racket/syncpilot/proxy.rkt"
         "../racket/syncpilot/settings.rkt"
         "../racket/syncpilot/updater.rkt"
         "../racket/syncpilot/version.rkt")

(provide start
         ;; test seam: point the data dir at a temp directory before serving
         current-data-dir)

;; -------------------------------------------------------------- API shapes

(define-enum DaemonPhase (stopped starting running crashed failed))
(define-enum PortProbe (compatible foreign unreachable))

(define-record DaemonStatus
  ([phase : DaemonPhase]
   [pid : (Optional Int64)]
   [uptime-secs : (Optional Int64)]
   [binary : (Optional String)]
   [error : (Optional String)]
   [autostart : Bool]))

;; Host-visible settings. The Web UI password is intentionally NOT exposed
;; (the old app never showed it either); hosts see has-password and can
;; regenerate the credential instead.
(define-record Settings
  ([rslsync-path : String]
   [webui-port : Int64]
   [webui-login : String]
   [has-password : Bool]
   [device-name : String]
   [autostart : Bool]
   [restart-on-crash : Bool]
   [keep-daemon-on-exit : Bool]
   [close-to-tray : Bool]
   [settings-version : Int64]))

(define-record SettingsDraft
  ([rslsync-path : String]
   [webui-port : Int64]
   [webui-login : String]
   [device-name : String]
   [autostart : Bool]
   [restart-on-crash : Bool]
   [keep-daemon-on-exit : Bool]
   [close-to-tray : Bool]))

;; Boot page handoff: where to load the official UI and what came up.
(define-record Handoff
  ([proxy-url : String]
   [daemon-version : (Optional String)]
   [phase : DaemonPhase]))

(define-record InstallResult
  ([ok : Bool]
   [path : (Optional String)]
   [error : (Optional String)]))

;; One getchartdata sample per direction, in bytes/sec.
(define-record Speeds
  ([down-bytes : Int64]
   [up-bytes : Int64]))

(define-record TrialResult
  ([ok : Bool]
   [error : (Optional String)]))

;; Result of a manual or silent update check. status: "available" |
;; "up-to-date" | "throttled" | "error"; the descriptive fields are only
;; filled for "available".
(define-record UpdateCheck
  ([status : String]
   [error : (Optional String)]
   [current-version : String]
   [available-version : (Optional String)]
   [build : (Optional Int64)]
   [published-at : (Optional String)]
   [installer : (Optional String)]
   [size-bytes : (Optional Int64)]))

;; Polled by the host while a download runs. phase: idle | checking |
;; downloading | downloaded | error.
(define-record UpdateState
  ([phase : String]
   [percent : Int64]
   [message : (Optional String)]
   [downloaded-path : (Optional String)]
   [available-version : (Optional String)]))

(define-event daemon-changed : DaemonStatus)
(define-state status : DaemonStatus
  (DaemonStatus (DaemonPhase 'stopped) (void) (void) (void) (void) #f))

;; ------------------------------------------------------------ runtime cells

;; Tests parameterize this so the real home directory is never touched.
(define current-data-dir (make-parameter #f))

(define runtime
  (box #f)) ; (cons manager proxy-handle) once init ran

(define (require-runtime who)
  (or (unbox runtime)
      (error who "backend is not initialized; call init first")))

(define (publish-status! st)
  (state-set! status st)
  (daemon-changed st))

(define (status->record s)
  (define phase (daemon-status-phase s))
  (DaemonStatus
   (DaemonPhase phase)
   (nullable (daemon-status-pid s))
   (nullable (daemon-status-uptime-secs s))
   (nullable (daemon-status-binary s))
   (nullable (daemon-status-error s))
   (daemon-status-autostart s)))

(define (nullable v) (if v v (void)))

(define (settings->record s)
  (Settings
   (app-settings-rslsync-path s)
   (app-settings-webui-port s)
   (app-settings-webui-login s)
   (not (string=? (app-settings-webui-password s) ""))
   (app-settings-device-name s)
   (app-settings-autostart-daemon s)
   (app-settings-restart-on-crash s)
   (app-settings-keep-daemon-on-exit s)
   (app-settings-close-to-tray s)
   (app-settings-settings-version s)))

(define (trim-or-empty v)
  (string-trim (if (string? v) v "")))

;; -------------------------------------------------------------------- init


;; The proxy binds an OS-assigned ephemeral port at init time. If a later
;; settings save moves the daemon's Web UI port onto exactly that port, the
;; daemon could never bind it — rebind the proxy (a fresh ephemeral port,
;; excluding the Web UI port) and return the new handle.
(define (ensure-proxy-port! proxy webui-port)
  (if (= (proxy-handle-port proxy) webui-port)
      (let ([config (unbox (proxy-handle-config-box proxy))])
        (stop-proxy! proxy)
        (define fresh
          (start-proxy!
           (proxy-config (proxy-config-daemon-port config)
                         (proxy-config-login config)
                         (proxy-config-password config))
           #:exclude-port webui-port))
        fresh)
      proxy))

(define-rpc (initialize : Void)
  (unless (unbox runtime)
    (define dir (or (current-data-dir) (default-data-dir)))
    (define settings (load-settings dir))
    (define mgr (make-manager dir settings))
    ;; The notify callback runs on manager threads; it inherits the request
    ;; thread's event emitter, so State + Event both stay observable.
    (set-manager-notify! mgr (lambda (s) (publish-status! (status->record s))))
    ;; Proxy for the official Web UI (auth injected, ephemeral port).
    (define proxy
      (start-proxy!
       (proxy-config (app-settings-webui-port settings)
                     (app-settings-webui-login settings)
                     (app-settings-webui-password settings))
       ;; the daemon binds this port later; the proxy must never take it
       #:exclude-port (app-settings-webui-port settings)))
    (set-box! runtime (cons mgr proxy))
    (publish-status! (status->record (manager-status mgr)))
    (start-supervisor! mgr)
    (when (app-settings-autostart-daemon settings)
      ;; Bring the daemon up in the background: init must return quickly
      ;; (the boot page follows up via get-handoff / daemon-changed).
      (thread
       (lambda ()
         (with-handlers ([exn:fail? void])
           (ensure-running! mgr))))))
  (void))

(define-rpc (get-handoff : Handoff)
  (define rt (require-runtime 'get-handoff))
  (define mgr (car rt))
  (define proxy (cdr rt))
  (ensure-running! mgr)
  (define version
    (with-handlers ([exn:fail? (lambda (_) #f)])
      (version! (manager-client mgr))))
  (Handoff (~a (proxy-handle-base-url proxy) "/gui/")
           (nullable version)
           (DaemonPhase (daemon-status-phase (manager-status mgr)))))

;; ----------------------------------------------------------------- daemon

(define-rpc (daemon-start : DaemonStatus)
  (define mgr (car (require-runtime 'daemon-start)))
  (ensure-running! mgr)
  (status->record (manager-status mgr)))

(define-rpc (daemon-stop : DaemonStatus)
  (define mgr (car (require-runtime 'daemon-stop)))
  (stop! mgr)
  (status->record (manager-status mgr)))

(define-rpc (daemon-restart : DaemonStatus)
  (define mgr (car (require-runtime 'daemon-restart)))
  (restart! mgr)
  (status->record (manager-status mgr)))

(define-rpc (probe-port : PortProbe)
  (define mgr (car (require-runtime 'probe-port)))
  (define probe
    (with-handlers ([exn:fail? (lambda (_) 'unreachable)])
      (probe-port (manager-client mgr))))
  (PortProbe probe))

;; First-run install of the official binary. Never raises: the host gets a
;; structured result to render. On success the daemon is brought up right
;; away with the fresh binary (parity with the old install_rslsync command).
(define-rpc (install-rslsync : InstallResult)
  (define rt (require-runtime 'install-rslsync))
  (define mgr (car rt))
  (with-handlers
      ([exn:fail?
        (lambda (e)
          (InstallResult #f (void) (exn-message e)))])
    (define path (install-official-binary!))
    (ensure-running! mgr)
    (InstallResult #t (path->string path) (void))))

;; ---------------------------------------------------------------- settings

(define-rpc (get-settings : Settings)
  (settings->record (manager-settings (car (require-runtime 'get-settings)))))

(define-rpc (save-settings [draft SettingsDraft] : Settings)
  (define rt (require-runtime 'save-settings))
  (define mgr (car rt))
  (define proxy (cdr rt))
  (define current (manager-settings mgr))
  (define port (validate-port! 'save-settings (record-ref draft 'webui-port)))
  (define updated
    (struct-copy app-settings current
                 [rslsync-path (trim-or-empty (record-ref draft 'rslsync-path))]
                 [webui-port port]
                 [webui-login (trim-or-empty (record-ref draft 'webui-login))]
                 [device-name (trim-or-empty (record-ref draft 'device-name))]
                 [autostart-daemon (record-ref draft 'autostart)]
                 [restart-on-crash (record-ref draft 'restart-on-crash)]
                 [keep-daemon-on-exit (record-ref draft 'keep-daemon-on-exit)]
                 [close-to-tray (record-ref draft 'close-to-tray)]))
  ;; Persist via the manager (single source of truth), then keep the
  ;; auth-injecting proxy in sync with the new credentials/port.
  (manager-update-settings! mgr updated)
  (define new-proxy
    (ensure-proxy-port! proxy (app-settings-webui-port updated)))
  (when new-proxy
    ;; the proxy's listener landed on the new Web UI port (it bound an
    ;; ephemeral port before this save); rebind it away
    (set-box! runtime (cons mgr new-proxy)))
  (settings->record updated))

;; The old app never shows the password; hosts offer a regenerate button
;; instead. The new credential takes effect on the next daemon spawn (the
;; conf is rewritten before every start).
(define-rpc (regenerate-password : Settings)
  (define rt (require-runtime 'regenerate-password))
  (define mgr (car rt))
  (define updated
    (struct-copy app-settings (manager-settings mgr)
                 [webui-password (random-token 20)]))
  (manager-update-settings! mgr updated)
  (set-proxy-config!
   (cdr rt)
   (proxy-config (app-settings-webui-port updated)
                 (app-settings-webui-login updated)
                 (app-settings-webui-password updated)))
  (settings->record updated))

;; --------------------------------------------------------------- live data

(define-rpc (get-speeds : Speeds)
  (define client (manager-client (car (require-runtime 'get-speeds))))
  (define speeds (get-speeds! client))
  (Speeds (car speeds) (cdr speeds)))

(define-rpc (open-trial : TrialResult)
  (define client (manager-client (car (require-runtime 'open-trial))))
  (with-handlers ([exn:fail? (lambda (e) (TrialResult #f (exn-message e)))])
    (start-trial-period! client)
    (TrialResult #t (void))))

;; ------------------------------------------------------------ online updates

;; The updater commits settings through the manager: it stays the single
;; source of truth, so last-update-check-at / rollout-bucket land on disk
;; and in every later reader.
(define (settings-commit! mgr)
  (lambda (s) (manager-update-settings! mgr s) (void)))

(define (update-check->record result)
  (define (opt key) (nullable (hash-ref result key #f)))
  (UpdateCheck
   (hash-ref result 'status "error")
   (opt 'message)
   (hash-ref result 'currentVersion app-version)
   (opt 'availableVersion)
   (opt 'build)
   (opt 'publishedAt)
   (opt 'installer)
   (opt 'sizeBytes)))

;; The silent startup auto-check is throttled here (not in the updater): a
;; check younger than a day returns "throttled" instead of hitting the
;; network, so relaunches stay offline-cheap.
(define auto-check-interval-seconds (* 24 60 60))

(define-rpc (check-updates [force Bool] : UpdateCheck)
  (define mgr (car (require-runtime 'check-updates)))
  (define settings (manager-settings mgr))
  (define last (app-settings-last-update-check-at settings))
  (define throttled
    (and (not force)
         (exact-integer? last)
         (< (- (current-seconds) last) auto-check-interval-seconds)))
  (if throttled
      (UpdateCheck "throttled" (void) app-version (void) (void) (void) (void) (void))
      (update-check->record
       (perform-check! settings (settings-commit! mgr)))))

;; Runs on a backend worker thread; the host follows progress via
;; update-state. Never raises: failures surface through the state's phase.
(define-rpc (start-download : Void)
  (define mgr (car (require-runtime 'start-download)))
  (start-download! (manager-settings mgr)
                   (settings-commit! mgr)
                   (or (current-data-dir) (default-data-dir)))
  (void))

(define-rpc (update-state : UpdateState)
  (define s (update-state-snapshot))
  (UpdateState
   (hash-ref s 'phase "idle")
   (hash-ref s 'percent 0)
   (nullable (hash-ref s 'message #f))
   (nullable (hash-ref s 'downloadedPath #f))
   (nullable (hash-ref s 'availableVersion #f))))

;; ------------------------------------------------------------------- entry

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
