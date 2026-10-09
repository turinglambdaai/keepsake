#lang racket/base

;; Keepsake Hub: a read/write HTTP facade over a keepsake repository
;; directory — the exact layout agents write on a local volume or SMB mount
;; (docs/repo-format.md). The hub adds remote reach, a browser timeline, and
;; (later) GC and verification; nothing in the format depends on it, and a
;; hub outage never stops a backup.
;;
;; Routing lives in `route` (pure: method + path + auth header + body →
;; code/type/bytes) so tests exercise it without any HTTP plumbing; the
;; servlet at the bottom is a thin adapter.

(require json
         racket/contract
         racket/file
         racket/list
         net/url
         racket/path
         racket/port
         racket/string
         web-server/http
         "../app/format.rkt"
         "../app/repo.rkt"
         "timeline.rkt")

(provide (contract-out
          [route (-> path-string? (or/c string? #f)
                     string? string? (or/c string? #f) bytes?
                     (list/c exact-nonnegative-integer? string? bytes?))]
          [hub-repo-open (-> path-string? repo?)]))

;; ---- repository handle ----

;; Opens (initializing when needed) the hub's repository root.
(define (hub-repo-open root)
  (repo-init root))

;; ---- helpers ----

(define (jsexpr-response code value)
  (list code "application/json; charset=utf-8" (jsexpr->bytes value)))

(define (text-response code text)
  (list code "text/plain; charset=utf-8" (string->bytes/utf-8 text)))

(define (authorized? token auth-header)
  (or (not token) ; no token configured: open mode (log a warning at boot)
      (and auth-header
           (string-prefix? auth-header "Bearer ")
           (string=? (substring auth-header 7) token))))

;; Blob store path under the hub repository: sha256/<xx>/<hash>.
(define (hub-blob-path root hash)
  (build-path root "blobs" "sha256" (substring hash 0 2) hash))

(define (valid-hash? s)
  (and (string? s)
       (= (string-length s) 64)
       (regexp-match? #px"^[0-9a-f]{64}$" s)))

;; ---- routing ----

;; (route repo-root token method raw-path auth-header body)
;;   → (list http-status content-type body-bytes)
;;
;;   GET  /healthz
;;   GET  /api/devices
;;   GET  /api/devices/<device>/snapshots
;;   GET  /api/blobs/sha256/<xx>/<hash>
;;   PUT  /api/blobs/sha256/<xx>/<hash>          (raw bytes)
;;   PUT  /api/devices/<device>/snapshots/<name> (manifest JSON)
;;   GET  /                                      (timeline page)
(define (route repo-root token method raw-path auth-header body)
  (define path (string-split (string-trim raw-path "/") "/" #:trim? #f))
  (define segments (map (lambda (s) (uri-decode-safe s)) path))

  (cond
    [(not (authorized? token auth-header))
     (list 401 "text/plain; charset=utf-8" #"unauthorized")]

    [(member ".." segments)
     (jsexpr-response 400 (hasheq 'error "path traversal rejected"))]

    [(and (equal? method "GET") (equal? path '("healthz")))
     (jsexpr-response 200 (hasheq 'ok #t 'format_version format-version))]

    [(and (equal? method "GET") (null? segments))
     (list 200 "text/html; charset=utf-8"
           (string->bytes/utf-8 (timeline-html repo-root token)))]

    ;; ---- devices ----
    [(and (equal? method "GET")
          (= (length segments) 2)
          (equal? (first segments) "api")
          (equal? (second segments) "devices"))
     (define root (simple-form-path repo-root))
     (define dev-dir (build-path root "devices"))
     (jsexpr-response
      200
      (if (directory-exists? dev-dir)
          (map path->string (directory-list dev-dir))
          '()))]

    [(and (equal? method "GET")
          (= (length segments) 4)
          (equal? (first segments) "api")
          (equal? (second segments) "devices"))
     (define device (third segments))
     (define snapshots-dir
       (build-path (simple-form-path repo-root) "devices" device "snapshots"))
     (cond
       [(not (directory-exists? snapshots-dir))
        (jsexpr-response 404 (hasheq 'error "no such device"))]
       [else
        (jsexpr-response
         200
         (for/list ([f (in-list (sort (directory-list snapshots-dir)
                                      string<?
                                      #:key path->string))]
                    #:when (string-suffix? (path->string f) manifest-suffix))
           (with-input-from-file (build-path snapshots-dir f) read-json)))])]

    ;; ---- manifests ----
    [(and (equal? method "PUT")
          (= (length segments) 5)
          (equal? (first segments) "api")
          (equal? (second segments) "devices")
          (equal? (fourth segments) "snapshots"))
     (define device (third segments))
     (define name (fifth segments))
     (cond
       [(not (string-suffix? name manifest-suffix))
        (jsexpr-response 400 (hasheq 'error "manifest filename must end in .manifest.json"))]
       [(not (safe-device-name? device))
        (jsexpr-response 400 (hasheq 'error "bad device id"))]
       [else
        (define parsed
          (with-handlers ([exn:fail? (lambda (_) #f)])
            (read-json (open-input-bytes body))))
        (cond
          [(not (and (hash? parsed)
                     (exact-integer? (hash-ref parsed 'format_version #f))))
           (jsexpr-response 400 (hasheq 'error "body is not a manifest JSON"))]
          [else
           (define dir (build-path (simple-form-path repo-root)
                                   "devices" device "snapshots"))
           (make-directory* dir)
           ;; Same-millisecond snapshots get a -2/-3 suffix so both survive
           ;; and still sort next to each other.
           (define final
             (let loop ([n 0])
               (define candidate
                 (if (zero? n)
                     name
                     (string-replace name ".manifest.json"
                                     (format "-~a.manifest.json" n))))
               (define p (build-path dir candidate))
               (if (file-exists? p) (loop (add1 n)) p)))
           (with-output-to-file final
             #:exists 'truncate
             (lambda () (write-bytes body)))
           (jsexpr-response 200 (hasheq 'ok #t
                                        'stored (path->string final)))])])]

    ;; ---- blobs ----
    [(and (= (length segments) 5)
          (equal? (first segments) "api")
          (equal? (second segments) "blobs")
          (equal? (third segments) "sha256"))
     (define hash (fifth segments))
     (define fanout (fourth segments))
     (cond
       [(not (and (valid-hash? hash) (equal? fanout (substring hash 0 2))))
        (jsexpr-response 400 (hasheq 'error "malformed blob path"))]
       [(equal? method "HEAD")
        (if (file-exists? (hub-blob-path (simple-form-path repo-root) hash))
            (list 200 "application/octet-stream" #"")
            (jsexpr-response 404 (hasheq 'error "no such blob")))]
       [(equal? method "PUT")
        (define dst (hub-blob-path (simple-form-path repo-root) hash))
        (make-directory* (path-only dst))
        (with-output-to-file dst
          #:exists 'truncate
          (lambda () (write-bytes body)))
        (jsexpr-response 204 (hasheq 'ok #t))]
       [(equal? method "GET")
        (if (file-exists? (hub-blob-path (simple-form-path repo-root) hash))
            (list 200 "application/octet-stream"
                  (file->bytes (hub-blob-path (simple-form-path repo-root) hash)))
            (jsexpr-response 404 (hasheq 'error "no such blob")))]
       [else (jsexpr-response 405 (hasheq 'error "method not allowed"))])]

    [else (jsexpr-response 404 (hasheq 'error "not found"))]))

;; Percent-decoding without pulling in the web-server internals twice.
(define (uri-decode-safe s)
  (with-handlers ([exn:fail? (lambda (_) s)])
    (let* ([s1 (string-replace s "+" " ")]
           [bytes
            (let loop ([chars (string->list s1)] [acc '()])
              (cond
                [(null? chars) (reverse acc)]
                [(char=? (car chars) #\%)
                 (if (>= (length chars) 3)
                     (loop (cdddr chars)
                           (cons (integer->char
                                  (string->number
                                   (list->string (take (cdr chars) 2)) 16))
                                 acc))
                     (loop (cdr chars) (cons (car chars) acc)))]
                [else (loop (cdr chars) (cons (car chars) acc))]))])
      (list->string bytes))))

(define (safe-device-name? device)
  (and (non-empty-string? device)
       (not (string-contains? device ".."))
       (not (string-contains? device "/"))
       (not (string-contains? device "\\"))))

;; ---- servlet adapter + entry point ----

;; Extracts (method raw-path auth-header body-bytes) from a web-server
;; request and hands it to `route`.
(define (make-hub-app repo-root token)
  (lambda (req)
    (define method (bytes->string/utf-8 (request-method req)))
    (define raw-path
      (url->raw-path (request-uri req)))
    (define auth-header
      (or (headers-assq* #"authorization" (request-headers/raw req))
          ;; Browsers cannot send Authorization headers; ?token= works for
          ;; the read-only timeline on a trusted LAN.
          (let ([q (url-query (request-uri req))])
            (for/first ([kv (in-list q)]
                        #:when (equal? (car kv) 'token))
              (string-append "Bearer " (cdr kv))))))
    (define body
      (or (request-post-data/raw req) #""))
    (define result (route repo-root token method raw-path auth-header body))
    (define code (first result))
    (define type (second result))
    (define payload (third result))
    (response/full code
                   (status->message code)
                   (current-seconds)
                   (string->bytes/utf-8 type)
                   (list (header #"Content-Type" (string->bytes/utf-8 type)))
                   (list payload))))

(define (url->raw-path u)
  (define path-parts (map path/param-path (url-path u)))
  (string-join path-parts "/"))

(define (headers-assq* name hdrs)
  ;; Header field names are matched case-insensitively: raw requests keep
  ;; whatever case the client sent ("Authorization" from curl, e.g.).
  (define wanted (bytes->string/utf-8 name))
  (for/first ([h (in-list hdrs)]
              #:when (equal? (string-downcase
                              (bytes->string/utf-8 (header-field h)))
                             wanted))
    (string-trim (bytes->string/utf-8 (header-value h)))))

(define (status->message code)
  (case code
    [(200) #"OK"]
    [(204) #"No Content"]
    [(400) #"Bad Request"]
    [(401) #"Unauthorized"]
    [(404) #"Not Found"]
    [(405) #"Method Not Allowed"]
    [else #""]))

(module+ main
  (require web-server/servlet-env
           racket/cmdline)
  (define repo-root
    (or (getenv "KEEPSAKE_HUB_REPO_ROOT") "hub-repo"))
  (define token (getenv "KEEPSAKE_HUB_TOKEN"))
  (define port
    (string->number (or (getenv "KEEPSAKE_HUB_PORT") "8080")))
  (hub-repo-open repo-root)
  (when (not token)
    (displayln "keepsake-hub: KEEPSAKE_HUB_TOKEN is not set — running in open mode; set a token before exposing this port"))
  (printf "keepsake-hub: repository at ~a, listening on :~a\n" repo-root port)
  (flush-output)
  (serve/servlet (make-hub-app repo-root token)
                 #:port port
                 #:listen-ip #f
                 #:command-line? #t
                 #:servlet-regexp #rx""))
