#lang racket/base

;; Full-protocol RPC tests for the keepsake backend: drive the real RVT1
;; server over pipes exactly the way the native hosts do, against a fake
;; WeChat directory and a scratch repository.

(require json
         rackunit
         racket/file
         racket/list
         racket/path
         racket/string
         rivet/backend
         rivet/protocol
         (file "../app/backend.rkt")
         (file "../app/discover.rkt"))

;; ---------- fixture: a fake WeChat account directory ----------

(define wechat-root (make-temporary-file "keepsake-rpc-wx-~a" 'directory))
(define acc-dir (build-path wechat-root "wxid_rpc" "db_storage"))
(make-directory* (build-path acc-dir "message"))
(define db-bytes (make-bytes (* 3 4096) 0))
(bytes-copy! db-bytes 0 #"SQLite format 3\0")
(bytes-set! db-bytes 16 #x10)
(for ([i (in-range 100 (bytes-length db-bytes))])
  (bytes-set! db-bytes i (remainder i 251)))
(with-output-to-file (build-path acc-dir "message" "0.db")
  #:exists 'replace (lambda () (write-bytes db-bytes)))
(with-output-to-file (build-path acc-dir "note.txt")
  #:exists 'replace (lambda () (display "rpc test")))

(define repo-dir (make-temporary-file "keepsake-rpc-repo-~a" 'directory))

;; ---------- server plumbing ----------

(define-values (server-in client-out) (make-pipe))
(define-values (client-in server-out) (make-pipe))

(define server-thread
  (parameterize ([current-wechat-root wechat-root])
    (thread (lambda () (serve server-in server-out)))))

(define (read-frame/timeout in [seconds 5])
  (define result (make-channel))
  (thread (lambda () (channel-put result (read-frame in))))
  (define value (sync/timeout seconds result))
  (unless value
    (error 'read-frame/timeout "timed out waiting for Rivet frame"))
  value)

(define next-id (box 0))

(define (call-rpc name . args)
  (define id (begin (set-box! next-id (add1 (unbox next-id)))
                    (unbox next-id)))
  (write-frame (frame message:request id (encode-value (list* name args)))
               client-out)
  ;; Skip interleaved event and state-update frames; only the response
  ;; (or a wire error) answers this request.
  (let loop ()
    (define response (read-frame/timeout client-in))
    (define type (frame-type response))
    (cond
      [(equal? type message:response)
       (check-equal? (frame-id response) id)
       (define value (decode-value (frame-payload response)))
       (if (bytes? value)
           (read-json (open-input-bytes value))
           value)]
      [(equal? type message:error)
       (error 'call-rpc "request failed: ~a"
              (decode-value (frame-payload response)))]
      [else (loop)])))

;; ---------- handshake ----------

(define hello (read-frame/timeout client-in))
(check-equal? (frame-type hello) message:hello)

;; ---------- discovery over the wire ----------

(define accounts (call-rpc "list-accounts"))
(check-equal? (length accounts) 1)
;; Records decode to positional lists on the wire: (id path size-label).
(define acct (car accounts))
(check-equal? (first acct) "wxid_rpc")
(check-true (string-contains? (third acct) "KB"))

;; ---------- repository location round trip ----------

(check-equal? (call-rpc "set-repository-location" (path->string repo-dir)) (void))
(check-equal? (call-rpc "get-repository-location") (path->string repo-dir))

;; ---------- snapshot over the wire ----------

(define snap-result (call-rpc "run-snapshot" "wxid_rpc"))
(check-equal? (first snap-result) #t)
(check-true (string-contains? (second snap-result) "files"))

;; unknown account: handled result, not a wire error
(define bad-snap (call-rpc "run-snapshot" "wxid_nope"))
(check-equal? (first bad-snap) #f)

;; ---------- snapshots over the wire ----------

(define snaps (call-rpc "list-snapshots" "wxid_rpc"))
(check-equal? (length snaps) 1)
(check-equal? (third (car snaps)) "wxid_rpc")
(check-equal? (fourth (car snaps)) 2)

;; ---------- restore over the wire ----------

(define target (build-path (make-temporary-file "keepsake-rpc-tgt-~a" 'directory)
                           "account"))
(define restore-result (call-rpc "restore-latest" "wxid_rpc" (path->string target)))
(check-equal? (first restore-result) #t)
(check-equal? (file->bytes (build-path target "db_storage" "message" "0.db")) db-bytes)
(check-equal? (file->string (build-path target "db_storage" "note.txt")) "rpc test")
