#lang racket/base

;; The keepsake repository: a self-describing, content-addressed directory
;; tree that can live on an APFS volume, an SMB mount, or inside a hub
;; container volume. Layout and rules are specified in docs/repo-format.md;
;; this module and the doc move together.

(require crypto
         crypto/libcrypto
         json
         racket/contract
         racket/date
         racket/file
         racket/format
         racket/list
         racket/path
         racket/port
         racket/string
         "format.rkt"
         "manifest.rkt")

;; The libcrypto factory backs the incremental digest in repo-put-blob!.
(crypto-factories (list libcrypto-factory))

(provide (contract-out
          [repo? predicate/c]
          [repo-init (-> path-string? repo?)]
          [repo-open (-> path-string? repo?)]
          [repo-root (-> repo? path-string?)]
          [repo-has-blob? (-> repo? string? boolean?)]
          [repo-put-blob! (-> repo? input-port? string?)]
          [repo-write-manifest! (-> repo? manifest? void?)]
          [repo-snapshots (-> repo? string? (listof manifest?))]))

;; current-seconds → "2026-10-09T12:00:00.000Z"
(define (now-iso [sec (current-seconds)])
  (define d (seconds->date sec #t)) ; UTC
  (define (~2 n) (~r n #:min-width 2 #:pad-string "0"))
  (format "~a-~a-~aT~a:~a:~a.000Z"
          (date-year d) (~2 (date-month d)) (~2 (date-day d))
          (~2 (date-hour d)) (~2 (date-minute d)) (~2 (date-second d))))

;; repo: (hasheq 'root string)
(define (repo? v)
  (and (hash? v) (string? (hash-ref v 'root #f))))

;; Atomic JSON write: temp file in the target directory, then rename.
(define (write-json-atomic path v)
  (define tmp (make-temporary-file "keepsake-tmp-~a" #f (path-only path)))
  (with-output-to-file tmp
    #:exists 'truncate
    (lambda () (write-json v)))
  (rename-file-or-directory tmp path #f))

;; Keep device ids from escaping the devices/ directory.
(define (sanitize device-id)
  (define cleaned
    (string-replace
     (string-replace (string-replace device-id ".." "__") "/" "-")
     "\\" "-"))
  (if (non-empty-string? cleaned) cleaned "unknown"))

(define (marker-path root) (build-path root marker-name))

;; Creates the repository at root (idempotent).
(define (repo-init root)
  (define blobs (build-path root "blobs" "sha256"))
  (make-directory* blobs)
  (make-directory* (build-path root "devices"))
  (unless (file-exists? (marker-path root))
    (write-json-atomic (marker-path root)
                       (hasheq 'format_version format-version
                               'created_at (now-iso))))
  (repo-open root))

;; Opens an existing repository; refuses directories without a marker and
;; repositories written by a newer format version.
(define (repo-open root)
  (define marker
    (with-handlers ([exn:fail:filesystem? (lambda (_)
                                            (error 'repo-open "~a is not a keepsake repository (no ~a)" root marker-name))])
      (with-input-from-file (marker-path root) read-json)))
  (define version (hash-ref marker 'format_version #f))
  (unless (and (exact-integer? version) (<= version format-version))
    (error 'repo-open "repository at ~a uses unsupported format version ~a" root version))
  (hasheq 'root (path->string (simple-form-path root))))

(define (repo-root repo) (hash-ref repo 'root))

(define (blob-path root hash)
  (build-path root "blobs" "sha256" (substring hash 0 2) hash))

(define (repo-has-blob? repo hash)
  (file-exists? (blob-path (repo-root repo) hash)))

;; Streams data into the blob store and returns its sha256 hex hash.
;; Content-addressed and idempotent: chunks already present are left alone.
(define (repo-put-blob! repo in)
  (define root (repo-root repo))
  (define tmp (make-temporary-file "keepsake-incoming-~a" #f (build-path root "blobs" "sha256")))
  (define hash
    (call-with-output-file tmp
      (lambda (out)
        (define ctx (make-digest-ctx 'sha256))
        (let loop ()
          (define buf (read-bytes (* 64 1024) in))
          (unless (eof-object? buf)
            (write-bytes buf out)
            (digest-update ctx buf)
            (loop)))
        (digest-final ctx))
      #:mode 'binary
      #:exists 'truncate))
  (define hex (bytes->hex-string hash))
  (define dst (blob-path root hex))
  (unless (file-exists? dst)
    (make-directory* (path-only dst))
    (rename-file-or-directory tmp dst #f))
  (when (file-exists? tmp) (delete-file tmp))
  hex)

(define (repo-write-manifest! repo m)
  (define device-id (sanitize (hash-ref m 'device_id)))
  (define dir (build-path (repo-root repo) "devices" device-id "snapshots"))
  (make-directory* dir)
  ;; Snapshots can land within the same millisecond; the manifest content
  ;; keeps the true timestamp while the filename gets a -2/-3 suffix so it
  ;; still sorts right after its same-millisecond sibling.
  (define base (manifest-filename (hash-ref m 'created_at)))
  (define path
    (let loop ([n 0])
      (define name
        (if (zero? n)
            base
            (string-replace base ".manifest.json" (format "-~a.manifest.json" n))))
      (define p (build-path dir name))
      (if (file-exists? p) (loop (add1 n)) p)))
  (write-json-atomic path m))

;; All manifests for a device, oldest first (filenames sort chronologically).
(define (repo-snapshots repo device-id)
  (define dir (build-path (repo-root repo) "devices" (sanitize device-id) "snapshots"))
  (if (directory-exists? dir)
      (sort
       (for/list ([f (in-list (directory-list dir))]
                  #:when (string-suffix? (path->string f) manifest-suffix))
         (call-with-input-file (build-path dir f) read-json))
       string<?
       #:key (lambda (m) (hash-ref m 'created_at)))
      '()))
