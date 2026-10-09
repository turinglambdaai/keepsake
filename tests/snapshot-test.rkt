#lang racket/base

;; End-to-end tests for the snapshot engine: full first snapshot, zero-upload
;; rerun, one-page edit uploading exactly one page, and symlink skipping.

(require rackunit
         racket/file
         racket/path
         "../app/discover.rkt"
         "../app/repo.rkt"
         "../app/snapshot.rkt")

(define (make-sqlite! path pages)
  (make-directory* (path-only path))
  (define data (make-bytes (* pages 4096) 0))
  (bytes-copy! data 0 #"SQLite format 3\0")
  (bytes-set! data 16 #x10) ; page size 4096, big-endian high byte
  (for ([i (in-range 100 (bytes-length data))])
    (bytes-set! data i (remainder i 251))) ; distinct pages, no accidental dedupe
  (with-output-to-file path #:exists 'replace (lambda () (write-bytes data))))

(define root (make-temporary-file "keepsake-src-~a" 'directory))
(define acc-dir (build-path root "wxid_test" "db_storage"))
(make-sqlite! (build-path acc-dir "message" "0.db") 4)
(with-output-to-file (build-path acc-dir "note.txt")
  #:exists 'replace (lambda () (display "hello")))

(define account (hasheq 'id "wxid_test" 'path (path->string acc-dir)))
(define r (repo-init (make-temporary-file "keepsake-repo-~a" 'directory)))

(test-case "first snapshot uploads everything and writes a manifest"
  (define-values (m stats) (snapshot-run r account "dev-a"))
  (check-equal? (hash-ref stats 'files) 2)
  (check-equal? (hash-ref stats 'deduped-blobs) 0)
  (check-true (> (hash-ref stats 'uploaded-blobs) 0))
  (check-equal? (hash-ref m 'device_id) "dev-a")
  (check-equal? (hash-ref m 'account) "wxid_test")
  (check-equal? (length (hash-ref m 'files)) 2)
  ;; every file entry's chunks cover its size
  (for ([f (in-list (hash-ref m 'files))])
    (check-equal? (for/sum ([c (in-list (hash-ref f 'chunks))]) (hash-ref c 'size))
                  (hash-ref f 'size))))

(test-case "unchanged rerun dedupes everything"
  (define-values (_ stats) (snapshot-run r account "dev-a"))
  (check-equal? (hash-ref stats 'uploaded-blobs) 0)
  (check-true (> (hash-ref stats 'deduped-blobs) 0))
  (check-equal? (hash-ref stats 'deduped-bytes) (hash-ref stats 'total-bytes)))

(test-case "one-page edit uploads exactly one page"
  (define db (build-path acc-dir "message" "0.db"))
  (define data (file->bytes db))
  (bytes-set! data 100 (bitwise-xor (bytes-ref data 100) #xFF))
  (with-output-to-file db #:exists 'replace (lambda () (write-bytes data)))
  (define-values (_ stats) (snapshot-run r account "dev-a"))
  (check-equal? (hash-ref stats 'uploaded-blobs) 1)
  (check-equal? (hash-ref stats 'uploaded-bytes) 4096)
  (check-equal? (length (repo-snapshots r "dev-a")) 3))

(test-case "symlinks are skipped"
  (define link (build-path acc-dir "sneaky-link"))
  (with-handlers ([exn:fail? (lambda (_) (void))])
    (make-file-or-directory-link (build-path root "outside") link))
  (define-values (m stats) (snapshot-run r account "dev-a"))
  (check-equal? (hash-ref stats 'files) 2)
  (check-false
   (for/or ([f (in-list (hash-ref m 'files))])
     (string=? (hash-ref f 'path) "db_storage/sneaky-link"))))
