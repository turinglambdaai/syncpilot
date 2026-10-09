#lang racket/base

;; App settings tests: fresh credentials, roundtrip, the v0.2.1 fork
;; regression (the loaded-and-persisted instance must be the one returned),
;; corrupt-file recovery, and the v1 -> v2 migration.

(require json
         rackunit
         racket/file
         racket/string
         "../syncpilot/settings.rkt")

(define (fresh-dir tag)
  (make-temporary-file (string-append "syncpilot-settings-test-~a-" tag) 'directory))

(test-case "defaults carry fresh random credentials"
  (define a (default-settings))
  (define b (default-settings))
  (check-equal? (app-settings-webui-port a) 38889)
  (check-equal? (app-settings-webui-login a) "syncpilot")
  (check-equal? (string-length (app-settings-webui-password a)) 20)
  (check-not-equal? (app-settings-webui-password a)
                    (app-settings-webui-password b)
                    "passwords must be random")
  (check-true (app-settings-autostart-daemon a))
  (check-true (app-settings-restart-on-crash a))
  (check-true (app-settings-keep-daemon-on-exit a))
  (check-true (app-settings-close-to-tray a))
  (check-equal? (app-settings-language a) "system")
  (check-equal? (app-settings-settings-version a) 2))

(test-case "port validation"
  (check-true (valid-port? 1024))
  (check-true (valid-port? 65535))
  (check-false (valid-port? 1023))
  (check-false (valid-port? 65536))
  (check-exn exn:fail? (lambda () (validate-port! 't 80))))

(test-case "language validation"
  (check-true (valid-language? "system"))
  (check-true (valid-language? "zh"))
  (check-true (valid-language? "en"))
  (check-false (valid-language? "fr"))
  (check-false (valid-language? 42))
  (check-exn exn:fail? (lambda () (validate-language! 't "fr"))))

(test-case "first load persists defaults and returns the persisted instance"
  ;; Regression: first load used to persist one random credential set and
  ;; return a second one, forking the app/daemon credentials (v0.2.1).
  (define dir (fresh-dir "first-load"))
  (define returned (load-settings dir))
  (check-true (file-exists? (settings-path dir))
              "first load must persist defaults")
  (define stored (read-json (open-input-file (settings-path dir))))
  (check-equal? (hash-ref stored 'webui_password)
                (app-settings-webui-password returned))
  (check-equal? (hash-ref stored 'webui_login)
                (app-settings-webui-login returned))
  (delete-directory/files dir))

(test-case "settings survive a reload roundtrip"
  (define dir (fresh-dir "roundtrip"))
  (define first (load-settings dir))
  (define edited
    (struct-copy app-settings first
                 [webui-port 40001]
                 [device-name "bench"]
                 [language "en"]))
  (persist-settings! dir edited)
  (define third (load-settings dir))
  (check-equal? (app-settings-webui-port third) 40001)
  (check-equal? (app-settings-device-name third) "bench")
  (check-equal? (app-settings-language third) "en"
                "the language choice must survive reload")
  (check-equal? (app-settings-webui-password third)
                (app-settings-webui-password first)
                "credentials must survive reload")
  (delete-directory/files dir))

(test-case "corrupt file is moved aside and replaced by defaults"
  (define dir (fresh-dir "corrupt"))
  (display-to-file "{not json" (settings-path dir) #:exists 'replace)
  (define s (load-settings dir))
  (check-equal? (app-settings-webui-port s) 38889)
  (check-true (file-exists? (build-path dir "syncpilot-settings.json.bak"))
              "the corrupt file must be preserved as .json.bak")
  (delete-directory/files dir))

(test-case "v1 file migrates to the tray-first defaults exactly once"
  (define dir (fresh-dir "migrate"))
  ;; A pre-0.3.0 file: explicit false values, no version stamp.
  (display-to-file "{\"close_to_tray\": false, \"keep_daemon_on_exit\": false}"
                   (settings-path dir)
                   #:exists 'replace)
  (define s (load-settings dir))
  (check-true (app-settings-close-to-tray s) "v1 installs must pick up hide-to-tray")
  (check-true (app-settings-keep-daemon-on-exit s) "v1 installs must keep the daemon")
  (check-equal? (app-settings-settings-version s) 2)
  (define stored (file->string (settings-path dir)))
  (check-true (string-contains? stored "\"settings_version\":2")
              "migration must be stamped to disk")
  (delete-directory/files dir))

(test-case "current-version files never rewrite explicit opt-outs"
  (define dir (fresh-dir "explicit"))
  (display-to-file
   "{\"settings_version\": 2, \"close_to_tray\": false, \"keep_daemon_on_exit\": false}"
   (settings-path dir)
   #:exists 'replace)
  (define s (load-settings dir))
  (check-false (app-settings-close-to-tray s) "explicit opt-out must survive load")
  (check-false (app-settings-keep-daemon-on-exit s))
  (check-equal? (app-settings-webui-login s) "syncpilot"
                "missing fields fall back per-field")
  (delete-directory/files dir))

(test-case "files from before the language field fall back to system"
  (define dir (fresh-dir "pre-language"))
  (display-to-file
   "{\"settings_version\": 2, \"language\": \"fr\"}"
   (settings-path dir)
   #:exists 'replace)
  (define s (load-settings dir))
  (check-equal? (app-settings-language s) "system"
                "junk language values must fall back, not poison the host")
  (delete-directory/files dir))
