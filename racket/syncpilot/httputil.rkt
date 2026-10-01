#lang racket/base

;; Tiny HTTP/1.1 client helpers shared by the rslsync action API, the CDN
;; installer, and the auth-injecting reverse proxy.
;;
;; Why raw TCP instead of net/url: the reverse proxy must rewrite headers on
;; a pass-through connection, and the action client needs a shared cookie jar
;; (the CSRF token is bound to the HTTP session). Both are awkward through a
;; general-purpose HTTP library, while the protocol subset the daemon speaks
;; is small and fully covered here.
;;
;; Simplification (v1): every request is sent with `Connection: close` and
;; responses are buffered in memory (bounded by `max-http-body-bytes`).
;; Response bodies arrive via Content-Length, chunked transfer coding, or
;; read-to-EOF when neither is declared.

(require ffi/unsafe
         net/base64
         net/uri-codec
         racket/format
         racket/port
         racket/string
         racket/tcp)

(provide epoch-ms
         basic-auth-value
         encode-query
         (struct-out cookie-jar)
         make-cookie-jar
         cookie-jar-store!
         cookie-jar-header
         (struct-out http-response)
         header-value
         header-values
         read-head
         read-exact-bytes
         read-chunked
         http-call
         read-http-response
         with-deadline
         sha256-hex
         sha256-pure
         bytes->hex-string
         max-http-body-bytes)

;; ---------------------------------------------------------------- utilities

;; Milliseconds since the Unix epoch, used only as a cache-busting `t` query
;; parameter. The sub-second part comes from the machine clock, which is fine
;; for a cache buster (parity with the old client's millis_now()).
(define (epoch-ms)
  (+ (* 1000 (current-seconds))
     (modulo (inexact->exact (truncate (current-inexact-milliseconds))) 1000)))

;; Value of an `Authorization` header with HTTP basic credentials.
(define (basic-auth-value login password)
  (string-append
   "Basic "
   (bytes->string/latin-1
    (base64-encode (string->bytes/latin-1 (string-append login ":" password)) #""))))

;; Encode an alist of (name . value) pairs as a URL query string (no '?').
(define (encode-query params)
  (string-join
   (for/list ([pair (in-list params)])
     (string-append (uri-encode (car pair)) "=" (uri-encode (cdr pair))))
   "&"))

;; ---------------------------------------------------------------- cookie jar

;; Minimal cookie store: name -> value, no domain/path accounting. rslsync
;; talks to a single loopback origin, so the simple shape is sufficient.
(struct cookie-jar (table lock) #:transparent)

(define (make-cookie-jar)
  (cookie-jar (make-hasheq) (make-semaphore 1)))

;; Store one `Set-Cookie` header value. Only the first name=value pair is
;; kept; attributes (Path, Expires, ...) are ignored.
(define (cookie-jar-store! jar value)
  (define first (car (string-split value ";" #:trim? #t)))
  (when (string-contains? first "=")
    (define kv (string-split first "=" #:trim? #t))
    (when (>= (length kv) 2)
      (call-with-semaphore
       (cookie-jar-lock jar)
       (lambda ()
         (hash-set! (cookie-jar-table jar)
                    (string->symbol (car kv))
                    (string-join (cdr kv) "=")))))))

;; Serialized cookie header value, or #f when the jar is empty.
(define (cookie-jar-header jar)
  (define pairs
    (sort
     (hash-map (cookie-jar-table jar)
               (lambda (name value)
                 (cons (symbol->string name) value)))
     string<?
     #:key car))
  (and (pair? pairs)
       (string-join (map (lambda (p) (string-append (car p) "=" (cdr p))) pairs) "; ")))

;; ---------------------------------------------------------------- responses

(struct http-response (status headers body) #:transparent)
;; status  : exact-integer?
;; headers : (listof (cons lowercase-name string))
;; body    : bytes?

(define max-http-body-bytes (* 64 1024 1024))

(define (header-value headers name)
  (define lowered (string-downcase name))
  (for/or ([pair (in-list headers)])
    (and (string=? (car pair) lowered) (cdr pair))))

(define (header-values headers name)
  (define lowered (string-downcase name))
  (for/list ([pair (in-list headers)]
             #:when (string=? (car pair) lowered))
    (cdr pair)))

;; -------------------------------------------------------------- wire reading

(define max-head-bytes 65536)

;; Read bytes up to and including the first CRLFCRLF. Raises on EOF.
(define (read-head in)
  (define out (open-output-bytes))
  (let loop ([got 0] [window ""])
    (define b (read-byte in))
    (when (eof-object? b)
      (error 'http "connection closed before the response head completed"))
    (write-byte b out)
    (define next (string-append window (string (integer->char b))))
    (define trimmed (if (> (string-length next) 4) (substring next 1) next))
    (when (> (add1 got) max-head-bytes)
      (error 'http "response head exceeds ~a bytes" max-head-bytes))
    (if (string=? trimmed "\r\n\r\n")
        (get-output-bytes out)
        (loop (add1 got) trimmed))))

(define (read-line-crlf in)
  (let loop ([chars '()])
    (define b (read-byte in))
    (cond
      [(eof-object? b) (list->string (reverse chars))]
      [(= b 10) (list->string (reverse chars))]
      [(= b 13) (read-byte in) (list->string (reverse chars))]
      [else (loop (cons (integer->char b) chars))])))

(define (read-exact-bytes in n)
  (define out (make-bytes n))
  (let loop ([filled 0])
    (cond
      [(= filled n) out]
      [else
       (define got (read-bytes! out in filled n))
       (when (eof-object? got)
         (error 'http "connection closed with ~a of ~a body bytes read" filled n))
       (loop (+ filled got))])))

(define (read-to-eof in)
  (define out (open-output-bytes))
  (let loop ([count 0])
    (define b (read-byte in))
    (cond
      [(eof-object? b) (get-output-bytes out)]
      [else
       (when (> count max-http-body-bytes)
         (error 'http "response body exceeds ~a bytes" max-http-body-bytes))
       (write-byte b out)
       (loop (add1 count))])))

(define (read-chunked in)
  (define out (open-output-bytes))
  (define (read-chunk!)
    (define line (read-line-crlf in))
    (define size-text (string-trim (car (string-split line ";" #:trim? #f))))
    (string->number size-text 16))
  (let loop ()
    (define size (read-chunk!))
    (unless size (error 'http "malformed chunked response"))
    (cond
      [(zero? size)
       ;; Consume trailer lines up to the blank terminator line.
       (let trailer ()
         (define line (read-line-crlf in))
         (unless (string=? line "") (trailer)))
       (get-output-bytes out)]
      [else
       (copy-port-bytes! in out size)
       (read-line-crlf in) ; CRLF after the chunk data
       (loop)])))

;; copy-port would stop at EOF; here the exact chunk length is known.
(define (copy-port-bytes! in out n)
  (let loop ([left n])
    (unless (zero? left)
      (define b (read-byte in))
      (when (eof-object? b)
        (error 'http "connection closed inside a chunked body"))
      (write-byte b out)
      (loop (sub1 left)))))

;; Parse and read one complete HTTP/1.1 response from `in`.
(define (read-http-response in)
  (define head-bytes (read-head in))
  (define lines
    (string-split (bytes->string/latin-1 head-bytes) "\r\n" #:trim? #f))
  (when (null? lines)
    (error 'http "empty response head"))
  (define status
    (let ([parts (string-split (car lines) " " #:trim? #t)])
      (cond
        [(and (>= (length parts) 2)
              (string->number (list-ref parts 1)))
         => values]
        [else (error 'http "malformed status line: ~a" (car lines))])))
  (define headers
    (for/list ([line (in-list (cdr lines))]
               #:when (not (string=? line ""))
               #:do [(define idx (string-index-of-colon line))]
               #:when idx)
      (cons (string-downcase (substring line 0 idx))
            (string-trim (substring line (add1 idx))))))
  (define body
    (cond
      [(member "chunked"
               (map string-trim
                    (string-split (or (header-value headers "transfer-encoding") "")
                                  ",")))
       (read-chunked in)]
      [(header-value headers "content-length")
       => (lambda (v)
            (define n (string->number (string-trim v)))
            (unless n (error 'http "malformed Content-Length: ~a" v))
            (unless (<= n max-http-body-bytes)
              (error 'http "response body exceeds ~a bytes" max-http-body-bytes))
            (read-exact-bytes in n))]
      [else (read-to-eof in)]))
  (http-response status headers body))

;; Locate the first colon in a header line; #f when there is none.
(define (string-index-of-colon line)
  (let loop ([i 0])
    (cond
      [(= i (string-length line)) #f]
      [(char=? (string-ref line i) #\:) i]
      [else (loop (add1 i))])))

;; ------------------------------------------------------------------- client

;; Run `thunk` in a custodian-isolated thread with a wall-clock deadline.
;; On timeout the worker's custodian (ports, connections) is torn down and an
;; error is raised.
;; Socket IO must run on a thread of the ORIGINAL custodian. Rivet runs each
;; RPC in a request custodian, and socket work from those threads misbehaves
;; (connections mysteriously refused / responses delayed — observed on
;; macOS). A single dispatcher thread created at module load (root
;; custodian) executes all HTTP work serially; callers wait with a deadline
;; and abandon the result on timeout (loopback requests always finish).
(define io-dispatch-channel (make-channel))
(define io-dispatcher
  (thread
   (lambda ()
     (let loop ()
       (define job (channel-get io-dispatch-channel))
       (when job
         ((car job))
         (loop))))))

(define (with-deadline secs who thunk)
  (define result (box #f))
  (define done (make-semaphore))
  (channel-put
   io-dispatch-channel
   (list (lambda ()
           (set-box! result
                     (with-handlers ([exn:fail? (lambda (e) (cons 'raised e))])
                       (cons 'ok (thunk))))
           (semaphore-post done))))
  (define finished (sync/timeout secs done))
  (cond
    [(not finished) (error who "timed out after ~as" secs)]
    [else
     (define r (unbox result))
     (cond
       [(and (pair? r) (eq? (car r) 'ok)) (cdr r)]
       [(and (pair? r) (eq? (car r) 'raised)) (raise (cdr r))]
       [else (error who "request worker terminated without a result")])]))

;; One HTTP/1.1 request against 127.0.0.1:<port>. Raises on network failure;
;; response status codes are returned, never raised.
(define (http-call #:port port
                   #:path path                    ; path + query, no host
                   #:method [method "GET"]
                   #:headers [headers '()]        ; (cons name value), any case
                   #:body [body #""]
                   #:timeout-secs [timeout-secs 8]
                   #:cookie-jar [jar #f])
  (with-deadline
   timeout-secs
   'http-call
   (lambda ()
     (define-values (in out)
       (tcp-connect "127.0.0.1" port))
     (dynamic-wind
       (lambda () (void))
       (lambda ()
         (define cookie-header (and jar (cookie-jar-header jar)))
         (define merged
           (append
            headers
            (if cookie-header (list (cons "Cookie" cookie-header)) '())
            (list (cons "Host" (format "127.0.0.1:~a" port))
                  (cons "Connection" "close"))))
         (fprintf out "~a ~a HTTP/1.1\r\n" method path)
         (for ([pair (in-list merged)])
           (fprintf out "~a: ~a\r\n" (car pair) (cdr pair)))
         (when (and (zero? (bytes-length body))
                    (member method '("POST" "PUT" "PATCH" "DELETE")))
           (fprintf out "Content-Length: 0\r\n"))
         (unless (zero? (bytes-length body))
           (fprintf out "Content-Length: ~a\r\n" (bytes-length body)))
         (write-bytes #"\r\n" out)
         (unless (zero? (bytes-length body))
           (write-bytes body out)
           (flush-output out))
         (flush-output out)
         (define response (read-http-response in))
         (when jar
           (for ([cookie (in-list (header-values (http-response-headers response)
                                                 "set-cookie"))])
             (cookie-jar-store! jar cookie)))
         response)
       (lambda ()
         (with-handlers ([exn:fail? void])
           (close-input-port in)
           (close-output-port out)))))))

;; ------------------------------------------------------------------- sha256

;; Hex digest of `data`. Prefers libcrypto's one-shot SHA256 when available
;; (the pinned download check can hash a ~15 MB archive) and falls back to a
;; self-contained pure-Racket implementation otherwise. Both paths agree on
;; the FIPS test vectors asserted in racket/tests/install-test.rkt.
(define (sha256-hex data)
  (cond
    [sha256-native
     (with-handlers ([exn:fail? (lambda (_) (sha256-pure data))])
       (define out (make-bytes 32))
       (sha256-native data (bytes-length data) out)
       (bytes->hex-string out))]
    [else (sha256-pure data)]))

(define (bytes->hex-string bstr)
  (apply string-append
         (for/list ([c (in-bytes bstr)])
           (~r c #:base 16 #:min-width 2 #:pad-string "0"))))

(define sha256-native
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define lib (ffi-lib "libcrypto"))
    (get-ffi-obj "SHA256" lib (_fun _bytes _long _bytes -> _void) (lambda () #f))))

(define (m32 x) (bitwise-and x #xFFFFFFFF))
(define (rr32 x n)
  (m32 (bitwise-ior (arithmetic-shift x (- n)) (arithmetic-shift x (- 32 n)))))

(define sha256-k
  '#(#x428a2f98 #x71374491 #xb5c0fbcf #xe9b5dba5 #x3956c25b #x59f111f1
     #x923f82a4 #xab1c5ed5 #xd807aa98 #x12835b01 #x243185be #x550c7dc3
     #x72be5d74 #x80deb1fe #x9bdc06a7 #xc19bf174 #xe49b69c1 #xefbe4786
     #x0fc19dc6 #x240ca1cc #x2de92c6f #x4a7484aa #x5cb0a9dc #x76f988da
     #x983e5152 #xa831c66d #xb00327c8 #xbf597fc7 #xc6e00bf3 #xd5a79147
     #x06ca6351 #x14292967 #x27b70a85 #x2e1b2138 #x4d2c6dfc #x53380d13
     #x650a7354 #x766a0abb #x81c2c92e #x92722c85 #xa2bfe8a1 #xa81a664b
     #xc24b8b70 #xc76c51a3 #xd192e819 #xd6990624 #xf40e3585 #x106aa070
     #x19a4c116 #x1e376c08 #x2748774c #x34b0bcb5 #x391c0cb3 #x4ed8aa4a
     #x5b9cca4f #x682e6ff3 #x748f82ee #x78a5636f #x84c87814 #x8cc70208
     #x90befffa #xa4506ceb #xbef9a3f7 #xc67178f2))

(define (sha256-pure data)
  (define len (bytes-length data))
  (define total-bits (* 8 len))
  (define padded-len (* (ceiling (/ (+ len 9) 64)) 64))
  (define buf (make-bytes padded-len))
  (bytes-copy! buf 0 data)
  (bytes-set! buf len #x80)
  (for ([i (in-range 8)])
    (bytes-set! buf (+ (- padded-len 8) i)
                ;; negative shift = right shift (big-endian 64-bit length)
                (bitwise-and (arithmetic-shift total-bits (* 8 (- i 7))) #xFF)))
  (define h (make-vector 8))
  (for ([i (in-range 8)]
        [v (in-list '(#x6a09e667 #xbb67ae85 #x3c6ef372 #xa54ff53a
                      #x510e527f #x9b05688c #x1f83d9ab #x5be0cd19))])
    (vector-set! h i v))
  (define w (make-vector 64))
  (let block ([off 0])
    (when (< off padded-len)
      (for ([t (in-range 16)])
        (vector-set! w t
                     (+ (* (bytes-ref buf (+ off (* 4 t))) 16777216)
                        (* (bytes-ref buf (+ off (* 4 t) 1)) 65536)
                        (* (bytes-ref buf (+ off (* 4 t) 2)) 256)
                        (bytes-ref buf (+ off (* 4 t) 3)))))
      (for ([t (in-range 16 64)])
        (define w15 (vector-ref w (- t 15)))
        (define w2 (vector-ref w (- t 2)))
        (define s0 (bitwise-xor (rr32 w15 7) (rr32 w15 18) (arithmetic-shift w15 -3)))
        (define s1 (bitwise-xor (rr32 w2 17) (rr32 w2 19) (arithmetic-shift w2 -10)))
        (vector-set! w t
                     (m32 (+ (vector-ref w (- t 16)) s0
                             (vector-ref w (- t 7)) s1))))
      (let round-loop ([t 0]
                       [a (vector-ref h 0)] [b (vector-ref h 1)]
                       [c (vector-ref h 2)] [d (vector-ref h 3)]
                       [e (vector-ref h 4)] [f (vector-ref h 5)]
                       [g (vector-ref h 6)] [hh (vector-ref h 7)])
        (if (= t 64)
            (for ([i (in-list (list 0 1 2 3 4 5 6 7))]
                  [v (in-list (list a b c d e f g hh))])
              (vector-set! h i (m32 (+ (vector-ref h i) v))))
            (let* ([s1 (bitwise-xor (rr32 e 6) (rr32 e 11) (rr32 e 25))]
                   [ch (bitwise-xor (bitwise-and e f)
                                    (bitwise-and (bitwise-not (m32 e)) g))]
                   [temp1 (m32 (+ hh s1 ch (vector-ref sha256-k t) (vector-ref w t)))]
                   [s0 (bitwise-xor (rr32 a 2) (rr32 a 13) (rr32 a 22))]
                   [maj (bitwise-xor (bitwise-and a b)
                                     (bitwise-and a c)
                                     (bitwise-and b c))]
                   [temp2 (m32 (+ s0 maj))])
              ;; h<-g g<-f f<-e e<-d+temp1 d<-c c<-b b<-a a<-temp1+temp2
              (round-loop (add1 t)
                          (m32 (+ temp1 temp2)) a b c
                          (m32 (+ d temp1)) e f g))))
      (block (+ off 64))))
  (apply string-append
         (for/list ([v (in-vector h)])
           (~a (number->string v 16)
               #:min-width 8 #:align 'right #:pad-string "0"))))
