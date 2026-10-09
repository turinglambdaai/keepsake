#lang racket/base

;; Content-addressed chunking with two policies (docs/repo-format.md):
;; media files are immutable in WeChat, so one whole-file chunk is optimal;
;; SQLite databases change a little every snapshot, so they are split on
;; their own page boundary and consecutive snapshots share unchanged pages.
;;
;; A chunk reference is a jsexpr-compatible immutable hash
;; (hasheq 'hash string 'offset integer 'size integer) — the exact shape
;; the manifest stores.

(require crypto
         crypto/libcrypto
         racket/contract
         racket/file
         racket/list)

;; The libcrypto factory backs both one-shot and incremental digests.
(crypto-factories (list libcrypto-factory))

(provide sqlite-magic
         detect-page-size
         plan-file
         hex-digest
         chunk-ref?)

;; The real format stores the page size in bytes as a big-endian uint16 at
;; header offset 16; the value 1 encodes 65536.
(define (sqlite-magic) #"SQLite format 3\0")

(define (chunk-ref? v)
  (and (hash? v)
       (immutable? v)
       (string? (hash-ref v 'hash #f))
       (exact-integer? (hash-ref v 'offset #f))
       (exact-integer? (hash-ref v 'size #f))
       (>= (hash-ref v 'size 0) 0)))

(define (hex-digest b)
  (define digits "0123456789abcdef")
  (list->string
   (append* (for/list ([x (in-bytes b)])
              (list (string-ref digits (arithmetic-shift x -4))
                    (string-ref digits (bitwise-and x #x0F)))))))

;; Returns the SQLite page size in bytes when path is a SQLite 3 database
;; (and its header is well-formed), #f otherwise.
(define (detect-page-size path)
  (with-input-from-file path
    (lambda ()
      (define head (read-bytes 100))
      (cond
        [(or (eof-object? head) (< (bytes-length head) 100)) #f]
        [(not (equal? (subbytes head 0 16) (sqlite-magic))) #f]
        [else
         (define raw (integer-bytes->integer (subbytes head 16 18) #f #t))
         (cond
           [(= raw 1) 65536]
           [(and (>= raw 512) (<= raw 65536)) raw]
           [else #f])]))
    #:mode 'binary))

(define (make-ref hash offset size)
  (hasheq 'hash hash 'offset offset 'size size))

(define (plan-page-aligned in page-size)
  (let loop ([offset 0] [acc '()])
    (define buf (read-bytes page-size in))
    (cond
      [(eof-object? buf) (reverse acc)]
      [else
       (define n (bytes-length buf))
       (loop (+ offset n)
             (cons (make-ref (hex-digest (digest 'sha256 buf)) offset n) acc))])))

(define (plan-whole-file in)
  ;; One streaming pass: hash and count, never holding the whole file.
  (define ctx (make-digest-ctx 'sha256))
  (let loop ([total 0])
    (define buf (read-bytes (* 64 1024) in))
    (cond
      [(eof-object? buf)
       (if (zero? total)
           '()
           (list (make-ref (hex-digest (digest-final ctx)) 0 total)))]
      [else
       (digest-update ctx buf)
       (loop (+ total (bytes-length buf)))])))

;; (plan-file path) → (listof chunk-ref?) covering the whole file in order:
;; offsets start at 0, increase monotonically, sizes sum to the file size.
(define (plan-file path)
  (define page-size (detect-page-size path))
  (with-input-from-file path
    (lambda ()
      (if page-size
          (plan-page-aligned (current-input-port) page-size)
          (plan-whole-file (current-input-port))))
    #:mode 'binary))
