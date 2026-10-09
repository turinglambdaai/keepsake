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
         "scheduler.rkt"
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
(define-event snapshots-changed : String)

;; ---- state ----

;; Where the repository lives; the hosts set it once at startup.
(define-state repo-root : String
  (path->string (build-path (find-system-path 'home-dir) "KeepsakeBackup")))

;; 0 = auto-snapshot off; otherwise minutes between automatic runs.
(define-state auto-snapshot-minutes : Int64 0)

;; The scheduler thread lives outside the RPC/state machinery, so its view
;; of the interval is a plain box kept in sync by set-auto-snapshot.
(define auto-interval-box (box 0))

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

;; Restores the snapshot at `index` (1-based, as listed by list-snapshots)
;; to target, safety-snapshotting the target first when it is non-empty
;; (same rule as the CLI).
(define-rpc (restore-snapshot [account-id : String] [index : Int64] [target : String] : OperationResult)
  (with-handlers ([exn:fail? (lambda (e) (OperationResult #f (exn-message e)))])
    (define repo (open-or-init-repo))
    (define snaps
      (filter (lambda (m) (string=? (hash-ref m 'account) account-id))
              (repo-snapshots repo (device-name))))
    (unless (and (>= index 1) (<= index (length snaps)))
      (error 'restore-snapshot "index ~a out of range 1..~a" index (length snaps)))
    (define m (list-ref snaps (sub1 index)))
    (define dir-exists (directory-exists? target))
    (define non-empty (and dir-exists (not (null? (directory-list target)))))
    (when non-empty
      (snapshot-run repo (hasheq 'id account-id 'path target) (device-name)))
    (delete-directory/files target #:must-exist? #f)
    (define n (materialize! repo m target))
    (define msg (format "restored snapshot ~a (~a files) to ~a" index n target))
    (notification msg)
    (OperationResult #t msg)))

;; ---- auto snapshot ----

;; Snapshots every discovered account. One failing account must not stop
;; the rest; the summary goes out on the wire so open hosts refresh.
(define (auto-snapshot-all!)
  (define repo (open-or-init-repo))
  (define accounts (find-accounts))
  (define ok-count 0)
  (for ([a (in-list accounts)])
    (with-handlers ([exn:fail? void])
      (snapshot-run repo a (device-name))
      (set! ok-count (add1 ok-count))))
  (when (> ok-count 0)
    (snapshots-changed (format "auto snapshot: ~a account(s)" ok-count))))

(void
 (start-scheduler! (make-scheduler)
                   (lambda () (inexact->exact (* 60 (unbox auto-interval-box))))
                   auto-snapshot-all!))

(define-rpc (set-auto-snapshot [minutes : Int64] : Void)
  (set-box! auto-interval-box minutes)
  (state-set! auto-snapshot-minutes minutes)
  (void))

(define-rpc (get-auto-snapshot : Int64)
  (state-ref auto-snapshot-minutes))

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
