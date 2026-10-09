#lang racket/base

;; Locates local WeChat data directories across platforms. Only the desktop
;; clients matter: the mobile clients keep their data sandboxed by the
;; platform security model and are deliberately out of scope — phone history
;; reaches the desktop through WeChat's own migrate-chat-history flow.

(require racket/contract
         racket/list
         racket/path)

(provide (contract-out
          [account? predicate/c]
          [default-root (-> (or/c path-string? #f))]
          [find-accounts (-> (listof account?))]
          [find-accounts-in (-> path-string? (listof account?))]
          [current-wechat-root (parameter/c (or/c path-string? #f))]))
;; Overrides the platform default root when set (tests, custom locations).
(define current-wechat-root (make-parameter #f))

;; account: (hasheq 'id string 'path string)
(define (account? v)
  (and (hash? v)
       (string? (hash-ref v 'id #f))
       (string? (hash-ref v 'path #f))))

;; The platform's WeChat data root, or #f when none of the known candidates
;; exists on this machine.
(define (default-root)
  (define home (path->string (find-system-path 'home-dir)))
  (define candidates
    (case (system-type 'os)
      [(macosx)
       (list (build-path home
                         "Library" "Containers" "com.tencent.xinWeChat"
                         "Data" "Documents" "xwechat_files"))]
      [(windows)
       (list (build-path home "Documents" "xwechat_files")   ; WeChat 4.x
             (build-path home "Documents" "WeChat Files"))]  ; 3.x legacy
      [(unix)
       (list (build-path home ".xwechat"))]
      [else '()]))
  (for/first ([c (in-list candidates)] #:when (directory-exists? c))
    (path->string c)))

;; Account directories under an explicit root. A directory counts as an
;; account when it contains a db_storage subdirectory (the WeChat 4.x
;; message store); cache clutter never shows up as an account. A root that
;; does not exist simply yields no accounts. A TCC denial (macOS without
;; Full Disk Access) becomes an actionable error instead of a bare errno.
(define (find-accounts-in root)
  (define root-path (simple-form-path root))
  (cond
    [(not (directory-exists? root-path)) '()]
    [else
     (define entries
       (with-handlers
           ([exn:fail:filesystem?
             (lambda (e)
               (if (regexp-match? #rx"Operation not permitted|Permission denied"
                                  (exn-message e))
                   (raise-user-error
                    'find-accounts
                    (string-append
                     "macOS blocked access to the WeChat data directory — grant "
                     "Full Disk Access to this app (System Settings → Privacy & "
                     "Security → Full Disk Access), then rescan"))
                   (raise e)))])
         (directory-list root-path)))
     (for/list ([e (in-list entries)]
                #:when (let ([p (build-path root-path e)])
                         (and (directory-exists? p)
                              (directory-exists? (build-path p "db_storage")))))
       (hasheq 'id (path->string e)
               'path (path->string (build-path root-path e))))]))

(define (find-accounts)
  (define root (or (current-wechat-root) (default-root)))
  (if root (find-accounts-in root) '()))
