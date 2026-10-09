#lang racket/base

;; Client↔hub integration without sockets: `current-hub-send` is pointed
;; straight at the hub's pure router, so the real client calls and the real
;; server logic must agree on paths, auth, payloads, and status codes.

(require json
         racket/file
         racket/list
         crypto
         crypto/libcrypto
         racket/port
         rackunit
         "../app/format.rkt"
         "../app/hub-client.rkt"
         "../app/repo.rkt"
         "../hub/server.rkt")

(crypto-factories (list libcrypto-factory))

(define repo-root (make-temporary-file "keepsake-hc-~a" 'directory))
(hub-repo-open repo-root)

(define token "integration-token")

;; Adapter: client requests go straight into the router. The client passes
;; the raw token; the router wants the full Authorization header.
(current-hub-send
 (lambda (base tok method path body)
   (define auth (and tok (string-append "Bearer " tok)))
   (define result (route repo-root token method path auth body))
   (values (first result) (third result))))

(define BASE "http://hub.test")

(test-case "healthz round trip through the client"
  (define health (hub-healthz BASE token))
  (check-true (hash? health))
  (check-equal? (hash-ref health 'format_version) format-version))

(test-case "blob put/get round trip through the client"
  (define data #"integration-blob-0123456789")
  (define digits "0123456789abcdef")
  (define hash
    (list->string
     (append* (for/list ([x (in-bytes (digest 'sha256 data))])
                (list (string-ref digits (arithmetic-shift x -4))
                      (string-ref digits (bitwise-and x #x0F)))))))
  (hub-put-blob BASE token hash data)
  (check-equal? (hub-get-blob BASE token hash) data)
  (check-false (hub-get-blob BASE token (make-string 64 #\0))))

(test-case "manifest push and snapshot listing through the client"
  (define manifest
    (hasheq 'format_version format-version
            'device_id "dev-ic"
            'account "wxid_ic"
            'host_platform "darwin"
            'created_at "2026-10-09T18:00:00.000Z"
            'files '()))
  (hub-put-manifest BASE token "dev-ic" "20261009T180000.000Z.manifest.json"
                    (string->bytes/utf-8 (jsexpr->string manifest)))
  (check-equal? (hub-list-devices BASE token) '("dev-ic"))
  (define snaps (hub-list-snapshots BASE token "dev-ic"))
  (check-equal? (length snaps) 1)
  (check-equal? (hash-ref (car snaps) 'account) "wxid_ic"))

(test-case "hub health-check failure surfaces at repo open"
  (check-exn exn:fail?
             (lambda ()
               ;; No adapter override for this base: the default transport
               ;; cannot reach a hub on a non-resolvable host, and even if
               ;; it could, it would not speak our health endpoint.
               (parameterize ([current-hub-send
                               (lambda (base tok method path body)
                                 (values 503 #"unavailable"))])
                 (string->repo "http://unreachable.test:1")))))

(test-case "string->repo opens a hub handle after a healthy healthz"
  (define repo (string->repo "http://hub.test" token))
  (check-true (hub-repo? repo))
  (check-equal? (hash-ref repo 'base) "http://hub.test"))
