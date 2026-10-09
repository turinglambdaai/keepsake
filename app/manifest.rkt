#lang racket/base

;; Snapshot manifests: the file-tree contract between a snapshot and the
;; blobs stored in a repository (docs/repo-format.md). Kept as plain jsexpr
;; with helpers, so the JSON on disk stays the single source of truth.

(require racket/contract
         racket/file
         racket/list
         racket/path
         racket/string
         json
         "format.rkt")

(provide (contract-out
          [file-entry? predicate/c]
          [manifest? predicate/c]
          [manifest->jsexpr (-> manifest? jsexpr?)]
          [jsexpr->manifest (-> jsexpr? (or/c manifest? #f))]
          [write-manifest (-> path-string? manifest? void?)]
          [read-manifest (-> path-string? manifest?)]
          [manifest-total-size (-> manifest? exact-integer?)]
          [manifest-filename (-> string? string?)]))

;; A manifest is a hash with validated shape; JSON stays the authority.
(define (chunk-ref? v)
  (and (hash? v)
       (string? (hash-ref v 'hash #f))
       (exact-integer? (hash-ref v 'offset #f))
       (exact-integer? (hash-ref v 'size #f))
       (>= (hash-ref v 'size 0) 0)))

(define (file-entry? v)
  (and (hash? v)
       (string? (hash-ref v 'path #f))
       (exact-integer? (hash-ref v 'size #f))
       (exact-integer? (hash-ref v 'mode #f))
       (string? (hash-ref v 'mod_time #f))
       (list? (hash-ref v 'chunks #f))
       (andmap chunk-ref? (hash-ref v 'chunks '()))))

(define (manifest? v)
  (and (hash? v)
       (equal? (hash-ref v 'format_version #f) format-version)
       (string? (hash-ref v 'device_id #f))
       (string? (hash-ref v 'account #f))
       (string? (hash-ref v 'host_platform #f))
       (string? (hash-ref v 'created_at #f))
       (list? (hash-ref v 'files #f))
       (andmap file-entry? (hash-ref v 'files '()))))

(define (manifest->jsexpr m) m)

(define (jsexpr->manifest v)
  (and (manifest? v) v))

;; Atomic JSON write: temp file in the same directory, then rename, so a
;; concurrent reader never observes a half-written manifest.
(define (write-manifest path m)
  (define dir (path-only path))
  (define tmp (make-temporary-file "keepsake-tmp-~a" #f dir))
  (with-output-to-file tmp
    #:exists 'truncate
    (lambda () (write-json m)))
  (rename-file-or-directory tmp path #f))

(define (read-manifest path)
  (jsexpr->manifest
   (with-input-from-file path read-json)))

(define (manifest-total-size m)
  (for/sum ([f (in-list (hash-ref m 'files))]) (hash-ref f 'size)))

;; "2026-10-09T12:00:00.000Z" → "20261009T120000.000Z.manifest.json"
;; (millisecond-precision UTC name so directory listings sort chronologically
;; by name alone)
(define (manifest-filename created-at-iso)
  (string-append
   (string-replace (string-replace created-at-iso "-" "") ":" "")
   manifest-suffix))
