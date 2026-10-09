#lang racket/base

;; Hub routing tests: drive the pure `route` function directly — no HTTP
;; plumbing. Covers the blob round trip, manifest writes, the devices list,
;; malformed inputs, and bearer-token authorization.

(require json
         racket/file
         racket/list
         racket/port
         racket/string
         crypto
         crypto/libcrypto
         rackunit
         "../app/format.rkt"
         "../hub/server.rkt")

(crypto-factories (list libcrypto-factory))

(define (bytes->hex-string/own b)
  (define digits "0123456789abcdef")
  (list->string
   (append* (for/list ([x (in-bytes (digest 'sha256 b))])
              (list (string-ref digits (arithmetic-shift x -4))
                    (string-ref digits (bitwise-and x #x0F)))))))

(define repo-root (make-temporary-file "keepsake-hub-~a" 'directory))
(define repo (hub-repo-open repo-root))

(define (run method path [auth "Bearer test-token"] [body #""])
  (route repo-root "test-token" method path auth body))

(test-case "healthz reports the format version"
  (define res (run "GET" "/healthz"))
  (check-equal? (first res) 200)
  (check-equal? (hash-ref (read-json (open-input-bytes (third res))) 'format_version)
                format-version))

(test-case "blob round trip: put then get"
  (define data #"chunk-bytes-0123456789")
  (define hash
    (bytes->hex-string/own data))
  (define path (string-append "/api/blobs/sha256/" (substring hash 0 2) "/" hash))
  (check-equal? (first (run "PUT" path "Bearer test-token" data)) 204)
  (define got (run "GET" path))
  (check-equal? (first got) 200)
  (check-equal? (third got) data))

(test-case "malformed blob paths are rejected"
  (check-equal? (first (run "PUT" "/api/blobs/sha256/zz/not-a-hash")) 400)
  (check-equal? (first (run "PUT" "/api/blobs/sha256/aa/short")) 400))

(test-case "manifest write requires JSON and the right suffix"
  (define manifest
    (hasheq 'format_version format-version
            'device_id "dev-hub"
            'account "wxid_hub"
            'host_platform "darwin"
            'created_at "2026-10-09T12:00:00.000Z"
            'files '()))
  (define body (jsexpr->bytes manifest))
  ;; wrong suffix
  (check-equal? (first (run "PUT" "/api/devices/dev-hub/snapshots/not-a-manifest")) 400)
  ;; bad device
  (check-equal? (first (run "PUT" "/api/devices/../evil/snapshots/x.manifest.json" "Bearer test-token" body)) 400)
  ;; not JSON
  (check-equal? (first (run "PUT" "/api/devices/dev-hub/snapshots/2026.manifest.json" "Bearer test-token" #"nope")) 400)
  ;; happy path
  (check-equal? (first (run "PUT" "/api/devices/dev-hub/snapshots/20261009T120000.000Z.manifest.json" "Bearer test-token" body)) 200)
  ;; visible in the device listing
  (define snaps (run "GET" "/api/devices/dev-hub/snapshots"))
  (check-equal? (first snaps) 200)
  (check-equal? (length (read-json (open-input-bytes (third snaps)))) 1)
  ;; and the device shows up in the devices list
  (define devices (run "GET" "/api/devices"))
  (check-not-false (member "dev-hub" (read-json (open-input-bytes (third devices))))))

(test-case "bad bodies and unknown routes"
  (check-equal? (first (run "GET" "/api/nope")) 404)
  (check-equal? (first (run "PATCH" "/api/devices")) 404))

(test-case "bearer token gate"
  ;; authorized request passes, missing/wrong token fails with 401
  (check-equal? (first (route repo-root "test-token" "GET" "/healthz" "Bearer test-token" #"")) 200)
  (check-equal? (first (route repo-root "test-token" "GET" "/healthz" "Bearer wrong" #"")) 401)
  (check-equal? (first (route repo-root "test-token" "GET" "/healthz" #f #"")) 401))


