#lang racket/base
;; SPDX-License-Identifier: AGPL-3.0-only

(require json net/http-client openssl racket/match racket/string "common.rkt" "x-errors.rkt")
(provide request current-transport json-request read-response (struct-out exn:fail:x-http))

(define (read-response status headers input limit
                       #:operation [operation "X API request"] #:write? [write? #t])
  (define matched (regexp-match #rx#"^HTTP/[0-9.]+ ([0-9][0-9][0-9])(?: |$)" status))
  (unless matched (bridge-error (string-append operation ": invalid HTTP status." (outcome-guidance write? operation))))
  (define code (string->number (bytes->string/latin-1 (cadr matched))))
  (define normalized
    (for/fold ([result (hash)]) ([header (in-list headers)])
      (match (regexp-match #rx#"^([^:]+):[ \t]*(.*)$" header)
        [(list _ name value)
         (hash-set result (string-downcase (bytes->string/latin-1 name))
                   (string-trim (bytes->string/latin-1 value)))]
        [_ result])))
  (unless (<= 200 code 299)
    ;; Error bodies have a separate small limit, including OAuth responses.
    (define bound (min limit (* 16 1024)))
    (define value
      (with-handlers ([exn:fail? (lambda (_) #f)])
        (define raw (read-bytes (add1 bound) input))
        (and (bytes? raw) (<= (bytes-length raw) bound) (parse-json raw))))
    (raise-x-http code normalized value operation write?))
  (define data (read-bytes (add1 limit) input))
  (when (and (bytes? data) (> (bytes-length data) limit))
    (bridge-error (string-append operation ": response exceeds the local size limit." (outcome-guidance write? operation))))
  (values normalized (if (eof-object? data) #"" data)))

(define (request url #:method [method "GET"] #:headers [headers (hash)]
                 #:body [body #f] #:limit [limit (* 8 1024 1024)])
  (define operation (operation-name url))
  (define write? (not (member method '("GET" "HEAD"))))
  ;; Callers construct URLs from fixed official endpoints or the CDN allowlist.
  (define matched (and (string? url) (regexp-match #px"^https://(api\\.x\\.com|pbs\\.twimg\\.com)(/[^\r\n ]*)$" url)))
  (unless matched (bridge-error "HTTP: only official X HTTPS endpoints are supported."))
  (unless (for/and ([(key value) (in-hash headers)])
            (and (string? key) (string? value)
                 (not (regexp-match? #rx"[\r\n]" (string-append key value)))))
    (bridge-error "HTTP: invalid request headers; check local authentication configuration."))
  (with-handlers ([exn:fail:bridge? raise]
                  [exn:fail? (lambda (_)
                               (bridge-error (string-append operation ": connection or TLS failed; check connectivity and trust roots." (outcome-guidance write? operation))))])
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
                     (lambda () (read-response status response-headers input limit #:operation operation #:write? write?))
                     (lambda () (close-input-port input))))
     (string-append operation ": request timed out; check connectivity." (outcome-guidance write? operation)))))

(define current-transport (make-parameter request))

(define (json-request url #:method [method "GET"] #:headers [headers (hash)] #:payload [payload #f])
  (define operation (operation-name url))
  (define write? (not (member method '("GET" "HEAD"))))
  (define-values (response-headers raw)
    ((current-transport) url #:method method
                         #:headers (if payload (hash-set headers "Content-Type" "application/json") headers)
                         #:body (and payload (jsexpr->bytes payload)) #:limit (* 1024 1024)))
  (define value
    (with-handlers ([exn:fail? (lambda (_) (bridge-error (string-append operation ": invalid JSON response." (outcome-guidance write? operation))))])
      (parse-json raw)))
  (unless (hash? value) (bridge-error (string-append operation ": expected a JSON object." (outcome-guidance write? operation))))
  (when (and (hash-has-key? value 'errors) (not (equal? (hash-ref value 'errors) '())))
    (bridge-error (string-append operation ": response contains errors or partial results. "
                                 (safe-problem-summary value) (retry-guidance response-headers)
                                 (outcome-guidance write? operation))))
  value)
