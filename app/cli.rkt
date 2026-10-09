#lang racket/base

;; The keepsake agent CLI: discover / snapshot / status — file-level backup
;; for desktop WeChat data, zero decryption. Runs with `racket app/cli.rkt`
;; today; the packaged binary and native hosts come with the M0 UI shell.

(require racket/file
         racket/format
         racket/list
         racket/os
         racket/path
         racket/port
         racket/string
         "chunk.rkt"
         "discover.rkt"
         "format.rkt"
         "manifest.rkt"
         "repo.rkt"
         "restore.rkt"
         "snapshot.rkt")

(define version "0.0.1")

(define (usage)
  (displayln "keepsake agent — local file-level backup for desktop WeChat data

Usage:
  racket app/cli.rkt discover                      list WeChat accounts on this machine
  racket app/cli.rkt snapshot --repo DIR [--account ID] [--device NAME]
  racket app/cli.rkt status   --repo DIR [--device NAME]
  racket app/cli.rkt restore --repo DIR --list
  racket app/cli.rkt restore --repo DIR --account ID --index N --to DIR [--dry-run]
  racket app/cli.rkt version"))

(define (parse-flags args allowed)
  ;; → (values flags-hash positionals); --name value for valued flags,
  ;; a bare --name (or one followed by another flag) becomes #t.
  (let loop ([args args] [flags (hasheq)] [pos '()])
    (cond
      [(null? args) (values flags (reverse pos))]
      [(and (string-prefix? (car args) "--")
            (member (substring (car args) 2) allowed))
       (define name (string->symbol (substring (car args) 2)))
       (if (and (pair? (cdr args))
                (not (string-prefix? (cadr args) "--")))
           (loop (cddr args) (hash-set flags name (cadr args)) pos)
           (loop (cdr args) (hash-set flags name #t) pos))]
      [else (loop (cdr args) flags (cons (car args) pos))])))

(define (human n)
  (cond
    [(< n 1024) (format "~a B" n)]
    [(< n (expt 1024 2)) (~a (~r (/ n 1024.0) #:precision '(= 1)) " KB")]
    [(< n (expt 1024 3)) (~a (~r (/ n (expt 1024 2)) #:precision '(= 1)) " MB")]
    [(< n (expt 1024 4)) (~a (~r (/ n (expt 1024 3)) #:precision '(= 1)) " GB")]
    [else (~a (~r (/ n (expt 1024 4)) #:precision '(= 1)) " TB")]))

(define (dir-size root)
  (for/sum ([p (in-list (walk-files root))]) (file-size p)))

(define (require-repo flags)
  (define repo-dir (hash-ref flags 'repo #f))
  (unless repo-dir (raise-user-error "snapshot/status" "--repo is required"))
  (repo-init repo-dir))

(define (default-device-name)
  (or (getenv "KEEPSAKE_DEVICE")
      (with-handlers ([exn:fail? (lambda (_) #f)]) (gethostname))
      "unknown"))

(define (cmd-discover)
  (define accounts (find-accounts))
  (cond
    [(null? accounts) (displayln "no WeChat account directories found")]
    [else
     (for ([a (in-list accounts)])
       (define size (dir-size (hash-ref a 'path)))
       (printf "~a\t~a\t~a\n" (hash-ref a 'id) (human size) (hash-ref a 'path)))]))

(define (cmd-snapshot args)
  (define-values (flags _) (parse-flags args '("repo" "account" "device")))
  (define repo (require-repo flags))
  (define accounts (find-accounts))
  (when (null? accounts) (raise-user-error "snapshot" "no WeChat accounts found"))
  (define selected
    (if (hash-ref flags 'account #f)
        (filter (lambda (a) (string=? (hash-ref a 'id) (hash-ref flags 'account)))
                accounts)
        accounts))
  (when (null? selected)
    (raise-user-error "snapshot" "account ~a not found; run discover first" (hash-ref flags 'account)))
  (define device (or (hash-ref flags 'device #f) (default-device-name)))
  (for ([a (in-list selected)])
    (define-values (m stats) (snapshot-run repo a device))
    (printf "snapshot ~a @ ~a\n" (hash-ref a 'id) (hash-ref m 'created_at))
    (for ([k (in-list '(files total-bytes uploaded-blobs uploaded-bytes deduped-blobs deduped-bytes))])
      (printf "  ~a: ~a\n" k (hash-ref stats k)))))

(define (cmd-status args)
  (define-values (flags _) (parse-flags args '("repo" "device")))
  (unless (hash-ref flags 'repo #f)
    (raise-user-error "status" "--repo is required"))
  (define repo (repo-open (hash-ref flags 'repo)))
  (define devices
    (if (hash-ref flags 'device #f)
        (list (hash-ref flags 'device))
        (map path->string (directory-list (build-path (repo-root repo) "devices")))))
  (for ([d (in-list devices)])
    (for ([m (in-list (repo-snapshots repo d))])
      (printf "~a\t~a\t~a\t~a\t~a\n"
              d
              (hash-ref m 'created_at)
              (hash-ref m 'account)
              (length (hash-ref m 'files))
              (human (manifest-total-size m))))))

;; plan + total in one pass for the CLI summary.
(define (restore-plan/with-stats repo m)
  (define plan (restore-plan repo m))
  (values plan (for/sum ([p (in-list plan)]) (cadr p))))

(define (cmd-restore args)
  (define-values (flags _) (parse-flags args '("repo" "account" "device" "index" "to" "list" "dry-run")))
  (unless (hash-ref flags 'repo #f)
    (raise-user-error "restore" "--repo is required"))
  (define repo (repo-open (hash-ref flags 'repo)))
  (define device (or (hash-ref flags 'device #f) (default-device-name)))
  (define snaps (repo-snapshots repo device))
  (when (null? snaps)
    (raise-user-error "restore" "no snapshots for device ~a" device))

  (cond
    ;; Listing mode: index + timestamp + size, oldest first.
    [(hash-ref flags 'list #f)
     (for ([m (in-list snaps)] [i (in-naturals 1)])
       (printf "~a\t~a\t~a\t~a files\t~a\n"
               i (hash-ref m 'created_at) (hash-ref m 'account)
               (length (hash-ref m 'files)) (human (manifest-total-size m))))]

    [else
     (define account-id (hash-ref flags 'account #f))
     (define index-str (hash-ref flags 'index #f))
     (define target (hash-ref flags 'to #f))
     (unless (and account-id index-str target)
       (raise-user-error "restore" "--account, --index and --to are required (or use --list)"))
     (define idx (string->number index-str))
     (unless (and idx (>= idx 1) (<= idx (length snaps)))
       (raise-user-error "restore" "--index must be between 1 and ~a (see --list)" (length snaps)))
     (define m (list-ref snaps (sub1 idx)))
     (unless (string=? (hash-ref m 'account) account-id)
       (raise-user-error "restore" "snapshot ~a belongs to account ~a, not ~a"
                         index-str (hash-ref m 'account) account-id))

     (define plan (restore-plan repo m))
     (define total (for/sum ([p (in-list plan)]) (cadr p)))
     (cond
       [(hash-ref flags 'dry-run #f)
        (printf "dry run: ~a files, ~a bytes would be restored to ~a\n"
                (length plan) total target)]
       [else
        ;; Safety first: the current contents of the target are snapshotted
        ;; into the same repository before anything is cleared.
        (when (and (directory-exists? target)
                   (not (null? (directory-list target))))
          (define-values (_s sstats)
            (snapshot-run repo (hasheq 'id account-id 'path target) device))
          (printf "safety snapshot: ~a files, ~a bytes captured before restore\n"
                  (hash-ref sstats 'files) (hash-ref sstats 'total-bytes)))
        (delete-directory/files target #:must-exist? #f)
        (define n (materialize! repo m target))
        (printf "restored ~a files (~a) to ~a\nopen WeChat and verify your history is back.\n"
                n (human total) target)])]))

(module+ main
  (define args (current-command-line-arguments))
  (define cmd (if (zero? (vector-length args)) #f (vector-ref args 0)))
  (define rest
    (if cmd (for/list ([i (in-range 1 (vector-length args))]) (vector-ref args i)) '()))
  (case cmd
    [("discover") (cmd-discover)]
    [("snapshot") (cmd-snapshot rest)]
    [("status") (cmd-status rest)]
    [("restore") (cmd-restore rest)]
    [("version") (printf "keepsake agent ~a\n" version)]
    [else (usage) (exit 2)]))
