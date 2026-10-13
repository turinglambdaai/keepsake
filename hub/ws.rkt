#lang racket/base

;; Timeline push for the hub: a small WebSocket fan-out endpoint next to
;; the HTTP facade. The HTTP server stays the source of truth — writes
;; that return 2xx call ws-hub-notify!, and every connected timeline
;; page reloads itself instead of waiting for the 60s meta refresh.
;;
;; Client protocol: ws://host:port/timeline?token=<hub token> — the same
;; ?token= escape hatch the read-only HTTP timeline already uses for
;; browsers. With no token configured (open mode) any connection is in.
;; Messages are one-kind JSON: {"event":"timeline_changed"}.

(require racket/async-channel
         racket/contract
         racket/string
         racket/tcp
         json
         websocket)

(struct ws-hub (token subs-box lock))

(struct ws-sub (conn channel thread))

(define (make-ws-hub token)
  (ws-hub token (box null) (make-semaphore 1)))

(provide (contract-out
          [struct ws-hub ((token (or/c string? #f))
                          (subs-box box?)
                          (lock semaphore?))]
          [make-ws-hub (-> (or/c string? #f) ws-hub?)]
          [ws-hub-notify! (-> ws-hub? void?)]
          [serve-timeline-ws!
           (->* (ws-hub?) (#:port exact-nonnegative-integer?)
                (values exact-nonnegative-integer? thread?))]))

;; ---- subscribers ------------------------------------------------------------

(define (gateway-add! hub s)
  (call-with-semaphore
   (ws-hub-lock hub)
   (λ () (set-box! (ws-hub-subs-box hub)
                   (cons s (unbox (ws-hub-subs-box hub)))))))

(define (gateway-remove! hub s)
  (call-with-semaphore
   (ws-hub-lock hub)
   (λ () (set-box! (ws-hub-subs-box hub)
                   (remq s (unbox (ws-hub-subs-box hub)))))))

;; one writer thread per subscriber; notify only does channel puts so a
;; slow page can never stall the HTTP path
(define (writer-loop conn ch cleanup)
  (let loop ()
    (define msg (sync/timeout 30 ch))
    (cond
      [(not msg)
       ;; idle keepalive — nobody reads this side
       (with-handlers ([exn:fail? (λ (_) (cleanup))])
         (ws-ping! conn))
       (loop)]
      [(eq? msg 'stop)
       (with-handlers ([exn:fail? void]) (ws-close! conn))
       (cleanup)]
      [else
       (with-handlers ([exn:fail? (λ (_) (cleanup))])
         (ws-send-text! conn msg))
       (loop)])))

(define (ws-hub-notify! hub)
  (define payload (jsexpr->string (hasheq 'event "timeline_changed")))
  (for ([s (in-list (unbox (ws-hub-subs-box hub)))])
    (async-channel-put (ws-sub-channel s) payload)))

;; ---- handshake ---------------------------------------------------------------

;; timeline pages authenticate with ?token= (browsers cannot send
;; Authorization headers); open mode (no token) admits everyone, same
;; semantics as the HTTP route
(define (token-from-path path)
  (and path
       (let ([m (regexp-match #rx"^/timeline\\?token=([^&]+)" path)])
         (and m (cadr m)))))

(define (authorized? hub path)
  (define expected (ws-hub-token hub))
  (cond
    [(not expected) #t]
    [else (define got (token-from-path path))
          (and got (string=? got expected))]))

(define (close-ports in out)
  (with-handlers ([exn:fail? void])
    (unless (port-closed? in) (close-input-port in))
    (unless (port-closed? out) (close-output-port out))))

(define (handle-connection! hub in out)
  (with-handlers ([exn:fail? (λ (_) (close-ports in out))])
    (define req (ws-read-upgrade-request! in))
    (cond
      [(not (authorized? hub (ws-upgrade-path req)))
       ;; reject before any upgrade response
       (with-handlers ([exn:fail? void])
         (define body "{\"error\":\"unauthorized\"}")
         (fprintf out "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: ~a\r\n\r\n~a"
                  (string-length body) body)
         (flush-output out))
       (close-ports in out)]
      [else
       (define conn
         (ws-adopt in out (ws-upgrade-header req "sec-websocket-key")))
       (define ch (make-async-channel))
       (define s
         (ws-sub conn ch
                 (thread (λ () (writer-loop conn ch
                                            (λ () (gateway-remove! hub s)))))))
       (gateway-add! hub s)])))

;; ---- accept loop ---------------------------------------------------------------

(define (serve-timeline-ws! hub #:port [port 8081])
  (define-values (listener real-port)
    (if (zero? port)
        (let loop ([tries 10])
          (define p (+ 21000 (random 20000)))
          (with-handlers
              ([exn:fail:network? (λ (_)
                                    (when (zero? tries)
                                      (error 'timeline-ws "no free port"))
                                    (loop (sub1 tries)))])
            (values (tcp-listen p 16 #t "0.0.0.0") p)))
        (values (tcp-listen port 16 #t "0.0.0.0") port)))
  (define accept-thread
    (thread
     (λ ()
       (let loop ()
         (with-handlers ([exn:fail? (λ (_) (void))])
           (define-values (in out) (tcp-accept listener))
           (thread (λ () (handle-connection! hub in out))))
         (loop)))))
  (values real-port accept-thread))
