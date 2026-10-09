#lang racket/base

;; Tests for account discovery: only directories with db_storage count as
;; accounts, clutter is ignored, and a missing root yields no accounts.

(require rackunit
         racket/file
         racket/path
         "../app/discover.rkt")

(test-case "find-accounts-in detects db_storage layout and ignores clutter"
  (define root (make-temporary-file "keepsake-disc-~a" 'directory))
  (make-directory* (build-path root "wxid_abc123" "db_storage" "message"))
  (make-directory* (build-path root "cache"))
  (with-output-to-file (build-path root "stray.txt") #:exists 'replace void)
  (make-directory* (build-path root "all-users"))
  (define accounts (find-accounts-in root))
  (check-equal? (length accounts) 1)
  (check-equal? (hash-ref (car accounts) 'id) "wxid_abc123")
  (check-equal? (hash-ref (car accounts) 'path)
                (path->string (build-path root "wxid_abc123"))))

(test-case "empty root yields no accounts"
  (check-equal? (find-accounts-in (make-temporary-file "keepsake-disc-~a" 'directory)) '()))

(test-case "missing root yields no accounts"
  (check-equal? (find-accounts-in (build-path (make-temporary-file "keepsake-disc-~a" 'directory) "nope")) '()))

(test-case "default-root is #f or a real directory on this machine"
  (define r (default-root))
  (check-true (or (not r) (directory-exists? r))))
