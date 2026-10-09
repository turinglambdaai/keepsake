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
         "snapshot.rkt")

(define version "0.0.1")

(define (usage)
  (displayln "keepsake agent — local file-level backup for desktop WeChat data

Usage:
  racket app/cli.rkt discover                      list WeChat accounts on this machine
  racket app/cli.rkt snapshot --repo DIR [--account ID] [--device NAME]
  racket app/cli.rkt status   --repo DIR [--device NAME]
  racket app/cli.rkt restore                       (not implemented yet)
  racket app/cli.rkt version"))

(define (parse-flags args allowed)
  ;; → (values flags-hash positionals); flags are --name value
  (let loop ([args args] [flags (hasheq)] [pos '()])
    (cond
      [(null? args) (values flags (reverse pos))]
      [(and (string-prefix? (car args) "--")
            (member (substring (car args) 2) allowed)
            (pair? (cdr args)))
       (loop (cddr args)
             (hash-set flags (string->symbol (substring (car args) 2)) (cadr args))
             pos)]
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

(module+ main
  (define args (current-command-line-arguments))
  (define cmd (if (zero? (vector-length args)) #f (vector-ref args 0)))
  (define rest
    (if cmd (for/list ([i (in-range 1 (vector-length args))]) (vector-ref args i)) '()))
  (case cmd
    [("discover") (cmd-discover)]
    [("snapshot") (cmd-snapshot rest)]
    [("status") (cmd-status rest)]
    [("restore") (displayln "restore is not implemented yet (M0 milestone); see docs/repo-format.md")]
    [("version") (printf "keepsake agent ~a\n" version)]
    [else (usage) (exit 2)]))
