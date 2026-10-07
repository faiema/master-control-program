#lang racket/base

(provide call-with-deadline)

;; Independent of MCP, X, and the caller's error vocabulary. Resources created
;; by thunk belong to a child custodian and are released on every exit path.
(define (call-with-deadline seconds thunk on-timeout)
  (define owner (make-custodian))
  (define result (make-channel))
  (dynamic-wind
    void
    (lambda ()
      (parameterize ([current-custodian owner]
                     [current-subprocess-custodian-mode 'kill])
        (thread
         (lambda ()
           (with-handlers ([exn:fail? (lambda (e) (channel-put result (cons 'error e)))])
             (channel-put result (cons 'ok (call-with-values thunk list)))))))
      (define answer (sync/timeout seconds result))
      (cond [(not answer) (on-timeout)]
            [(eq? (car answer) 'error) (raise (cdr answer))]
            [else (apply values (cdr answer))]))
    (lambda () (custodian-shutdown-all owner))))
