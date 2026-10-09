#lang racket/base
;; SPDX-License-Identifier: AGPL-3.0-only

;; Process isolation lets the parent enforce a deadline even inside a C codec.
(require json "lib/image.rkt")

(module+ main
  (define result
    (with-handlers ([exn:fail:image? (lambda (e) (hasheq 'error (string-append "Media: " (exn-message e))))]
                    [exn:fail? (lambda (_) (hasheq 'error "Media: native image decoder failed; check codec installation."))])
      (define raw (read-bytes (add1 (* 5 1024 1024))))
      (define info (inspect-static-image raw #:max-bytes (* 5 1024 1024) #:max-pixels 40000000))
      (hasheq 'mime_type (image-info-mime info) 'width (image-info-width info)
              'height (image-info-height info) 'size_bytes (image-info-size info))))
  (write-json result)
  (newline))
