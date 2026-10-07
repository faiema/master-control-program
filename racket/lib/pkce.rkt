#lang racket/base

(require net/base64 racket/random racket/string)
(provide base64url random-state make-pkce)

(define (base64url raw)
  (string-replace
   (string-replace (regexp-replace #rx"=+$" (bytes->string/utf-8 (base64-encode raw #"")) "") "+" "-")
   "/" "_"))

(define (random-state) (base64url (crypto-random-bytes 32)))

(define (make-pkce)
  (define verifier (base64url (crypto-random-bytes 48)))
  (values verifier (base64url (sha256-bytes (string->bytes/utf-8 verifier)))))
