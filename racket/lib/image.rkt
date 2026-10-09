#lang racket/base
;; SPDX-License-Identifier: AGPL-3.0-only

;; Generic, offline static-image validation. It has no knowledge of URLs, X,
;; MCP, credentials, or the application's byte/pixel policy.
(require racket/class racket/draw "webp.rkt")
(provide inspect-static-image (struct-out image-info) (struct-out exn:fail:image))

(struct image-info (mime width height size) #:transparent)
(struct exn:fail:image exn:fail () #:transparent)
(define (invalid [message "invalid, truncated, or unsafe image content."])
  (raise (exn:fail:image message (current-continuation-marks))))
(define (unsupported) (invalid "only static JPEG, PNG, and WebP images are supported."))
(define (u16 raw at) (integer-bytes->integer raw #f #t at (+ at 2)))
(define (u32 raw at [big-endian? #t]) (integer-bytes->integer raw #f big-endian? at (+ at 4)))
(define (starts? raw prefix)
  (and (>= (bytes-length raw) (bytes-length prefix))
       (bytes=? (subbytes raw 0 (bytes-length prefix)) prefix)))

;; Verify every PNG chunk, including ancillary CRCs that libpng can ignore.
;; This is container validation; pixel decoding is left to the native codec.
(define crc-table
  (for/vector ([byte (in-range 256)])
    (for/fold ([crc byte]) ([_ (in-range 8)])
      (bitwise-xor (arithmetic-shift crc -1) (if (odd? crc) #xedb88320 0)))))
(define (crc32 raw start end)
  (bitwise-xor
   #xffffffff
   (for/fold ([crc #xffffffff]) ([index (in-range start end)])
     (bitwise-xor (arithmetic-shift crc -8)
                  (vector-ref crc-table (bitwise-and #xff (bitwise-xor crc (bytes-ref raw index))))))))

(define (png-dimensions raw)
  (define size (bytes-length raw))
  (unless (and (>= size 33) (bytes=? (subbytes raw 12 16) #"IHDR") (= (u32 raw 8) 13)) (invalid))
  (define width (u32 raw 16))
  (define height (u32 raw 20))
  (let loop ([offset 8] [seen-data? #f])
    (unless (<= (+ offset 12) size) (invalid))
    (define length (u32 raw offset))
    (define end (+ offset 8 length))
    (unless (<= (+ end 4) size) (invalid))
    (define kind (subbytes raw (+ offset 4) (+ offset 8)))
    (unless (= (crc32 raw (+ offset 4) end) (u32 raw end)) (invalid))
    (when (or (bytes=? kind #"acTL") (bytes=? kind #"fcTL") (bytes=? kind #"fdAT")) (unsupported))
    (when (and (> offset 8) (bytes=? kind #"IHDR")) (invalid))
    (cond
      [(bytes=? kind #"IEND")
       (unless (and (zero? length) seen-data?) (invalid))
       (values width height)]
      [else (loop (+ end 4) (or seen-data? (bytes=? kind #"IDAT")))])))

(define (jpeg-dimensions raw)
  (define size (bytes-length raw))
  ;; Require a real end marker; libjpeg may otherwise repair truncated input.
  (unless (regexp-match? #rx#"\377\331" raw) (invalid))
  (let loop ([offset 2])
    (unless (and (< (+ offset 3) size) (= (bytes-ref raw offset) #xff)) (invalid))
    (define marker-at
      (let skip-fill ([at (add1 offset)])
        (unless (< at size) (invalid))
        (if (= (bytes-ref raw at) #xff) (skip-fill (add1 at)) at)))
    (define marker (bytes-ref raw marker-at))
    (unless (and (not (memv marker '(0 1 #xd8 #xd9 #xda)))
                 (not (<= #xd0 marker #xd7)) (<= (+ marker-at 3) size)) (invalid))
    (define length (u16 raw (add1 marker-at)))
    (unless (and (>= length 2) (<= (+ marker-at 1 length) size)) (invalid))
    (cond
      [(memv marker '(#xc0 #xc1 #xc2 #xc3 #xc5 #xc6 #xc7 #xc9 #xca #xcb #xcd #xce #xcf))
       (unless (and (>= length 8) (= length (+ 8 (* 3 (bytes-ref raw (+ marker-at 8)))))) (invalid))
       (values (u16 raw (+ marker-at 6)) (u16 raw (+ marker-at 4)))]
      [else (loop (+ marker-at 1 length))])))

(define (inspect-static-image raw #:max-bytes max-bytes #:max-pixels max-pixels)
  (unless (and (bytes? raw) (<= 1 (bytes-length raw) max-bytes))
    (invalid "image is empty or exceeds the byte limit."))
  (with-handlers ([exn:fail:image? raise]
                  [exn:fail:webp-runtime? (lambda (_) (invalid "WebP decoder unavailable; install the libwebp runtime library."))]
                  [exn:fail? (lambda (_) (invalid))])
    (define-values (kind mime width height)
      (cond
        [(starts? raw #"\211PNG\r\n\032\n")
         (define-values (width height) (png-dimensions raw))
         (values 'png "image/png" width height)]
        [(starts? raw #"\377\330")
         (define-values (width height) (jpeg-dimensions raw))
         (values 'jpeg "image/jpeg" width height)]
        [(and (starts? raw #"RIFF") (>= (bytes-length raw) 12) (bytes=? (subbytes raw 8 12) #"WEBP"))
         (unless (<= (+ 8 (u32 raw 4 #f)) (bytes-length raw)) (invalid))
         (define-values (width height animated?) (webp-dimensions+animation raw))
         (when animated? (unsupported))
         (values 'webp "image/webp" width height)]
        [else (unsupported)]))
    (unless (and (positive? width) (positive? height) (<= (* width height) max-pixels))
      (invalid "image exceeds the pixel limit or has invalid dimensions."))
    (cond
      [(eq? kind 'webp) (validate-webp-pixels raw width height)]
      [else
       (define bitmap (read-bitmap (open-input-bytes raw) kind #f #t))
       (unless (and (send bitmap ok?) (= width (send bitmap get-width)) (= height (send bitmap get-height)))
         (invalid))])
    (image-info mime width height (bytes-length raw))))
