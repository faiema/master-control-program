#lang racket/base
;; SPDX-License-Identifier: AGPL-3.0-only

(require json racket/file racket/path "pkce.rkt")
(provide write-private-json call-with-private-json-lock)

(define token-lock (make-semaphore 1))

(define (prepare-parent path)
  (define parent (path-only (path->complete-path path)))
  (unless (directory-exists? parent)
    (make-directory* (simplify-path (build-path parent 'up)))
    (with-handlers ([exn:fail:filesystem:exists? void])
      (make-directory parent #o700)))
  parent)

;; Lock a stable sibling, never the token inode that atomic replacement removes.
;; The OS releases the lock on process exit; the empty lock file stays in place.
(define (call-with-private-json-lock path thunk failure)
  (prepare-parent path)
  (call-with-semaphore
   token-lock
   (lambda ()
     (call-with-file-lock/timeout path 'exclusive thunk failure #:max-delay 1.0))))

;; Atomically replace a secret file without a world-readable creation window.
;; An existing parent directory is never chmodded as it may contain other data.
(define (write-private-json path value)
  (define destination (path->complete-path path))
  (define parent (prepare-parent destination))
  (define temporary (build-path parent (string-append ".token-" (random-state) ".tmp")))
  (dynamic-wind
    void
    (lambda ()
      (call-with-output-file temporary #:exists 'error #:permissions #o600
        (lambda (output) (write-json value output)))
      (rename-file-or-directory temporary destination #t))
    (lambda () (when (file-exists? temporary) (delete-file temporary)))))
