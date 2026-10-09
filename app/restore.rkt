#lang racket/base

;; Materializes a snapshot manifest back into a directory. Two-phase by
;; design: verify every blob exists and matches its declared size BEFORE
;; touching the target, then clear the target and write. A restore that
;; fails mid-flight should be impossible; the caller's pre-restore safety
;; snapshot is the second belt.

(require racket/contract
         racket/date
         racket/file
         racket/list
         racket/path
         racket/port
         racket/string
         "chunk.rkt"
         "format.rkt"
         "manifest.rkt"
         "repo.rkt")

(provide (contract-out
          [safe-rel? (-> string? boolean?)]
          [iso->seconds (-> string? (or/c exact-integer? #f))]
          [restore-plan (-> repo? manifest? (listof (list/c string? exact-integer?)))]
          [materialize! (-> repo? manifest? path-string? exact-nonnegative-integer?)]))

;; Manifest paths must stay inside the target directory: relative, forward
;; slashes only, no ".." segments, no drive letters.
(define (safe-rel? rel)
  (and (non-empty-string? rel)
       (not (string-prefix? rel "/"))
       (not (string-contains? rel "\\"))
       (not (regexp-match? #rx"^[A-Za-z]:" rel))
       (not (member ".." (string-split rel "/")))))

;; "2026-10-09T12:00:00.000Z" → UTC seconds, or #f when unparsable.
;; Racket 9.3's find-seconds only reads local wall time, so evaluate the
;; wall clock in the local zone and subtract that instant's zone offset.
(define (iso->seconds iso)
  (define m (regexp-match #px"^(\\d{4})-(\\d{2})-(\\d{2})T(\\d{2}):(\\d{2}):(\\d{2})" iso))
  (and m
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (define local
           (find-seconds (string->number (list-ref m 6))
                         (string->number (list-ref m 5))
                         (string->number (list-ref m 4))
                         (string->number (list-ref m 3))
                         (string->number (list-ref m 2))
                         (string->number (list-ref m 1))
                         #f))
         (- local (date-time-zone-offset (seconds->date local))))))

;; Pre-flight: the files the restore will write (path + size), and an error
;; naming the first missing or wrong-sized blob, if any. Runs before the
;; target is touched.
(define (restore-plan repo m)
  (for/list ([f (in-list (hash-ref m 'files))])
    (define rel (hash-ref f 'path))
    (unless (safe-rel? rel)
      (error 'restore-plan "unsafe path in manifest: ~a" rel))
    (for ([ref (in-list (hash-ref f 'chunks))])
      (define h (hash-ref ref 'hash))
      (unless (repo-has-blob? repo h)
        (error 'restore-plan "missing blob ~a for ~a — repository incomplete" h rel))
      ;; fs knows sizes cheaply; hub defers to materialize's per-chunk check
      (define actual (repo-blob-size repo h))
      (when (and actual (not (= actual (hash-ref ref 'size))))
        (error 'restore-plan "blob ~a is ~a bytes, manifest says ~a" h actual (hash-ref ref 'size))))
    (list rel (hash-ref f 'size))))

;; Writes every file of the manifest under target. The caller is responsible
;; for the pre-restore safety snapshot and for clearing the target first;
;; this function only materializes (creating target when missing).
(define (materialize! repo m target)
  (define root (simple-form-path target))
  (make-directory* root)
  (for/fold ([count 0])
            ([f (in-list (hash-ref m 'files))])
    (define rel (hash-ref f 'path))
    (unless (safe-rel? rel)
      (error 'materialize! "unsafe path in manifest: ~a" rel))
    (define dest (build-path root (string->path rel)))
    (make-directory* (path-only dest))
    (call-with-output-file dest
      (lambda (out)
        (for ([ref (in-list (hash-ref f 'chunks))])
          (define in (repo-read-blob repo (hash-ref ref 'hash)))
          (copy-port in out)
          (close-input-port in))
        (void))
      #:mode 'binary
      #:exists 'truncate)
    ;; Best-effort metadata restore; content is what matters.
    (with-handlers ([exn:fail? (lambda (_) (void))])
      (file-or-directory-permissions dest (hash-ref f 'mode)))
    (with-handlers ([exn:fail? (lambda (_) (void))])
      (define sec (iso->seconds (hash-ref f 'mod_time)))
      (when sec (file-or-directory-modify-seconds dest sec)))
    ;; Trust, then verify: written size must match the manifest.
    (define written (file-size dest))
    (unless (= written (hash-ref f 'size))
      (error 'materialize! "~a restored to ~a bytes, manifest says ~a" rel written (hash-ref f 'size)))
    (add1 count)))
