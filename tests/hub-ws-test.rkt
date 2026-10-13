#lang racket/base

;; Timeline websocket fan-out: auth on the handshake, the notify
;; broadcast, and the HTTP-write hook — against a real listener with
;; real WebSocket clients.

(require rackunit
         racket/file
         racket/tcp
         json
         websocket
         "../hub/ws.rkt")

(define (jsexpr->bytes j)
  (string->bytes/utf-8 (jsexpr->string j)))

(define TOKEN "hub-secret")

(define (recv/timeout conn secs what)
  (define ch (make-channel))
  (define t (thread (λ () (channel-put ch (ws-recv conn)))))
  (or (sync/timeout secs ch)
      (begin (kill-thread t) #f)))

(define (recv-event conn secs what)
  (define m (recv/timeout conn secs what))
  (unless (and (ws-message? m) (not (vector? m)))
    (error 'recv-event "no message for ~a: ~a" what m))
  (read-json (open-input-string (bytes->string/utf-8 (ws-message-payload m)))))

(define (connect-timeline port token)
  (ws-connect
   (if token
       (format "ws://127.0.0.1:~a/timeline?token=~a" port token)
       (format "ws://127.0.0.1:~a/timeline" port))))

(module+ test
  (define hub (make-ws-hub TOKEN))
  (define-values (ws-port _accept-thread) (serve-timeline-ws! hub #:port 0))

  ;; missing / wrong token are rejected before any upgrade
  (check-exn exn:fail:websocket? (λ () (connect-timeline ws-port #f)))
  (check-exn exn:fail:websocket? (λ () (connect-timeline ws-port "wrong")))

  ;; open mode admits everyone
  (define open-hub (make-ws-hub #f))
  (define-values (open-port _) (serve-timeline-ws! open-hub #:port 0))
  (define open-conn (connect-timeline open-port #f))
  (ws-hub-notify! open-hub)
  (check-equal? (hash-ref (recv-event open-conn 5 "open notify") 'event)
                "timeline_changed")
  (ws-close! open-conn)

  ;; authorized client receives the notify broadcast
  (define conn (connect-timeline ws-port TOKEN))
  (ws-hub-notify! hub)
  (check-equal? (hash-ref (recv-event conn 5 "notify") 'event)
                "timeline_changed")

  ;; two clients both fan out
  (define conn2 (connect-timeline ws-port TOKEN))
  (ws-hub-notify! hub)
  (check-equal? (hash-ref (recv-event conn 5 "fanout 1") 'event)
                "timeline_changed")
  (check-equal? (hash-ref (recv-event conn2 5 "fanout 2") 'event)
                "timeline_changed")
  (ws-close! conn)
  (ws-close! conn2))

;; the HTTP write hook: a 2xx PUT fires on-write, other routes don't
(module+ test
  (require "../hub/server.rkt"
           (only-in web-server/http/request-structs request header)
           (only-in net/url string->url)
           (only-in racket/promise delay))

  (define (make-GET path)
    (request #"GET" (string->url path) null (delay null) #f
             "127.0.0.1" 80 "127.0.0.1"))

  (define (make-PUT path body auth-header)
    (request #"PUT" (string->url path)
             (if auth-header
                 (list (header #"Authorization"
                               (string->bytes/utf-8
                                (string-append "Bearer " auth-header))))
                 null)
             (delay null)
             body
             "127.0.0.1" 80 "127.0.0.1"))

  (require (only-in "../app/format.rkt" format-version)
           racket/format)
  (define dir (make-temporary-file "keepsake-ws-~a" 'directory))
  (hub-repo-open dir)
  (define fired (box 0))
  (define app (make-hub-app dir "tok"
                            (λ () (set-box! fired (add1 (unbox fired))))
                            8081))
  ;; read: no fire
  (void (app (make-GET "/healthz")))
  (check-equal? (unbox fired) 0)
  ;; unauthorized write: 401, no fire
  (void (app (make-PUT "/api/devices/d1/snapshots/20261013T000000.000Z.manifest.json"
                       #"{}" #f)))
  (check-equal? (unbox fired) 0)
  ;; authorized manifest write that 200s: fires
  (define manifest
    (hasheq 'format_version format-version
            'device_id "dev-ws"
            'account "wxid_ws"
            'host_platform "darwin"
            'created_at "2026-10-13T00:00:00.000Z"
            'files '()))
  (void (app (make-PUT
              (format "/api/devices/dev-ws/snapshots/~a.manifest.json"
                      "20261013T000000.000Z")
              (jsexpr->bytes manifest)
              "tok")))
  (check-equal? (unbox fired) 1))
