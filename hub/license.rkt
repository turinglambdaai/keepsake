#lang racket/base

;; Keepsake Hub license tokens (KS1.<claims>.<sig>), the same honesty
;; scheme as payback's PB1: an Ed25519-signed claims token, verified fully
;; offline. Unlicensed hubs run a 30-day trial from the repository's
;; creation timestamp; after that they keep serving reads and restores
;; forever but stop accepting new writes — agents fail over to direct
;; directory writes, so no data is ever held hostage.

(require crypto
         crypto/all
         json
         net/base64
         racket/contract
         racket/date
         racket/file
         racket/format
         racket/list
         racket/port
         racket/string
         "../app/format.rkt")

(use-all-factories!)

(provide (contract-out
          [trial-days exact-nonnegative-integer?]
          [license-public-key-b64 parameter?]
          [license-key-id parameter?]
          [parse-and-verify (->* (string?) (#:today (or/c string? #f))
                                 (values (or/c hash? #f) (or/c string? #f)))]
          [issue-hub-token (->* (private-key? string?)
                                (#:expiry (or/c string? #f))
                                string?)]
          [trial-state (-> path-string? exact-nonnegative-integer? exact-nonnegative-integer?)]
          [license-decision (-> path-string? (or/c string? #f) hash?)]))

;; ---- trial policy ----

(define trial-days 30)

;; First-seen timestamp: the repository marker's created_at (written once,
;; when the hub first opened the repository), so the trial survives restarts
;; and cannot be reset by deleting a config file.
(define (first-seen-seconds root)
  (define marker
    (with-handlers ([exn:fail? (lambda (_) #f)])
      (with-input-from-file (build-path root marker-name) read-json)))
  (define created (and marker (hash-ref marker 'created_at #f)))
  (define m (and created
                 (regexp-match #px"^(\\d{4})-(\\d{2})-(\\d{2})T(\\d{2}):(\\d{2}):(\\d{2})"
                               created)))
  (if m
      (with-handlers ([exn:fail? (lambda (_) (current-seconds))])
        ;; Racket 9.3's find-seconds only reads local wall time: evaluate
        ;; locally and subtract that instant's zone offset.
        (define local
          (find-seconds (string->number (list-ref m 6))
                        (string->number (list-ref m 5))
                        (string->number (list-ref m 4))
                        (string->number (list-ref m 3))
                        (string->number (list-ref m 2))
                        (string->number (list-ref m 1))
                        #f))
        (- local (date-time-zone-offset (seconds->date local))))
      (current-seconds)))

;; Remaining trial days (0 = trial over), given the license is absent.
(define (trial-state root now-seconds)
  (define started (first-seen-seconds root))
  (define used-days (quotient (- now-seconds started) 86400))
  (if (>= used-days trial-days) 0 (- trial-days used-days)))

;; ---- license evaluation ----

;; One decision per request snapshot:
;;   licensed — valid token present
;;   trial    — unlicensed, days remaining (in 'days)
;;   expired  — unlicensed and trial over (writes must be refused)
;;   invalid  — a token was presented but does not verify ('reason)
(define (license-decision root token)
  (if token
      (let-values ([(claims reason) (parse-and-verify token)])
        (if claims
            (hasheq 'state "licensed" 'subject (hash-ref claims 'subject ""))
            (hasheq 'state "invalid" 'reason reason 'days 0)))
      (let ([days (trial-state root (current-seconds))])
        (if (> days 0)
            (hasheq 'state "trial" 'days days)
            (hasheq 'state "expired" 'days 0)))))

;; ---- token crypto (KS1 format; PB1's sibling) ----

(define license-public-key-b64 (make-parameter #f))
(define license-key-id (make-parameter "ks-hub-2026-01"))

(define (canonical-json v)
  (string->bytes/utf-8 (json-fragment v)))

(define (json-fragment v)
  (cond
    [(hash? v)
     (string-append
      "{"
      (string-join (for/list ([k (in-list (sort (hash-keys v) string<? #:key symbol->string))])
                     (format "~a:~a" (json-string (symbol->string k))
                             (json-fragment (hash-ref v k))))
                   ",")
      "}")]
    [(list? v) (string-append "[" (string-join (map json-fragment v) ",") "]")]
    [(string? v) (json-string v)]
    [(real? v) (~a v)]
    [(boolean? v) (if v "true" "false")]
    [else (json-string (format "~a" v))]))

(define (json-string s)
  (string-append "\""
                 (string-join (for/list ([c (in-string s)])
                                (case c
                                  [(#\") "\\\""]
                                  [(#\\) "\\\\"]
                                  [(#\newline) "\\n"]
                                  [(#\return) "\\r"]
                                  [(#\tab) "\\t"]
                                  [else (string c)]))
                              "")
                 "\""))

(define (b64url-encode bytes)
  (define standard
    (string-trim (bytes->string/utf-8 (base64-encode bytes #""))))
  (string-replace
   (string-replace (string-replace standard "=" "") "+" "-")
   "/" "_"))

(define (b64url-decode s)
  (define padded
    (case (modulo (string-length s) 4)
      [(2) (string-append s "==")]
      [(3) (string-append s "=")]
      [else s]))
  (base64-decode
   (string->bytes/utf-8 (string-replace
                         (string-replace padded "-" "+")
                         "_" "/"))))

;; ---- issuing (vendor side; tests use it with a throwaway keypair) ----

(define (issue-hub-token private-key subject #:expiry [expiry #f])
  (define claims
    (hasheq 'product "keepsake-hub"
            'subject subject
            'type "hub"
            'key_id (license-key-id)))
  (define claims-with-expiry
    (if expiry (hash-set claims 'expiry expiry) claims))
  (define payload (canonical-json claims-with-expiry))
  (define sig (pk-sign private-key payload))
  (string-append "KS1."
                 (b64url-encode payload)
                 "."
                 (b64url-encode sig)))

;; ---- verification (hub side, fully offline) ----

;; (parse-and-verify token [today]) → (values claims reason)
(define (parse-and-verify token #:today [today #f])
  (let/cc return
    (define (fail reason) (return #f reason))
    (define parts (and (string? token) (string-split token ".")))
    (unless (and parts (= (length parts) 3) (string=? (first parts) "KS1"))
      (fail "malformed"))
    (define claims
      (with-handlers ([exn:fail? (lambda (_) #f)])
        (define raw (b64url-decode (second parts)))
        (and raw (with-handlers ([exn:fail? (lambda (_) #f)])
                   (call-with-input-bytes raw read-json)))))
    (unless (hash? claims)
      (fail "malformed"))
    (define sig (with-handlers ([exn:fail? (lambda (_) #f)])
                  (b64url-decode (third parts))))
    (unless (bytes? sig)
      (fail "malformed"))
    (define pub-b64 (license-public-key-b64))
    (define public-key
      (and pub-b64
           (with-handlers ([exn:fail? (lambda (_) #f)])
             (datum->pk-key (b64url-decode pub-b64) 'SubjectPublicKeyInfo))))
    (unless public-key
      (fail "malformed"))
    ;; note crypto's argument order: (public-key message signature)
    (unless (pk-verify public-key (canonical-json claims) sig)
      (fail "signature"))
    (unless (equal? (hash-ref claims 'product #f) "keepsake-hub")
      (fail "product"))
    (unless (equal? (hash-ref claims 'key_id #f) (license-key-id))
      (fail "key-id"))
    (unless (equal? (hash-ref claims 'type #f) "hub")
      (fail "type"))
    (define expiry (hash-ref claims 'expiry #f))
    (when (eq? expiry 'null) (set! expiry #f))
    (when (and expiry today (string<? expiry today))
      (fail "expired"))
    (values claims #f)))
