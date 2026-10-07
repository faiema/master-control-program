#lang racket/base

(require "auth.rkt" "common.rkt" "lib/oauth-loopback.rkt")
(provide login)

(define (login)
  (define client-id (getenv "X_CLIENT_ID"))
  (unless (and client-id (not (equal? client-id "")))
    (bridge-error "Authentication: set X_CLIENT_ID from your X developer app first."))
  (define-values (url state verifier) (authorization client-id))
  (define code
    (with-handlers ([exn:fail:oauth-callback? (lambda (e) (bridge-error (string-append "Authentication: " (exn-message e))))]
                    [exn:fail? (lambda (_) (bridge-error "Authentication: callback listener failed; check that 127.0.0.1:8765 is available."))])
      (receive-authorization-code state
                                  #:on-listening (lambda (_)
                                                   (displayln "Open this URL in a browser on this machine:")
                                                   (displayln url) (flush-output)))))
  (save-token (exchange code verifier client-id (getenv "X_CLIENT_SECRET")))
  (displayln "Token stored with owner-only permissions. Re-run login when it expires."))

(module+ main
  (with-handlers ([exn:fail:bridge? (lambda (e) (displayln (exn-message e) (current-error-port)) (exit 1))])
    (login)))
