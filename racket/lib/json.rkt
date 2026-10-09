#lang racket/base
;; SPDX-License-Identifier: AGPL-3.0-only

(require json racket/port racket/string)
(provide parse-json)

(define (parse-json raw)
  (define input (if (bytes? raw) (open-input-bytes raw) (open-input-string raw)))
  (define value (read-json input))
  (unless (and (not (eof-object? value)) (string=? "" (string-trim (port->string input))))
    (error 'json "Expected one JSON value"))
  value)
