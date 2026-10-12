#lang racket/base
;; SPDX-License-Identifier: AGPL-3.0-only

;; GitHub credentials never enter the X or file-download transports.
(require json "lib/cancellation.rkt" net/http-client openssl racket/string "common.rkt")
(provide (struct-out exn:fail:github) current-github-request current-github-token current-github-sendrecv github-request read-github-response)

(struct exn:fail:github exn:fail:bridge (status) #:transparent)
(define (github-http-error code message)
  (raise (exn:fail:github message (current-continuation-marks) code)))

(define current-github-token (make-parameter (lambda () (getenv "MCP_GITHUB_TOKEN"))))
(define current-github-sendrecv (make-parameter http-sendrecv))

(define (read-github-response status headers input limit #:write? [write? #f])
  (define matched (regexp-match #rx#"^HTTP/[0-9.]+ ([0-9][0-9][0-9])(?: |$)" status))
  (unless matched (bridge-error "GitHub: invalid HTTP status."))
  (define code (string->number (bytes->string/latin-1 (cadr matched))))
  (unless (or (= code 200) (and write? (= code 201)))
    ;; Never echo upstream bodies, redirect targets, or credential-bearing URLs.
    (github-http-error code
     (format "GitHub: HTTP ~a. ~a" code
             (cond [(= code 401) "Authentication failed; replace MCP_GITHUB_TOKEN with a valid token."]
                   [(= code 404) "Repository, path, or ref was not found, or is private. Check the inputs and the token's repository access."]
                   [(= code 403) (if write? "Access denied or rate limited. Check Contents: write permission, branch rules, organization authorization, and rate limits." "Access denied or rate limited. Check Contents: read permission, organization authorization, and GitHub rate limits before retrying.")]
                   [(= code 429) "Rate limited; wait before retrying."]
                   [(<= 300 code 399) "Redirect refused. Use the repository's current owner/name; credentials were not forwarded."]
                   [(member code '(409 422)) "Conflict or validation failure. Check the branch and current file SHA; do not overwrite or retry blindly."]
                   [(>= code 500) "Service failure; retry later."]
                   [else "Request rejected; check repository, path, and ref."]))))
  (define raw (read-bytes (add1 limit) input))
  (unless (and (bytes? raw) (<= 1 (bytes-length raw) limit))
    (bridge-error "GitHub: empty response or response exceeds the local size limit."))
  (define length-header
    (for/or ([header (in-list headers)])
      (define m (regexp-match #px#"(?i:^content-length:[ \t]*([0-9]+)[ \t]*$)" header))
      (and m (string->number (bytes->string/latin-1 (cadr m))))))
  (when (and length-header (not (= length-header (bytes-length raw))))
    (bridge-error "GitHub: truncated response; received length does not match Content-Length."))
  raw)

(define (github-request target accept limit #:payload [payload #f])
  (define write? (and payload #t))
  (unless (and (string? target) (regexp-match? #px"^/repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/(?:contents/|git/blobs/)[^\r\n ]+$" target)
               (member accept '("application/vnd.github.object+json" "application/vnd.github.raw+json" "application/vnd.github+json")))
    (bridge-error "GitHub: invalid internal request target."))
  (when (and write? (not (and (hash? payload) (regexp-match? #px"^/repos/[^/]+/[^/]+/contents/[^?]+$" target))))
    (bridge-error "GitHub: writes require a contents endpoint without query parameters."))
  (define token ((current-github-token)))
  (when (and write? (not token))
    (bridge-error "GitHub: uploads require MCP_GITHUB_TOKEN with Contents: write permission."))
  (unless (or (not token) (and (string? token) (regexp-match? #px"^[A-Za-z0-9_]+$" token)))
    (bridge-error "GitHub: MCP_GITHUB_TOKEN must contain only the token, without whitespace."))
  (define body (and payload (jsexpr->bytes payload)))
  (define (guidance message)
    (if write? (string-append message " A commit may have succeeded; check the destination before retrying. No automatic retry occurred.") message))
  ;; Cross the cancellation boundary in the tool thread, before bounded I/O.
  (when write? (mark-side-effect-started!))
  (with-handlers ([exn:fail:github? (lambda (e) (github-http-error (exn:fail:github-status e) (guidance (exn-message e))))]
                  [exn:fail:bridge? (lambda (e) (bridge-error (guidance (exn-message e))))]
                  [exn:fail? (lambda (_) (bridge-error (guidance "GitHub: connection or TLS failed; check connectivity and trust roots.")))])
    (call/bounded
     30
     (lambda ()
       (define-values (status headers input)
         ((current-github-sendrecv) "api.github.com" target #:ssl? (ssl-secure-client-context)
                        #:method (if write? "PUT" "GET") #:data body
                        #:content-decode '()
                        #:headers (append
                                   (list "User-Agent: master-control-program/0.1"
                                         "X-GitHub-Api-Version: 2026-03-10"
                                         (string-append "Accept: " accept))
                                   (if token (list (string-append "Authorization: Bearer " token)) '())
                                   (if write? '("Content-Type: application/json") '()))))
       (dynamic-wind void
                     (lambda () (read-github-response status headers input limit #:write? write?))
                     (lambda () (close-input-port input))))
     "GitHub: request timed out.")))

(define current-github-request (make-parameter github-request))
