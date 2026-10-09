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
         "hub-client.rkt"
         "manifest.rkt")

;; The libcrypto factory backs the incremental digest in repo-put-blob!.
(crypto-factories (list libcrypto-factory))

(provide (contract-out
          [repo? predicate/c]
          [hub-repo? predicate/c]
          [string->repo (->* (path-string?) ((or/c string? #f)) repo?)]
          [repo-init (->* (path-string?) ((or/c string? #f)) repo?)]
          [repo-open (->* (path-string?) ((or/c string? #f)) repo?)]
          [repo-root (-> repo? path-string?)]
          [repo-devices (-> repo? (listof string?))]
          [repo-has-blob? (-> repo? string? boolean?)]
          [repo-blob-path (-> repo? string? path?)]
          [repo-blob-size (-> repo? string? (or/c exact-nonnegative-integer? #f))]
          [repo-read-blob (-> repo? string? input-port?)]
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

;; repo handles: fs = (hasheq 'kind 'fs 'root string)
;;               hub = (hasheq 'kind 'hub 'base string 'token (or/c string? #f))
(define (repo? v)
  (and (hash? v)
       (memq (hash-ref v 'kind #f) '(fs hub))
       (case (hash-ref v 'kind)
         [(fs) (string? (hash-ref v 'root #f))]
         [(hub) (string? (hash-ref v 'base #f))]
         [else #f])))

(define (hub-repo? v)
  (and (repo? v) (equal? (hash-ref v 'kind) 'hub)))

;; "http://nas:8080" → hub handle; anything else → a local directory.
;; Health-checks the hub so a typo'd URL fails at open, not mid-snapshot.
(define (string->repo spec [token (getenv "KEEPSAKE_HUB_TOKEN")])
  (if (regexp-match? #px"^https?://" spec)
      (let ()
        (define health (hub-healthz spec token))
        (unless health
          (error 'string->repo
                 "hub unreachable at ~a (is it running? is KEEPSAKE_HUB_TOKEN right?)" spec))
        (define version (hash-ref health 'format_version #f))
        (unless (and (exact-integer? version) (<= version format-version))
          (error 'string->repo "hub at ~a uses unsupported format version ~a" spec version))
        (hasheq 'kind 'hub 'base spec 'token token))
      (repo-open spec)))

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

;; Creates a local repository at root (idempotent). Hubs manage their own
;; storage; repo-init on a hub spec just health-checks it.
(define (repo-init spec [token (getenv "KEEPSAKE_HUB_TOKEN")])
  (if (regexp-match? #px"^https?://" spec)
      (string->repo spec token)
      (let ()
        (define blobs (build-path spec "blobs" "sha256"))
        (make-directory* blobs)
        (make-directory* (build-path spec "devices"))
        (unless (file-exists? (marker-path spec))
          (write-json-atomic (marker-path spec)
                             (hasheq 'format_version format-version
                                     'created_at (now-iso))))
        (repo-open spec))))

;; Opens an existing local repository; refuses directories without a marker
;; and repositories written by a newer format version.
(define (repo-open spec [token (getenv "KEEPSAKE_HUB_TOKEN")])
  (if (regexp-match? #px"^https?://" spec)
      (string->repo spec token)
      (let ([root spec])
        (define marker
          (with-handlers ([exn:fail:filesystem? (lambda (_)
                                                  (error 'repo-open "~a is not a keepsake repository (no ~a)" root marker-name))])
            (with-input-from-file (marker-path root) read-json)))
        (define version (hash-ref marker 'format_version #f))
        (unless (and (exact-integer? version) (<= version format-version))
          (error 'repo-open "repository at ~a uses unsupported format version ~a" root version))
        (hasheq 'kind 'fs 'root (path->string (simple-form-path root))))))

(define (repo-root repo) (hash-ref repo 'root))

;; Devices present in the repository (the CLI status list).
(define (repo-devices repo)
  (if (hub-repo? repo)
      (hub-list-devices (hash-ref repo 'base) (hash-ref repo 'token))
      (let ([dev-dir (build-path (repo-root repo) "devices")])
        (if (directory-exists? dev-dir)
            (map path->string (directory-list dev-dir))
            '()))))

(define (blob-path root hash)
  (build-path root "blobs" "sha256" (substring hash 0 2) hash))

;; Where a chunk lives inside an fs repository (fs-only callers).
(define (repo-blob-path repo hash)
  (blob-path (repo-root repo) hash))

(define (repo-has-blob? repo hash)
  (if (hub-repo? repo)
      (let-values ([(code _) (hub-request (hash-ref repo 'base)
                                          (hash-ref repo 'token)
                                          "HEAD"
                                          (api-blob-path hash)
                                          #"")])
        (= code 200))
      (file-exists? (blob-path (repo-root repo) hash))))

;; Blob size when the backend can know it cheaply (fs); #f when unknown
;; (hub) — callers then verify sizes at materialization time instead.
(define (repo-blob-size repo hash)
  (if (hub-repo? repo)
      #f
      (with-handlers ([exn:fail:filesystem? (lambda (_) #f)])
        (file-size (blob-path (repo-root repo) hash)))))

;; Opens a stored chunk for reading (both backends).
(define (repo-read-blob repo hash)
  (if (hub-repo? repo)
      (let ()
        (define data (hub-get-blob (hash-ref repo 'base) (hash-ref repo 'token) hash))
        (unless data (error 'repo-read-blob "missing blob ~a" hash))
        (open-input-bytes data))
      (open-input-file (blob-path (repo-root repo) hash))))

(define (api-blob-path hash)
  (string-append "/api/blobs/sha256/" (substring hash 0 2) "/" hash))

;; Streams data into the blob store and returns its sha256 hex hash.
;; Content-addressed and idempotent: chunks already present are left alone.
(define (repo-put-blob! repo in)
  (if (hub-repo? repo)
      (let ()
        (define data (port->bytes in))
        (define hex (bytes->hex-string (digest 'sha256 data)))
        (hub-put-blob (hash-ref repo 'base) (hash-ref repo 'token) hex data)
        hex)
      (let ()
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
        hex)))

(define (repo-write-manifest! repo m)
  (define device-id (sanitize (hash-ref m 'device_id)))
  (define base (manifest-filename (hash-ref m 'created_at)))
  (if (hub-repo? repo)
      ;; The hub owns collision handling; the manifest content keeps the
      ;; true timestamp regardless of the final name it lands under.
      (hub-put-manifest (hash-ref repo 'base) (hash-ref repo 'token)
                        device-id base
                        (string->bytes/utf-8 (jsexpr->string m)))
      (let ()
        (define dir (build-path (repo-root repo) "devices" device-id "snapshots"))
        (make-directory* dir)
        ;; Snapshots can land within the same millisecond; the manifest
        ;; content keeps the true timestamp while the filename gets a -2/-3
        ;; suffix so it still sorts right after its same-millisecond sibling.
        (define path
          (let loop ([n 0])
            (define name
              (if (zero? n)
                  base
                  (string-replace base ".manifest.json" (format "-~a.manifest.json" n))))
            (define p (build-path dir name))
            (if (file-exists? p) (loop (add1 n)) p)))
        (write-json-atomic path m))))

;; All manifests for a device, oldest first (chronological by created_at).
;; Hub manifests come back with string keys from JSON; normalize them to
;; the symbol-keyed shape the rest of the engine reads.
(define (repo-snapshots repo device-id)
  (define raw
    (if (hub-repo? repo)
        (hub-list-snapshots (hash-ref repo 'base) (hash-ref repo 'token)
                            (sanitize device-id))
        (let ([dir (build-path (repo-root repo) "devices" (sanitize device-id) "snapshots")])
          (if (directory-exists? dir)
              (for/list ([f (in-list (directory-list dir))]
                         #:when (string-suffix? (path->string f) manifest-suffix))
                (call-with-input-file (build-path dir f) read-json))
              '()))))
  (for/list ([m (in-list raw)])
    (for/hash ([(k v) (in-hash m)])
      (values (if (symbol? k) k (string->symbol k)) v))))
