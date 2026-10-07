#lang racket/base

(require json racket/file racket/path "pkce.rkt")
(provide write-private-json)

;; Atomically replace a secret file without a world-readable creation window.
;; An existing parent directory is never chmodded as it may contain other data.
(define (write-private-json path value)
  (define destination (path->complete-path path))
  (define parent (path-only destination))
  (unless (directory-exists? parent)
    (make-directory* (simplify-path (build-path parent 'up)))
    (make-directory parent #o700))
  (define temporary (build-path parent (string-append ".token-" (random-state) ".tmp")))
  (dynamic-wind
    void
    (lambda ()
      (call-with-output-file temporary #:exists 'error #:permissions #o600
        (lambda (output) (write-json value output)))
      (rename-file-or-directory temporary destination #t))
    (lambda () (when (file-exists? temporary) (delete-file temporary)))))
