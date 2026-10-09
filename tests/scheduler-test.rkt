#lang racket/base

;; Auto-snapshot scheduling decision: interval on, interval off, and the
;; elapsed-time gate — pure enough to test without sleeping.

(require rackunit
         "../app/scheduler.rkt")

(test-case "interval off never runs"
  (define sch (make-scheduler))
  (define ran (box 0))
  (check-false (scheduler-maybe-run! sch 0 100 (lambda () (set-box! ran 1))))
  (check-false (scheduler-maybe-run! sch 0 9999 (lambda () (set-box! ran 1))))
  (check-equal? (unbox ran) 0))

(test-case "first tick runs immediately, then respects the interval"
  (define sch (make-scheduler))
  (define ran (box 0))
  ;; First tick: a fresh scheduler always snapshots once.
  (check-true (scheduler-maybe-run! sch 3600 1000 (lambda () (set-box! ran (add1 (unbox ran))))))
  (check-equal? (unbox ran) 1)
  ;; Too soon: 1000 + 3599 < interval gate.
  (check-false (scheduler-maybe-run! sch 3600 3000 (lambda () (set-box! ran 99))))
  (check-equal? (unbox ran) 1)
  ;; Due: 1000 + 3600 = 4600.
  (check-true (scheduler-maybe-run! sch 3600 4600 (lambda () (set-box! ran (add1 (unbox ran))))))
  (check-equal? (unbox ran) 2))

(test-case "turning the interval off mid-flight stops runs"
  (define sch (make-scheduler))
  (check-true (scheduler-maybe-run! sch 60 100 void))
  (check-false (scheduler-maybe-run! sch 0 200 void)))
