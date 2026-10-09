#lang racket/base

;; Auto-snapshot scheduling: a testable "should it run now" decision plus a
;; thin sleep-loop thread around it. The interval lives with the caller (the
;; backend mirrors it to the UI as state); the scheduler only knows seconds.

(require racket/contract)

(provide (contract-out
          [scheduler? predicate/c]
          [make-scheduler (-> scheduler?)]
          [scheduler-maybe-run! (-> scheduler? exact-nonnegative-integer?
                                    exact-integer? (-> any) boolean?)]
          [start-scheduler! (-> scheduler? (-> exact-nonnegative-integer?) (-> any)
                                thread?)]))

(struct scheduler ([last-run #:mutable]) #:transparent)

(define (make-scheduler) (scheduler #f))

;; Runs `run` when the interval says so: interval > 0 and (now - last-run)
;; has reached it, or on the very first tick. Returns whether it ran.
;; interval <= 0 means the feature is off and nothing ever runs.
(define (scheduler-maybe-run! sch interval-seconds now-seconds run)
  (cond
    [(<= interval-seconds 0) #f]
    [(and (scheduler-last-run sch)
          (< (- now-seconds (scheduler-last-run sch)) interval-seconds))
     #f]
    [else
     (run)
     (set-scheduler-last-run! sch now-seconds)
     #t]))

;; Background loop: ticks every 30 seconds and delegates the decision.
;; Errors from `run` are swallowed per tick — a failed auto-snapshot must
;; never kill the scheduler.
(define (start-scheduler! sch get-interval-seconds run)
  (thread
   (lambda ()
     (let loop ()
       (sleep 30)
       (with-handlers ([exn:fail? void])
         (scheduler-maybe-run! sch (get-interval-seconds) (current-seconds) run))
       (loop)))))
