#lang racket/base
;; SPDX-License-Identifier: AGPL-3.0-only

(provide make-request-state current-request-state request-cancel! request-cancelled?
         mark-side-effect-started! call-with-cancellation-shield exn:cancelled?)

;; Generic per-request state: the application chooses the irreversible boundary.
;; Cancellation is not exn:fail, so application failure handlers cannot swallow it.
(struct exn:cancelled exn () #:transparent)
(struct request-state (gate cancelled? submitted? shields) #:mutable)
(define (make-request-state) (request-state (make-semaphore 1) #f #f 0))
(define current-request-state (make-parameter #f))
(define (cancelled) (raise (exn:cancelled "Request cancelled." (current-continuation-marks))))
(define (request-cancelled? state)
  (call-with-semaphore (request-state-gate state) (lambda () (request-state-cancelled? state))))

(define (request-cancel! state)
  (call-with-semaphore
   (request-state-gate state)
   (lambda ()
     (cond [(request-state-submitted? state) 'submitted]
           [else
            (set-request-state-cancelled?! state #t)
            (if (positive? (request-state-shields state)) 'deferred 'cancelled)]))))

(define (mark-side-effect-started!)
  (define state (current-request-state))
  (when state
    (call-with-semaphore
     (request-state-gate state)
     (lambda ()
       (when (request-state-cancelled? state) (cancelled))
       (set-request-state-submitted?! state #t)))))

;; Finish credential rotation/persistence before honouring a pending cancellation.
(define (call-with-cancellation-shield thunk)
  (define state (current-request-state))
  (if (not state) (thunk)
      (let ([results
             (dynamic-wind
               (lambda ()
                 (call-with-semaphore
                  (request-state-gate state)
                  (lambda ()
                    (when (request-state-cancelled? state) (cancelled))
                    (set-request-state-shields! state (add1 (request-state-shields state))))))
               (lambda () (call-with-values thunk list))
               (lambda ()
                 (call-with-semaphore
                  (request-state-gate state)
                  (lambda () (set-request-state-shields! state (sub1 (request-state-shields state)))))))])
        (when (request-cancelled? state) (cancelled))
        (apply values results))))
