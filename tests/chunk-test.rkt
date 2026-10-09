#lang racket/base

;; Tests for chunking: generic files → one whole-file chunk, SQLite
;; databases → page-aligned chunks with stable hashes, page sharing across
;; revisions, and empty files producing nothing.

(require rackunit
         racket/file
         racket/port
         crypto
         crypto/libcrypto
         "../app/chunk.rkt")

(define (write-tmp! name bytes)
  (define p (make-temporary-file (string-append "keepsake-chunk-" name "-~a")))
  (with-output-to-file p
    #:exists 'replace
    (lambda () (write-bytes bytes)))
  p)

(define (sqlite-bytes pages page-size)
  (define header (make-bytes 100 0))
  (bytes-copy! header 0 (sqlite-magic))
  (bytes-set! header 16 (arithmetic-shift page-size -8))
  (bytes-set! header 17 (bitwise-and page-size #xFF))
  (define data (make-bytes (* pages page-size) 0))
  (bytes-copy! data 0 header)
  (for ([i (in-range 100 (bytes-length data))])
    (bytes-set! data i (remainder i 251)))
  data)

(define (check-coverage refs size expected-count)
  (check-equal? (length refs) expected-count)
  (check-equal? (for/sum ([r (in-list refs)]) (hash-ref r 'size)) size)
  (for/fold ([offset 0])
            ([r (in-list refs)] [i (in-naturals)])
    (check-equal? (hash-ref r 'offset) offset (format "chunk ~a offset" i))
    (+ offset (hash-ref r 'size))))

(test-case "generic file is one whole-file chunk"
  (define data #"not a database at all")
  (crypto-factories (list libcrypto-factory))
  (define p (write-tmp! "generic" data))
  (check-coverage (plan-file p) (bytes-length data) 1)
  (check-equal? (hash-ref (car (plan-file p)) 'hash)
                (hex-digest (digest (quote sha256) data))))

(test-case "sqlite file is page-aligned"
  (define data (sqlite-bytes 5 4096))
  (define p (write-tmp! "db" data))
  (check-equal? (detect-page-size p) 4096)
  (define refs (plan-file p))
  (check-coverage refs (bytes-length data) 5)
  (for ([r (in-list refs)] [i (in-naturals)])
    (check-equal? (hash-ref r 'hash)
                  (hex-digest (digest (quote sha256) (subbytes data (* i 4096) (* (add1 i) 4096)))))))

(test-case "one-page edit shares the other pages"
  (define v1 (sqlite-bytes 5 4096))
  (define v2 (bytes-copy v1))
  (bytes-set! v2 100 255) ; mutate inside the first page only
  (define p (write-tmp! "db" v1))
  (define first (plan-file p))
  (with-output-to-file p #:exists 'replace (lambda () (write-bytes v2)))
  (define second (plan-file p))
  (check-equal?
   (for/sum ([a (in-list first)] [b (in-list second)])
     (if (string=? (hash-ref a 'hash) (hash-ref b 'hash)) 1 0))
   4))

(test-case "empty file produces no chunks"
  (define p (write-tmp! "empty" #""))
  (check-equal? (plan-file p) '()))

(test-case "hex-digest matches sha256(abc)"
  (check-equal? (hex-digest (digest (quote sha256) #"abc"))
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
