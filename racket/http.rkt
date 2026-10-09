#lang racket/base
;; SPDX-License-Identifier: AGPL-3.0-only

(require json net/http-client openssl racket/match racket/string "common.rkt")
(provide request current-transport json-request read-response)

(define (read-response status headers input limit)
  (define matched (regexp-match #rx#"^HTTP/[0-9.]+ ([0-9][0-9][0-9])(?: |$)" status))
  (unless matched (bridge-error "HTTP: invalid response status; check connectivity."))
  (define code (string->number (bytes->string/latin-1 (cadr matched))))
  (unless (<= 200 code 299)
    (bridge-error
     (format "HTTP ~a: ~a Writes are not retried; check X before resubmitting."
             code (case code
                    [(401) "Authenticate again with racket racket/login.rkt."]
                    [(403) "Check endpoint access, app permissions, and scopes."]
                    [(429) "Rate limited; wait before retrying."]
                    [else "Check the endpoint and account access."]))))
  (define data (read-bytes (add1 limit) input))
  (when (and (bytes? data) (> (bytes-length data) limit))
    (bridge-error "HTTP: response exceeds the local size limit; use a smaller image. Check X before repeating a write."))
  (define normalized
    (for/fold ([result (hash)]) ([header (in-list headers)])
      (match (regexp-match #rx#"^([^:]+):[ \t]*(.*)$" header)
        [(list _ name value)
         (hash-set result (string-downcase (bytes->string/latin-1 name))
                   (string-trim (bytes->string/latin-1 value)))]
        [_ result])))
  (values normalized (if (eof-object? data) #"" data)))

(define (request url #:method [method "GET"] #:headers [headers (hash)]
                 #:body [body #f] #:limit [limit (* 8 1024 1024)])
  ;; Callers construct URLs from fixed official endpoints or the CDN allowlist.
  (define matched (and (string? url) (regexp-match #px"^https://(api\\.x\\.com|pbs\\.twimg\\.com)(/[^\r\n ]*)$" url)))
  (unless matched (bridge-error "HTTP: only official X HTTPS endpoints are supported."))
  (unless (for/and ([(key value) (in-hash headers)])
            (and (string? key) (string? value)
                 (not (regexp-match? #rx"[\r\n]" (string-append key value)))))
    (bridge-error "HTTP: invalid request headers; check local authentication configuration."))
  (with-handlers ([exn:fail:bridge? raise]
                  [exn:fail? (lambda (_)
                               (bridge-error "HTTP: connection or TLS failed. Check connectivity and trust roots. A write may have succeeded; check X before resubmitting."))])
    (call/bounded
     30
     (lambda ()
       (define-values (status response-headers input)
         (http-sendrecv (cadr matched) (caddr matched)
                        #:ssl? (ssl-secure-client-context)
                        #:method method #:data body #:content-decode '()
                        #:headers (cons "User-Agent: master-control-program/0.1"
                                        (for/list ([(key value) (in-hash headers)])
                                          (string-append key ": " value)))))
       (dynamic-wind void
                     (lambda () (read-response status response-headers input limit))
                     (lambda () (close-input-port input))))
     "HTTP: request timed out. A write may have succeeded; check X before resubmitting.")))

(define current-transport (make-parameter request))

(define (json-request url #:method [method "GET"] #:headers [headers (hash)] #:payload [payload #f])
  (define-values (_ raw)
    ((current-transport) url #:method method
                         #:headers (if payload (hash-set headers "Content-Type" "application/json") headers)
                         #:body (and payload (jsexpr->bytes payload)) #:limit (* 1024 1024)))
  (define value
    (with-handlers ([exn:fail? (lambda (_) (bridge-error "X API: invalid JSON response. A write may have succeeded; check X before retrying."))])
      (parse-json raw)))
  (unless (hash? value) (bridge-error "X API: expected a JSON object. Check X before repeating a write."))
  (when (and (hash-has-key? value 'errors) (not (equal? (hash-ref value 'errors) '())))
    (bridge-error "X API: response contains errors or partial results. Check X before repeating a write."))
  value)
