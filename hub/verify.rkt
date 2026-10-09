#lang racket/base

;; Repository health audit: every manifest must parse into a valid-shaped
;; value, and every referenced blob must exist with a sha256 equal to its
;; name. Returns a list of problems (empty = healthy); designed for a cron
;; job inside the hub container or a manual run against a local volume.

(require crypto
         crypto/libcrypto
         json
         racket/contract
         racket/file
         racket/list
         racket/path
         racket/port
         racket/string
         "../app/format.rkt")

(crypto-factories (list libcrypto-factory))

(provide (contract-out
          [verify-repo (-> path-string? (listof (hash/c symbol? string?)))]))

(define (manifest-paths root)
  (define dev-dir (build-path root "devices"))
  (if (directory-exists? dev-dir)
      (for*/list ([dev (in-list (directory-list dev-dir))]
                  [f (in-list (let ([dir (build-path dev-dir dev "snapshots")])
                                (if (directory-exists? dir)
                                    (directory-list dir)
                                    (list))))]
                  #:when (string-suffix? (path->string f) manifest-suffix))
        (build-path dev-dir dev "snapshots" f))
      (list)))

(define (blob-paths root)
  (define blobs (build-path root "blobs" "sha256"))
  (if (directory-exists? blobs)
      (for*/list ([shard (in-list (directory-list blobs))]
                  #:when (directory-exists? (build-path blobs shard))
                  [f (in-list (directory-list (build-path blobs shard)))])
        (build-path blobs shard f))
      (list)))

(define (hex-of b)
  (define digest-bytes (digest 'sha256 b))
  (define digits "0123456789abcdef")
  (list->string
   (append* (for/list ([x (in-bytes digest-bytes)])
              (list (string-ref digits (arithmetic-shift x -4))
                    (string-ref digits (bitwise-and x #x0F)))))))

;; Returns problem entries: (hasheq 'kind 'what 'detail string).
(define (verify-repo root)
  (define problems (list))

  (define (problem! kind detail)
    (set! problems (cons (hasheq 'kind kind 'detail detail) problems)))

  ;; manifests parse
  (for ([mp (in-list (manifest-paths root))])
    (with-handlers ([exn:fail? (lambda (e)
                                 (problem! "manifest-unreadable"
                                           (format "~a: ~a" mp (exn-message e))))])
      (with-input-from-file mp read-json)))

  ;; every referenced blob exists and hashes to its name
  (define referenced
    (remove-duplicates
     (append*
      (for/list ([mp (in-list (manifest-paths root))])
        (define m
          (with-handlers ([exn:fail? (lambda (_) #f)])
            (with-input-from-file mp read-json)))
        (if (hash? m)
            (for*/list ([f (in-list (hash-ref m 'files (list)))]
                        [c (in-list (hash-ref f 'chunks (list)))])
              (cons (hash-ref c 'hash) (hash-ref f 'path "manifest entry")))
            (list))))))
  (for ([pair (in-list referenced)])
    (define hash (car pair))
    (define p (build-path root "blobs" "sha256" (substring hash 0 2) hash))
    (cond
      [(not (file-exists? p))
       (problem! "blob-missing" (format "~a referenced but absent" hash))]
      [else
       (define actual (hex-of (call-with-input-file p port->bytes #:mode 'binary)))
       (unless (string=? actual hash)
         (problem! "blob-corrupt"
                   (format "~a hashes to ~a" hash actual)))]))

  (reverse problems))
