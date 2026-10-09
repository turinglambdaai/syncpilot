#lang racket/base

;; Application-side settings (distinct from the generated rslsync.conf).
;; Port of src-tauri/src/settings.rs. Stored as JSON under the app data dir;
;; secrets are generated once on first launch and never leave this machine.
;;
;; JSON field names match the old Rust serde names (snake_case) so the file
;; is a drop-in for existing installs.

(require json
         racket/file
         racket/format
         racket/path
         racket/random
         racket/string)

(provide (struct-out app-settings)
         default-settings
         settings-version-current
         settings-path
         load-settings
         persist-settings!
         random-token
         default-device-name
         default-data-dir
         valid-port?
         validate-port!
         valid-language?
         validate-language!)

(struct app-settings
  (rslsync-path          ; explicit binary path; "" means auto-detect
   webui-port            ; loopback Web UI / API port, 1024..=65535
   webui-login
   webui-password        ; never exposed over RPC (see app/backend.rkt)
   device-name
   autostart-daemon
   restart-on-crash
   keep-daemon-on-exit
   close-to-tray
   language              ; UI language: "system" | "zh" | "en"; "system" is
                         ; resolved by the host at startup, because the boot
                         ; page and tray render before get-settings answers
   update-base-url       ; optional updater override; #f = family default
   last-update-check-at  ; epoch seconds of the last completed check, #f = never
   rollout-bucket        ; sticky 0..99 staged-rollout assignment, #f = unassigned
   settings-version)     ; schema version of the persisted file
  #:transparent)

(define settings-version-current 2)

(define (default-settings)
  (app-settings
   ""
   38889
   "syncpilot"
   (random-token 20)
   (default-device-name)
   #t ; autostart-daemon: start rslsync together with the app
   #t ; restart-on-crash
   ;; Sync clients are expected to keep working with their window closed:
   ;; the official clients hide to the tray and the daemon syncs regardless
   ;; of any UI. Quit stays explicit, via the tray menu.
   #t ; keep-daemon-on-exit
   #t ; close-to-tray
   "system" ; language: follow the session locale until the user picks one
   #f ; update-base-url (updater uses the embedded default)
   #f ; last-update-check-at
   #f ; rollout-bucket
   settings-version-current))

(define (settings-path dir)
  (build-path dir "syncpilot-settings.json"))

(define (random-token len)
  (define alphabet
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
  (list->string
   (for/list ([b (in-bytes (crypto-random-bytes len))])
     (string-ref alphabet (modulo b (string-length alphabet))))))

(define (default-device-name)
  (or (let ([hostname "/etc/hostname"])
        (and (file-exists? hostname)
             (let ([name (string-trim (file->string hostname))])
               (and (not (string=? name "")) name))))
      (let ([env (getenv "COMPUTERNAME")])
        (and env (not (string=? env "")) env))
      "syncpilot-device"))

;; App data dir: contract path is ~/.local/share/site.jrtx.syncpilot on
;; Linux; other platforms get their conventional base so dev runs and tests
;; stay out of Linux's way. Tests pass their own directory explicitly.
(define (default-data-dir)
  (define home (find-system-path 'home-dir))
  (build-path
   (case (system-type 'os)
     [(unix) (let ([xdg (getenv "XDG_DATA_HOME")])
               (if (and xdg (not (string=? xdg "")))
                   (string->path xdg)
                   (build-path home ".local" "share")))]
     [(macosx) (build-path home "Library" "Application Support")]
     [else (build-path home "AppData" "Roaming")])
   "site.jrtx.syncpilot"))

;; --------------------------------------------------------------- persistence

(define (settings->jsexpr s)
  (hasheq 'rslsync_path (app-settings-rslsync-path s)
          'webui_port (app-settings-webui-port s)
          'webui_login (app-settings-webui-login s)
          'webui_password (app-settings-webui-password s)
          'device_name (app-settings-device-name s)
          'autostart_daemon (app-settings-autostart-daemon s)
          'restart_on_crash (app-settings-restart-on-crash s)
          'keep_daemon_on_exit (app-settings-keep-daemon-on-exit s)
          'close_to_tray (app-settings-close-to-tray s)
          'language (app-settings-language s)
          'update_base_url (app-settings-update-base-url s)
          'last_update_check_at (app-settings-last-update-check-at s)
          'rollout_bucket (app-settings-rollout-bucket s)
          'settings_version (app-settings-settings-version s)))

;; JSON null (and wrong-typed junk) falls back to the field default, so an
;; old or hand-edited file keeps loading — same serde(default) semantics as
;; the pre-existing fields.
(define (present ref name fallback ok?)
  (define v (ref name fallback))
  (if (ok? v) v fallback))

(define (jsexpr->settings v)
  (define base (default-settings))
  (define (ref name fallback)
    (cond
      [(not (hash? v)) fallback]
      [(hash-has-key? v name) (hash-ref v name)]
      [else fallback]))
  ;; serde(default) semantics: every missing field falls back independently.
  (app-settings
   (ref 'rslsync_path (app-settings-rslsync-path base))
   (ref 'webui_port (app-settings-webui-port base))
   (ref 'webui_login (app-settings-webui-login base))
   (ref 'webui_password (app-settings-webui-password base))
   (ref 'device_name (app-settings-device-name base))
   (ref 'autostart_daemon (app-settings-autostart-daemon base))
   (ref 'restart_on_crash (app-settings-restart-on-crash base))
   (ref 'keep_daemon_on_exit (app-settings-keep-daemon-on-exit base))
   (ref 'close_to_tray (app-settings-close-to-tray base))
   (present ref 'language (app-settings-language base) valid-language?)
   (present ref 'update_base_url #f
            (lambda (v) (or (not v) (string? v))))
   (present ref 'last_update_check_at #f exact-integer?)
   (present ref 'rollout_bucket #f
            (lambda (v) (and (exact-integer? v) (<= 0 v 99))))
   ;; A file without the stamp predates versioning (everything up to and
   ;; including 0.2.x) and must enter migrate; the container default would
   ;; fill the current version and skip it.
   (ref 'settings_version 1)))

(define (persist-settings! dir s)
  (make-directory* dir)
  (display-to-file (jsexpr->string (settings->jsexpr s))
                   (settings-path dir)
                   #:exists 'replace)
  s)

;; Bring a settings file written by an older version up to date. Runs at most
;; once per version bump: load stamps the current version right after, so
;; choices the user makes afterwards always win.
(define (migrate s)
  ;; v1 shipped both flags as false; adopt the tray-first behavior wholesale
  ;; rather than leaving upgraded installs looking unchanged.
  (if (< (app-settings-settings-version s) 2)
      (struct-copy app-settings s
                   [close-to-tray #t]
                   [keep-daemon-on-exit #t]
                   [settings-version settings-version-current])
      (struct-copy app-settings s
                   [settings-version settings-version-current])))

;; Load settings, creating defaults (with fresh credentials) on first run.
;; A corrupt file is moved aside rather than failing the app.
;;
;; The freshly generated instance is both persisted AND returned — returning
;; a second `default-settings` would silently fork the credentials: the file
;; keeps one random password while the app (and the conf it writes for the
;; daemon) uses another, and the two can never talk (the v0.2.1 bug).
(define (load-settings dir)
  (define path (settings-path dir))
  (define (fresh) (persist-settings! dir (default-settings)))
  (cond
    [(not (file-exists? path)) (fresh)]
    [else
     (define v
       (with-handlers ([exn:fail? (lambda (_) 'corrupt)])
         (read-json (open-input-file path))))
     (cond
       [(eq? v 'corrupt)
        ;; rename "syncpilot-settings.json" -> "syncpilot-settings.json.bak"
        (with-handlers ([exn:fail? void])
          (rename-file-or-directory path
                                    (path-replace-extension path ".json.bak")
                                    #f))
        (fresh)]
       [(not (hash? v)) (fresh)]
       [else
        (define s (jsexpr->settings v))
        (if (< (app-settings-settings-version s) settings-version-current)
            (persist-settings! dir (migrate s))
            s)])]))

;; ---------------------------------------------------------------- validation

(define (valid-port? port)
  (and (exact-integer? port) (<= 1024 port 65535)))

(define (validate-port! who port)
  (unless (valid-port? port)
    (raise-arguments-error who "port must be in 1024..=65535" "port" port))
  port)

(define (valid-language? language)
  (and (string? language)
       (member language '("system" "zh" "en"))
       #t))

(define (validate-language! who language)
  (unless (valid-language? language)
    (raise-arguments-error who
                           "language must be one of system/zh/en"
                           "language"
                           language))
  language)
