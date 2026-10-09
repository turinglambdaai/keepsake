#lang racket/base

;; Turns a WeChat account directory into a repository snapshot:
;; walk → chunk → upload missing blobs → write the manifest.

(require racket/contract
         racket/date
         racket/file
         racket/format
         racket/list
         racket/path
         racket/port
         racket/string
         "chunk.rkt"
         "discover.rkt"
         "format.rkt"
         "manifest.rkt"
         "repo.rkt")

(provide (contract-out
          [snapshot-run (-> repo? account? string? (values manifest? hash?))]
          [walk-files (-> path-string? (listof path?))]))

;; current-seconds → ISO 8601 UTC with milliseconds.
(define (now-iso [sec (current-seconds)])
  (define d (seconds->date sec #t))
  (define (~2 n) (~r n #:min-width 2 #:pad-string "0"))
  (format "~a-~a-~aT~a:~a:~a.000Z"
          (date-year d) (~2 (date-month d)) (~2 (date-day d))
          (~2 (date-hour d)) (~2 (date-minute d)) (~2 (date-second d))))

;; All regular files under dir, never following symlinks (WeChat data has
;; none in practice, and following them risks loops and escaping the
;; account directory).
(define (walk-files dir)
  (append*
   (for/list ([e (in-list (directory-list dir))])
     (define p (build-path dir e))
     (cond
       [(link-exists? p) '()]
       [(directory-exists? p) (walk-files p)]
       [(file-exists? p) (list p)]
       [else '()]))))

(define (to-slash-rel base p)
  (string-replace (path->string (find-relative-path base p)) "\\" "/"))

;; (snapshot-run repo account device-id) → (values manifest stats)
;; stats: (hasheq 'files 'total-bytes 'uploaded-blobs 'uploaded-bytes
;;                 'deduped-blobs 'deduped-bytes) — the numbers that make
;; incremental behavior visible to the user.
(define (snapshot-run repo account device-id)
  (define acc-dir (simple-form-path (hash-ref account 'path)))
  (define files (walk-files acc-dir))
  (define entries '())
  (define stats
    (hasheq 'files 0 'total-bytes 0
            'uploaded-blobs 0 'uploaded-bytes 0
            'deduped-blobs 0 'deduped-bytes 0))

  (for ([p (in-list files)])
    (define size (file-size p))
    (define refs (plan-file p))
    (define chunk-list
      (with-input-from-file p
        (lambda ()
          (for/list ([ref (in-list refs)])
            (define h (hash-ref ref 'hash))
            (define off (hash-ref ref 'offset))
            (define n (hash-ref ref 'size))
            (if (repo-has-blob? repo h)
                (begin
                  (set! stats (hash-update stats 'deduped-blobs add1))
                  (set! stats (hash-update stats 'deduped-bytes (lambda (v) (+ v n))))
                  ref)
                (let ([stored (upload-chunk repo p off n)])
                  (unless (string=? stored h)
                    (error 'snapshot-run
                           "chunk hash mismatch for ~a: planned ~a, stored ~a" p h stored))
                  (set! stats (hash-update stats 'uploaded-blobs add1))
                  (set! stats (hash-update stats 'uploaded-bytes (lambda (v) (+ v n))))
                  ref))))
        #:mode 'binary))
    (set! entries
          (cons (hasheq 'path (to-slash-rel acc-dir p)
                        'size size
                        'mode (file-or-directory-permissions p 'bits)
                        'mod_time (now-iso (file-or-directory-modify-seconds p))
                        'chunks chunk-list)
                entries))
    (set! stats (hash-update stats 'files add1))
    (set! stats (hash-update stats 'total-bytes (lambda (v) (+ v size)))))

  (define manifest
    (hasheq 'format_version format-version
            'device_id device-id
            'account (hash-ref account 'id)
            'host_platform (symbol->string (system-type 'os))
            'created_at (now-iso)
            'files (reverse entries)))
  (repo-write-manifest! repo manifest)
  (values manifest stats))

;; Uploads bytes [offset, offset+size) of path as a blob, returning the
;; stored hash.
(define (upload-chunk repo path offset size)
  (define buf
    (with-input-from-file path
      (lambda ()
        (file-position (current-input-port) offset)
        (read-bytes size))
      #:mode 'binary))
  (when (< (bytes-length buf) size)
    (error 'snapshot-run "short read of ~a @~a (~a of ~a bytes)" path offset (bytes-length buf) size))
  (repo-put-blob! repo (open-input-bytes buf)))
