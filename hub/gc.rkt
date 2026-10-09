#lang racket/base

;; Garbage collection for a keepsake repository: mark every blob referenced
;; by any manifest, then sweep unreferenced blobs whose modification time is
;; older than the grace window. The grace window protects blobs that an
;; agent has just uploaded but not yet referenced (its manifest lands after
;; the blobs do).

(require json
         racket/contract
         racket/file
         racket/list
         racket/path
         racket/set
         racket/string
         "../app/format.rkt")

(provide (contract-out
          [referenced-hashes (-> path-string? (listof string?))]
          [all-blob-paths (-> path-string? (listof path?))]
          [gc-repo! (-> path-string? exact-nonnegative-integer?
                        (listof (list/c path? exact-nonnegative-integer?)))]))

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

;; Every blob hash named by any manifest on disk.
(define (referenced-hashes root)
  (remove-duplicates
   (append*
    (for/list ([mp (in-list (manifest-paths root))])
      (define m
        (with-handlers ([exn:fail? (lambda (_) #f)])
          (with-input-from-file mp read-json)))
      (if (hash? m)
          (for*/list ([f (in-list (hash-ref m 'files (list)))]
                  [c (in-list (hash-ref f 'chunks (list)))])
        (hash-ref c 'hash))
          (list))))))

(define (all-blob-paths root)
  (define blobs (build-path root "blobs" "sha256"))
  (if (directory-exists? blobs)
      (for*/list ([shard (in-list (directory-list blobs))]
                  #:when (directory-exists? (build-path blobs shard))
                  [f (in-list (directory-list (build-path blobs shard)))])
        (build-path blobs shard f))
      (list)))

;; Deletes unreferenced blobs older than grace-seconds; returns what it
;; deleted as (path size) pairs.
(define (gc-repo! root grace-seconds)
  (define referenced (list->set (referenced-hashes root)))
  (define cutoff (- (current-seconds) grace-seconds))
  (for/list ([p (in-list (all-blob-paths root))]
             #:when (let ([name (path->string (file-name-from-path p))])
                      (and (not (set-member? referenced name))
                           (< (file-or-directory-modify-seconds p) cutoff))))
    (define size (file-size p))
    (delete-file p)
    (list p size)))
