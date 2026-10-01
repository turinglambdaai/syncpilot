#lang racket/base

;; Generation of the `rslsync.conf` handed to the managed daemon (port of
;; src-tauri/src/rslsync_config.rs). The file keeps the Web UI on loopback
;; with app-generated credentials so the backend can drive the action API
;; without prompting the user. Facts from docs/api-verified.md:
;;
;; - `agree_to_EULA: "yes"` is mandatory — 3.x exits immediately without it.
;; - NEVER write `webui.api_key`: the 3.x binary validates it against
;;   Resilio-issued signed keys and refuses to start on a local one.

(require json
         racket/file
         racket/format
         "settings.rkt")

(provide conf-path
         storage-dir
         build-conf-json
         write-conf!)

(define (conf-path app-dir)
  (build-path app-dir "rslsync.conf"))

(define (storage-dir app-dir)
  (build-path app-dir "storage"))

;; The JSON body of the conf file. `storage-path` must be an existing
;; directory by the time the daemon starts; write-conf! creates it.
(define (build-conf-json settings storage-path)
  (hasheq 'device_name (app-settings-device-name settings)
          'storage_path (path->string storage-path)
          ;; rslsync 3.x refuses to start without explicit EULA acceptance.
          'agree_to_EULA "yes"
          'webui
          (hasheq 'listen (~a "127.0.0.1:" (app-settings-webui-port settings))
                  'login (app-settings-webui-login settings)
                  'password (app-settings-webui-password settings))
          'shared_folders '()))

;; Write the config with restrictive permissions (secrets inside). Runs
;; before every daemon spawn, so credential or port changes are always
;; reflected in the file the daemon reads.
(define (write-conf! app-dir settings)
  (define storage (storage-dir app-dir))
  (make-directory* storage)
  (define path (conf-path app-dir))
  (display-to-file (jsexpr->string (build-conf-json settings storage))
                   path
                   #:mode 'text
                   #:exists 'replace)
  ;; Strict on purpose: a world-readable conf would leak the Web UI password,
  ;; and the Rust original merely skipped the chmod silently.
  (file-or-directory-permissions path #o600)
  path)
