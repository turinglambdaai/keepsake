#lang racket/base

;; Tests for the repository: init idempotence, open refusal, blob dedupe,
;; manifest write/list ordering, and device-id traversal containment.

(require json
         racket/file
         racket/format
         rackunit
         racket/path
         "../app/format.rkt"
         "../app/manifest.rkt"
         "../app/repo.rkt")

(define temp-root (make-temporary-file "keepsake-repo-~a" 'directory))

(test-case "init is idempotent and marks the directory"
  (define r (repo-init temp-root))
  (define r2 (repo-init temp-root))
  (check-equal? (repo-root r) (repo-root r2))
  (check-true (file-exists? (build-path temp-root "repo.json")))
  (define marker (call-with-input-file (build-path temp-root "repo.json") read-json))
  (check-equal? (hash-ref marker 'format_version) format-version))

(test-case "open refuses a plain directory"
  (check-exn exn:fail? (lambda () (repo-open (make-temporary-file "keepsake-notrepo-~a" 'directory)))))

(test-case "put-blob dedupes identical content"
  (define r (repo-init (make-temporary-file "keepsake-repo-~a" 'directory)))
  (define h1 (repo-put-blob! r (open-input-bytes #"the same chunk, twice")))
  (define h2 (repo-put-blob! r (open-input-bytes #"the same chunk, twice")))
  (check-equal? h1 h2)
  (check-true (repo-has-blob? r h1))
  (check-false (repo-has-blob? r "deadbeef"))
  ;; exactly one blob file exists for that content
  (define shard (build-path (repo-root r) "blobs" "sha256" (substring h1 0 2)))
  (check-equal? (length (directory-list shard)) 1))

(test-case "manifests list oldest-first per device"
  (define r (repo-init (make-temporary-file "keepsake-repo-~a" 'directory)))
  (define (mk i minute)
    (hasheq 'format_version format-version
            'device_id "mac-mini"
            'account "wxid_test"
            'host_platform "darwin"
            'created_at (format "2026-10-09T12:~a:00.000Z" (~r minute #:min-width 2 #:pad-string "0"))
            'files (list (hasheq 'path (format "f~a" i) 'size i 'mode 420
                                 'mod_time "2026-10-09T12:00:00.000Z" 'chunks '()))))
  (for ([m (in-list (list (mk 0 30) (mk 1 10) (mk 2 20)))])
    (repo-write-manifest! r m))
  (define snaps (repo-snapshots r "mac-mini"))
  (check-equal? (length snaps) 3)
  (check-equal? (map (lambda (m) (hash-ref m 'created_at)) snaps)
                (list "2026-10-09T12:10:00.000Z"
                      "2026-10-09T12:20:00.000Z"
                      "2026-10-09T12:30:00.000Z"))
  (check-equal? (repo-snapshots r "other-box") '()))

(test-case "device id cannot escape devices/"
  (define r (repo-init (make-temporary-file "keepsake-repo-~a" 'directory)))
  (repo-write-manifest!
   r (hasheq 'format_version format-version
             'device_id "../../escape"
             'account "a"
             'host_platform "darwin"
             'created_at "2026-10-09T12:00:00.000Z"
             'files '()))
  (check-false (directory-exists? (build-path (repo-root r) "escape"))))

(test-case "manifest-filename normalizes ISO to sortable name"
  (check-equal? (manifest-filename "2026-10-09T12:30:00.000Z")
                "20261009T123000.000Z.manifest.json"))
