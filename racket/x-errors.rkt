#lang racket/base
;; SPDX-License-Identifier: AGPL-3.0-only

(require racket/list racket/string "common.rkt")
(provide (struct-out exn:fail:x-http) raise-x-http safe-problem-summary retry-guidance operation-name outcome-guidance)

;; Only status and a locally authored message survive the HTTP boundary.
(struct exn:fail:x-http exn:fail:bridge (status) #:transparent)
(define problems
  (hash "invalid-request" "Invalid request; check parameters."
        "resource-not-found" "Resource not found; check the post or media ID."
        "not-authorized-for-resource" "Resource access denied; check account permissions."
        "client-forbidden" "App access denied; check endpoint access and app permissions."
        "usage-capped" "Usage cap reached; check API usage and credits."
        "rate-limit-exceeded" "Rate limit reached; wait before retrying."))

;; Never echo arbitrary title/detail/message, URLs, parameters, or resource IDs.
;; Even a syntactically harmless upstream string could contain a credential.
(define (safe-problem-summary value)
  (define entries
    (if (hash? value)
        (cons value (let ([errors (hash-ref value 'errors '())])
                      (if (list? errors) (take errors (min 4 (length errors))) '())))
        '()))
  (string-join
   (remove-duplicates
    (append-map
     (lambda (entry)
       (if (hash? entry)
           (let* ([type (hash-ref entry 'type #f)]
                  [matched (and (string? type)
                                (regexp-match #px"^https://api[.](?:x|twitter)[.]com/2/problems/([a-z-]+)$" type))]
                  [description (and matched (hash-ref problems (cadr matched) #f))]
                  [code (hash-ref entry 'code #f)]
                  [oauth (hash-ref entry 'error #f)]
                  [oauth-description
                   (and (string? oauth)
                        (hash-ref (hash "invalid_grant" "OAuth invalid_grant: authorization expired or revoked; log in again."
                                        "invalid_client" "OAuth invalid_client: check the client ID and secret."
                                        "invalid_scope" "OAuth invalid_scope: check the app scopes."
                                        "unauthorized_client" "OAuth unauthorized_client: check app authentication settings."
                                        "temporarily_unavailable" "OAuth temporarily_unavailable: retry later.") oauth #f))])
             (append (if description (list description) '())
                     (if oauth-description (list oauth-description) '())
                     (if (and (exact-integer? code) (<= 0 code 9999))
                         (list (format "X error code ~a." code)) '())))
           '())) entries)) " "))

(define (bounded-number value maximum)
  (and (string? value) (regexp-match? #px"^[0-9]{1,10}$" value)
       (let ([n (string->number value)]) (and (<= n maximum) n))))

(define (retry-guidance headers [now (current-seconds)])
  (define after (bounded-number (hash-ref headers "retry-after" #f) 604800))
  (define reset (bounded-number (hash-ref headers "x-rate-limit-reset" #f) 4102444800))
  (define delay (and reset (< now reset) (<= (- reset now) 604800) (- reset now)))
  (if (or after delay)
      (format " Wait at least ~a seconds before considering a retry."
              (max (or after 0) (or delay 0)))
      ""))

(define (operation-name url)
  (cond [(equal? url "https://api.x.com/2/oauth2/token") "X authentication"]
        [(equal? url "https://api.x.com/2/media/upload") "X media upload"]
        [(equal? url "https://api.x.com/2/tweets") "X post creation"]
        [(and (string? url) (string-prefix? url "https://pbs.twimg.com/")) "X media retrieval"]
        [else "X API request"]))

(define (outcome-guidance write? [operation #f])
  (cond
    [(equal? operation "X authentication")
     " No automatic retry. Token exchange may have succeeded; log in again if refresh no longer works."]
    [write?
      " No automatic retry. A write may have succeeded; check X before resubmitting."]
    [else " No automatic retry."]))

(define (raise-x-http code headers value operation write?)
  (define summary (safe-problem-summary value))
  (define advice
    (case code
      [(400 422) "Request rejected; check parameters and required fields."]
      [(401) "Authentication rejected; check credentials or run racket racket/login.rkt."]
      [(402) "Check API credits and billing access."]
      [(403) "Access denied; check app permissions, scopes, and endpoint access."]
      [(404) "Resource or endpoint not found; check the requested ID."]
      [(409) "Request conflicts with current state; inspect the resource before retrying."]
      [(413) "Request too large; check the media size."]
      [(429) "Rate limit or usage cap reached; wait or check API usage and credits."]
      [else (cond [(<= 300 code 399) "Redirect refused; check the configured endpoint."]
                  [(<= 500 code 599) "X service failure; try again later."]
                  [else "Request failed; check endpoint and account access."])]))
  (raise (exn:fail:x-http
          (string-append (format "~a: HTTP ~a. ~a" operation code advice)
                         (if (equal? summary "") "" (string-append " " summary))
                         (if (or (= code 429) (<= 500 code 599)) (retry-guidance headers) "")
                         (outcome-guidance write? operation))
          (current-continuation-marks) code)))
