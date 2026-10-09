#lang racket/base

;; End-to-end restore tests: snapshot → destroy/tamper → restore must
;; reproduce byte-identical content; the pre-restore safety snapshot is the
;; CLI's job, but the engine must refuse unsafe manifest paths and verify
;; sizes.

(require racket/date
         racket/file
         racket/path
         rackunit
         "../app/discover.rkt"
         "../app/repo.rkt"
         "../app/restore.rkt"
         "../app/snapshot.rkt")

(define root (make-temporary-file "keepsake-rt-src-~a" 'directory))
(define acc-dir (build-path root "wxid_restore" "db_storage"))
(make-directory* (build-path acc-dir "message"))
(define db (build-path acc-dir "message" "0.db"))
(define data (make-bytes (* 3 4096) 0))
(bytes-copy! data 0 #"SQLite format 3\0")
(bytes-set! data 16 #x10)
(for ([i (in-range 100 (bytes-length data))])
  (bytes-set! data i (remainder i 251)))
(with-output-to-file db #:exists 'replace (lambda () (write-bytes data)))
(with-output-to-file (build-path acc-dir "note.txt")
  #:exists 'replace (lambda () (display "hello keepsake")))

(define account (hasheq 'id "wxid_restore" 'path (path->string acc-dir)))
(define r (repo-init (make-temporary-file "keepsake-rt-repo-~a" 'directory)))
(define-values (m _stats) (snapshot-run r account "dev-r"))

(test-case "restore reproduces a wiped directory byte-for-byte"
  (define target (build-path (make-temporary-file "keepsake-rt-tgt-~a" 'directory) "account"))
  (define n (materialize! r m target))
  (check-equal? n 2)
  (check-equal? (file->bytes (build-path target "message" "0.db")) data)
  (check-equal? (file->string (build-path target "note.txt")) "hello keepsake"))

(test-case "restore overwrites an existing dirty target"
  (define target (build-path (make-temporary-file "keepsake-rt-tgt-~a" 'directory) "account"))
  (make-directory* (build-path target "db_storage"))
  (with-output-to-file (build-path target "db_storage" "garbage.txt")
    #:exists 'replace (lambda () (display "junk")))
  (materialize! r m target)
  (check-equal? (file->bytes (build-path target "message" "0.db")) data)
  (check-false (file-exists? (build-path target "garbage.txt"))))

(test-case "unsafe manifest paths are refused"
  (define bad-m
    (hash-copy m))
  (hash-set! bad-m 'files
             (list (hasheq 'path "../escape.txt" 'size 1 'mode 420
                           'mod_time "2026-10-09T12:00:00.000Z" 'chunks '())))
  (check-exn exn:fail?
             (lambda ()
               (materialize! r bad-m
                             (build-path (make-temporary-file "keepsake-rt-tgt-~a" 'directory) "a")))))

(test-case "restore-plan errors on a missing blob"
  ;; A manifest whose chunk points nowhere: plan must fail, loudly.
  (define fake
    (hash-copy m))
  (hash-set! fake 'files
             (list (hasheq 'path "x.txt" 'size 5 'mode 420
                           'mod_time "2026-10-09T12:00:00.000Z"
                           'chunks (list (hasheq 'hash "0000000000000000000000000000000000000000000000000000000000000000"
                                                 'offset 0 'size 5)))))
  (check-exn exn:fail? (lambda () (restore-plan r fake))))

(test-case "iso->seconds round-trips UTC"
  ;; Reference point: a zero-zone-offset date (true UTC), so this does not
  ;; depend on the CI machine's timezone.
  (define ref (date->seconds (date 20 0 12 9 10 2026 0 0 #f 0)))
  (check-equal? (iso->seconds "2026-10-09T12:00:20.000Z") ref)
  (check-false (iso->seconds "not a date")))
