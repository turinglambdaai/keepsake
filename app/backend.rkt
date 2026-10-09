#lang racket/base

;; Keepsake backend: serves the backup engine to the native hosts over
;; RVT1. Thin on purpose — every user-visible number comes from the engine
;; modules, and docs/repo-format.md remains the storage contract.

(require rivet/backend
         racket/file
         racket/format
         racket/list
         racket/os
         racket/path
         racket/string
         "discover.rkt"
         "manifest.rkt"
         "repo.rkt"
         "restore.rkt"
         "snapshot.rkt")

(provide start)

;; ---- records ----

(define-record AccountInfo
  ([id : String]
   [path : String]
   [size-label : String]))

(define-record SnapshotInfo
  ([index : Int64]
   [created-at : String]
   [account : String]
   [file-count : Int64]
   [total-label : String]))

(define-record OperationResult
  ([ok : Bool]
   [message : String]))

(define-event notification : String)

;; ---- state ----

;; Where the repository lives; the hosts set it once at startup.
(define-state repo-root : String
  (path->string (build-path (find-system-path 'home-dir) "KeepsakeBackup")))

(define (device-name)
  (with-handlers ([exn:fail? (lambda (_) "unknown")]) (gethostname)))

(define (open-or-init-repo)
  (repo-init (state-ref repo-root)))

(define (find-account account-id)
  (or (findf (lambda (a) (string=? (hash-ref a 'id) account-id)) (find-accounts))
      (error 'backend "account ~a not found on this machine" account-id)))

(define (human n)
  (cond
    [(< n 1024) (format "~a B" n)]
    [(< n (expt 1024 2)) (~a (~r (/ n 1024.0) #:precision '(= 1)) " KB")]
    [(< n (expt 1024 3)) (~a (~r (/ n (expt 1024 2)) #:precision '(= 1)) " MB")]
    [(< n (expt 1024 4)) (~a (~r (/ n (expt 1024 3)) #:precision '(= 1)) " GB")]
    [else (~a (~r (/ n (expt 1024 4)) #:precision '(= 1)) " TB")]))

(define (dir-size root)
  (for/sum ([p (in-list (walk-files root))]) (file-size p)))

;; ---- rpc ----

(define-rpc (set-repository-location [path : String] : Void)
  (state-set! repo-root path)
  (void))

(define-rpc (get-repository-location : String)
  (state-ref repo-root))

(define-rpc (list-accounts : (List AccountInfo))
  (for/list ([a (in-list (find-accounts))])
    (AccountInfo (hash-ref a 'id)
                 (hash-ref a 'path)
                 (human (dir-size (hash-ref a 'path))))))

(define-rpc (run-snapshot [account-id : String] : OperationResult)
  (with-handlers ([exn:fail? (lambda (e) (OperationResult #f (exn-message e)))])
    (define repo (open-or-init-repo))
    (define-values (m s)
      (snapshot-run repo (find-account account-id) (device-name)))
    (define msg
      (format "~a files · ~a total · ~a new, ~a reused"
              (hash-ref s 'files)
              (human (hash-ref s 'total-bytes))
              (human (hash-ref s 'uploaded-bytes))
              (human (hash-ref s 'deduped-bytes))))
    (notification msg)
    (OperationResult #t msg)))

(define-rpc (list-snapshots [account-id : String] : (List SnapshotInfo))
  (define repo (open-or-init-repo))
  (for/list ([m (in-list (repo-snapshots repo (device-name)))]
             [i (in-naturals 1)]
             #:when (string=? (hash-ref m 'account) account-id))
    (SnapshotInfo i
                  (hash-ref m 'created_at)
                  account-id
                  (length (hash-ref m 'files))
                  (human (manifest-total-size m)))))

;; Restores the newest snapshot for the account to target, safety-snapshotting
;; the target first when it is non-empty (same rule as the CLI).
(define-rpc (restore-latest [account-id : String] [target : String] : OperationResult)
  (with-handlers ([exn:fail? (lambda (e) (OperationResult #f (exn-message e)))])
    (define repo (open-or-init-repo))
    (define snaps
      (filter (lambda (m) (string=? (hash-ref m 'account) account-id))
              (repo-snapshots repo (device-name))))
    (when (null? snaps)
      (error 'restore-latest "no snapshots for ~a" account-id))
    (define m (last snaps))
    (define dir-exists (directory-exists? target))
    (define non-empty (and dir-exists (not (null? (directory-list target)))))
    (when non-empty
      (snapshot-run repo (hasheq 'id account-id 'path target) (device-name)))
    (delete-directory/files target #:must-exist? #f)
    (define n (materialize! repo m target))
    (define msg (format "restored ~a files to ~a" n target))
    (notification msg)
    (OperationResult #t msg)))

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
