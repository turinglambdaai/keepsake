#lang racket/base

;; HTTP client for the keepsake hub. Thin on purpose: one request primitive
;; (`hub-request`) plus the hub calls the engine needs.
;;
;; `current-hub-send` lets tests replace the network with a direct call into
;; the hub's pure router — client and server logic get exercised together
;; with zero sockets.

(require json
         net/url
         racket/contract
         racket/port
         racket/string)

(provide (contract-out
          [current-hub-send parameter?]
          [hub-request (-> string? (or/c string? #f) string? string? bytes?
                           (values exact-nonnegative-integer? bytes?))]
          [hub-healthz (-> string? (or/c string? #f) (or/c jsexpr? #f))]
          [hub-put-blob (-> string? (or/c string? #f) string? bytes? void?)]
          [hub-get-blob (-> string? (or/c string? #f) string? (or/c bytes? #f))]
          [hub-put-manifest (-> string? (or/c string? #f) string? string? bytes? void?)]
          [hub-list-devices (-> string? (or/c string? #f) jsexpr?)]
          [hub-list-snapshots (-> string? (or/c string? #f) string? jsexpr?)]))

;; "/api" "devices" dev "/snapshots/" name → "/api/devices/dev/snapshots/name"
(define (api-path . parts)
  (string-append "/"
   (string-join
    (for/list ([p (in-list parts)])
      (string-trim p #px"/+"))
    "/")))

;; Default transport: net/url with the status line parsed by hand.
;; Returns (values status-code body-bytes).
(define (default-hub-send base token method path body)
  (define url (string->url (string-append (string-trim base #px"/+") path)))
  (define headers
    (append
     (if token
         (list (string-append "Authorization: Bearer " token))
         '())
     (list "Content-Type: application/octet-stream")))
  (define in
    (case method
      [("GET") (get-impure-port url headers)]
      [("HEAD") (head-impure-port url headers)]
      [("PUT") (put-impure-port url body headers)]
      [else (error 'hub-request "unsupported method ~a" method)]))
  ;; Status line: "HTTP/1.1 204 No Content"
  (define status-line (read-line in 'any))
  (define parts (string-split (string-trim status-line)))
  (define code
    (if (>= (length parts) 2)
        (or (string->number (list-ref parts 1)) 0)
        0))
  ;; Drain headers up to the blank line.
  (let loop ()
    (define l (read-line in 'any))
    (unless (or (eof-object? l) (equal? l "")) (loop)))
  (define body-bytes (port->bytes in))
  (close-input-port in)
  (values code body-bytes))

;; Injectable so tests can route requests straight into the hub router.
(define current-hub-send (make-parameter default-hub-send))

;; The single entry point all hub calls go through.
(define (hub-request base token method path body)
  ((current-hub-send) base token method path body))

(define (hub-healthz base token)
  (define-values (code body) (hub-request base token "GET" "/healthz" #""))
  (if (= code 200)
      (with-handlers ([exn:fail? (lambda (_) #f)])
        (read-json (open-input-bytes body)))
      #f))

(define (hub-put-blob base token hash blob-bytes)
  (define path (api-path "api/blobs/sha256" (substring hash 0 2) hash))
  (define-values (code _) (hub-request base token "PUT" path blob-bytes))
  (unless (= code 204)
    (error 'hub-put-blob "hub refused blob ~a (HTTP ~a)" hash code)))

(define (hub-get-blob base token hash)
  (define path (api-path "api/blobs/sha256" (substring hash 0 2) hash))
  (define-values (code body) (hub-request base token "GET" path #""))
  (if (= code 200) body #f))

(define (hub-put-manifest base token device filename manifest-bytes)
  (define path (api-path "api/devices" device "snapshots" filename))
  (define-values (code _) (hub-request base token "PUT" path manifest-bytes))
  (unless (or (= code 204) (= code 200))
    (error 'hub-put-manifest "hub refused manifest ~a (HTTP ~a)" filename code)))

(define (hub-list-devices base token)
  (define-values (code body) (hub-request base token "GET" "/api/devices" #""))
  (unless (= code 200)
    (error 'hub-list-devices "HTTP ~a" code))
  (read-json (open-input-bytes body)))

(define (hub-list-snapshots base token device)
  (define path (api-path "api/devices" device "snapshots"))
  (define-values (code body) (hub-request base token "GET" path #""))
  (unless (= code 200)
    (error 'hub-list-snapshots "HTTP ~a" code))
  (read-json (open-input-bytes body)))
