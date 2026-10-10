#lang racket/base

;; License tests: token issue/verify round trip, tamper rejection, expiry,
;; and the trial/expired/licensed decision logic.

(require crypto
         crypto/all
         json
         net/base64
         racket/file
         racket/list
         racket/format
         racket/port
         racket/string
         rackunit
         "../app/format.rkt"
         "../app/repo.rkt"
         "../hub/license.rkt")

(use-all-factories!)

;; throwaway keypair; the public half is parameterized into the verifier
(define priv (generate-private-key 'eddsa '((curve ed25519))))
(define pub
  (datum->pk-key (pk-key->datum priv 'rkt-public) 'rkt-public))
(define (b64-encode bytes)
  (define standard (string-trim (bytes->string/utf-8 (base64-encode bytes #""))))
  standard)
(define pub-b64 (b64-encode (pk-key->datum pub 'SubjectPublicKeyInfo)))

(define (with-test-keys thunk)
  (parameterize ([license-public-key-b64 pub-b64]
                 [license-key-id "test-key"])
    (thunk)))

(define (today-string)
  (define d (seconds->date (current-seconds) #t))
  (format "~a-~a-~a" (date-year d)
          (~r (date-month d) #:min-width 2 #:pad-string "0")
          (~r (date-day d) #:min-width 2 #:pad-string "0")))

(define (issue-test-token subject #:expiry [expiry #f])
  (parameterize ([license-key-id "test-key"])
    (issue-hub-token priv subject #:expiry expiry)))

(test-case "valid token verifies and returns claims"
  (with-test-keys
   (lambda ()
     (define token (issue-test-token "customer@example.com"))
     (define-values (claims reason) (parse-and-verify token))
     (check-false reason)
     (check-true (hash? claims))
     (check-equal? (hash-ref claims 'subject) "customer@example.com")
     (check-equal? (hash-ref claims 'type) "hub"))))

(test-case "tampered token fails on signature"
  (with-test-keys
   (lambda ()
     (define token (issue-test-token "customer@example.com"))
     (define parts (string-split token "."))
     (define tampered
       (string-join (list (first parts) (second parts)
                          (string-append "AAAA" (third parts))) "."))
     (define-values (claims reason) (parse-and-verify tampered))
     (check-false claims)
     (check-equal? reason "signature"))))

(test-case "expired token is refused"
  (with-test-keys
   (lambda ()
     (define token (issue-test-token "s" #:expiry "2020-01-01"))
     (define-values (claims reason)
       (parse-and-verify token #:today (today-string)))
     (check-false claims)
     (check-equal? reason "expired"))))

(test-case "malformed tokens are refused with a reason"
  (with-test-keys
   (lambda ()
     (define-values (claims reason) (parse-and-verify "KS1.only-two-parts"))
     (check-false claims)
     (check-equal? reason "malformed"))))

(test-case "trial-state counts down from the repository creation stamp"
  (define root (make-temporary-file "keepsake-lic-~a" 'directory))
  (repo-init root)
  ;; fresh repository: 30-day trial just started
  (check-equal? (trial-state root (current-seconds)) 30)
  ;; a repository created 29 days ago has 1 day left
  (define marker-path (build-path root "repo.json"))
  (define marker (with-input-from-file marker-path read-json))
  (with-output-to-file marker-path
    #:exists 'replace
    (lambda ()
      (write-json (hash-set marker 'created_at
                            "2026-09-10T12:00:00.000Z"))))
  (check-equal? (trial-state root (current-seconds)) 1)
  ;; created before the trial window: trial over
  (with-output-to-file marker-path
    #:exists 'replace
    (lambda ()
      (write-json (hash-set marker 'created_at
                            "2026-08-01T12:00:00.000Z"))))
  (check-equal? (trial-state root (current-seconds)) 0))

(test-case "license-decision: trial, licensed, expired"
  (define root (make-temporary-file "keepsake-lic-~a" 'directory))
  (repo-init root)
  (with-test-keys
   (lambda ()
     ;; unlicensed + fresh: trial with 30 days
     (define d1 (license-decision root #f))
     (check-equal? (hash-ref d1 'state) "trial")
     (check-equal? (hash-ref d1 'days) 30)
     ;; valid token: licensed
     (define d2 (license-decision root (issue-test-token "s")))
     (check-equal? (hash-ref d2 'state) "licensed")
     ;; tampered token: invalid with a reason (writes blocked)
     (define d3 (license-decision root "KS1.bad.bad"))
     (check-equal? (hash-ref d3 'state) "invalid"))))
