#lang racket/base
;; SPDX-License-Identifier: AGPL-3.0-only

;; Minimal bindings to the documented libwebp decoding API. Keep unsafe FFI
;; inside the image worker, never in the long-lived MCP process.
(require ffi/unsafe racket/promise)
(provide webp-dimensions+animation validate-webp-pixels exn:fail:webp-runtime?)

(struct exn:fail:webp-runtime exn:fail () #:transparent)

(define webp-library
  (delay (ffi-lib "libwebp" '("7" "")
                  #:fail (lambda () (raise (exn:fail:webp-runtime "libwebp unavailable" (current-continuation-marks)))))))
(define-cstruct _features
  ([width _int] [height _int] [alpha _int] [animation _int] [format _int]
   [padding (_array _uint32 5)]))

(define (webp-dimensions+animation raw)
  ;; WebPGetFeatures is an inline C wrapper around this ABI-checked export.
  ;; The structure and version are from libwebp's installed decode.h (0x0210).
  (define get-features
    (get-ffi-obj "WebPGetFeaturesInternal" (force webp-library)
                 (_fun _bytes _size _features-pointer _int -> _int)))
  (define result (cast (malloc _features 'atomic) _pointer _features-pointer))
  (unless (zero? (get-features raw (bytes-length raw) result #x0210))
    (error 'webp "Invalid WebP features"))
  (values (features-width result) (features-height result) (not (zero? (features-animation result)))))

(define (validate-webp-pixels raw width height)
  (define decode
    (get-ffi-obj "WebPDecodeRGBA" (force webp-library)
                 (_fun _bytes _size (width : (_ptr o _int)) (height : (_ptr o _int))
                       -> (pixels : _pointer) -> (values pixels width height))))
  (define release (get-ffi-obj "WebPFree" (force webp-library) (_fun _pointer -> _void)))
  (define-values (pixels actual-width actual-height) (decode raw (bytes-length raw)))
  (unless pixels (error 'webp "Invalid WebP pixel data"))
  (dynamic-wind void
                (lambda ()
                  (unless (and (= width actual-width) (= height actual-height))
                    (error 'webp "Inconsistent WebP dimensions")))
                (lambda () (release pixels))))
