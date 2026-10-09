#lang racket/base
(require rackunit)

;; GC tests: a referenced blob survives, an aged unreferenced blob is swept,
;; and a fresh unreferenced blob survives the grace window.

(require crypto
         crypto/libcrypto
         json
         racket/file
         racket/list
         racket/path
         racket/port
         racket/set
         racket/string
         "../app/format.rkt"
         "../hub/gc.rkt")

(crypto-factories (list libcrypto-factory))

(define (hex-of b)
  (define digits "0123456789abcdef")
  (list->string
   (append* (for/list ([x (in-bytes (digest 'sha256 b))])
              (list (string-ref digits (arithmetic-shift x -4))
                    (string-ref digits (bitwise-and x #x0F)))))))

(define (store-blob! root name bytes)
  (define p (build-path root "blobs" "sha256" (substring name 0 2) name))
  (make-directory* (path-only p))
  (call-with-output-file p
    (lambda (out) (write-bytes bytes))
    #:mode 'binary
    #:exists 'replace))

(define (write-manifest! root device-name created-at chunks)
  (define snaps (build-path root "devices" device-name "snapshots"))
  (make-directory* snaps)
  (with-output-to-file (build-path snaps created-at)
    #:exists 'replace
    (lambda ()
      (write-json
       (hasheq 'format_version format-version
               'device_id device-name
               'account "a"
               'host_platform "darwin"
               'created_at "2026-10-09T12:00:00.000Z"
               'files (list (hasheq 'path "f"
                                    'size 18
                                    'mode 420
                                    'mod_time "2026-10-09T12:00:00.000Z"
                                    'chunks chunks)))))))

(define (blob-path root hash)
  (build-path root "blobs" "sha256" (substring hash 0 2) hash))

(define root (make-temporary-file "keepsake-gc-~a" 'directory))

;; one referenced blob, named by a manifest
(define ref-data #"referenced content")
(define ref-hash (hex-of ref-data))
(store-blob! root ref-hash ref-data)
(write-manifest! root "dev" "20261009T120000.000Z.manifest.json"
                 (list (hasheq 'hash ref-hash 'offset 0 'size (bytes-length ref-data))))

;; one aged orphan
(define orphan (hex-of #"orphan content"))
(store-blob! root orphan #"orphan content")
(file-or-directory-modify-seconds
 (blob-path root orphan)
 (- (current-seconds) 100000))

(test-case "referenced hashes come from manifests"
  (check-equal? (referenced-hashes root) (list ref-hash)))

(test-case "gc sweeps the aged orphan and keeps the referenced blob"
  (define deleted (gc-repo! root 3600))
  (check-equal? (length deleted) 1)
  (check-true (file-exists? (blob-path root ref-hash)))
  (check-false (file-exists? (blob-path root orphan))))

(test-case "fresh orphans survive the grace window"
  (define fresh (hex-of #"fresh orphan"))
  (store-blob! root fresh #"fresh orphan")
  (check-equal? (length (gc-repo! root 3600)) 0)
  (check-true (file-exists? (blob-path root fresh))))
