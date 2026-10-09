#lang racket/base

;; rslsync.conf generator tests: EULA acceptance present, NO api_key ever,
;; loopback Web UI, storage dir created, 0600 permissions.

(require json
         rackunit
         racket/file
         racket/string
         "../syncpilot/conf.rkt"
         "../syncpilot/settings.rkt")

(define tmp (make-temporary-file "syncpilot-conf-test-~a" 'directory))

(define settings
  (app-settings "" 38889 "syncpilot" "topsecret" "test-device"
                #t #t #t #t #f #f #f settings-version-current))

(test-case "build-conf-json has exactly the verified shape"
  (define conf
    (read-json
     (open-input-string
      (jsexpr->string (build-conf-json settings (storage-dir tmp))))))
  ;; rslsync 3.x refuses to start without explicit EULA acceptance.
  (check-equal? (hash-ref conf 'agree_to_EULA) "yes")
  (check-equal? (hash-ref conf 'device_name) "test-device")
  (check-equal? (hash-ref conf 'storage_path) (path->string (storage-dir tmp)))
  (check-equal? (hash-ref conf 'shared_folders) '())
  (define webui (hash-ref conf 'webui))
  (check-equal? (hash-ref webui 'listen) "127.0.0.1:38889")
  (check-equal? (hash-ref webui 'login) "syncpilot")
  (check-equal? (hash-ref webui 'password) "topsecret"))

(test-case "no api_key is ever written"
  (define text (jsexpr->string (build-conf-json settings (storage-dir tmp))))
  (check-false (string-contains? text "api_key")
               "3.x validates Resilio-signed keys and refuses local ones")
  (define conf (read-json (open-input-string text)))
  (check-false (hash-has-key? (hash-ref conf 'webui) 'api_key)))

(test-case "write-conf! creates the storage dir and locks the file down"
  (define path (write-conf! tmp settings))
  (check-true (file-exists? path))
  (check-true (directory-exists? (storage-dir tmp)))
  (define bits (file-or-directory-permissions path 'bits))
  (check-equal? (bitwise-and bits #o777) #o600
                "the conf carries the Web UI password and must be 0600"))

(test-case "write-conf! overwrites stale content (port change)"
  (define path
    (write-conf! tmp (struct-copy app-settings settings [webui-port 40000])))
  (define conf (read-json (open-input-file path)))
  (check-equal? (hash-ref (hash-ref conf 'webui) 'listen) "127.0.0.1:40000"))

(void (delete-directory/files tmp))
