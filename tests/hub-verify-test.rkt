#lang racket/base
(require rackunit)
(require json)

;; Verify tests: a healthy repository reports no problems; a corrupted blob
;; is named; a manifest referencing a missing blob is named.

(require crypto
         crypto/libcrypto
         racket/file
         racket/list
         rackunit
         (only-in crypto/libcrypto libcrypto-factory)
         "../hub/verify.rkt")

(crypto-factories (list libcrypto-factory))

(define (hex-of b)
  (define digits "0123456789abcdef")
  (list->string
   (append* (for/list ([x (in-bytes (digest 'sha256 b))])
              (list (string-ref digits (arithmetic-shift x -4))
                    (string-ref digits (bitwise-and x #x0F)))))))

(define root (make-temporary-file "keepsake-verify-~a" 'directory))

(define data #"audited content")
(define hash (hex-of data))
(define blob-dir (build-path root "blobs" "sha256" (substring hash 0 2)))
(make-directory* blob-dir)
(with-output-to-file (build-path blob-dir hash)
  #:exists 'replace (lambda () (write-bytes data)))
(make-directory* (build-path root "devices" "dev" "snapshots"))
(with-output-to-file
    (build-path root "devices" "dev" "snapshots" "20261009T120000.000Z.manifest.json")
  #:exists 'replace
  (lambda ()
    (write-json
     (hasheq 'format_version 1
             'device_id "dev" 'account "a" 'host_platform "darwin"
             'created_at "2026-10-09T12:00:00.000Z"
             'files (list (hasheq 'path "f" 'size (bytes-length data) 'mode 420
                                  'mod_time "2026-10-09T12:00:00.000Z"
                                  'chunks (list (hasheq 'hash hash 'offset 0
                                                        'size (bytes-length data)))))))))

(test-case "healthy repository reports no problems"
  (check-equal? (verify-repo root) (list)))

(test-case "corrupted blob is named"
  (with-output-to-file (build-path blob-dir hash)
    #:exists 'replace (lambda () (write-bytes #"tampered")))
  (define problems (verify-repo root))
  (check-equal? (length problems) 1)
  (check-equal? (hash-ref (car problems) 'kind) "blob-corrupt"))

(test-case "missing blob is named"
  (delete-file (build-path blob-dir hash))
  (define problems (verify-repo root))
  (check-equal? (length problems) 1)
  (check-equal? (hash-ref (car problems) 'kind) "blob-missing"))
