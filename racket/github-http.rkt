#lang racket/base
;; SPDX-License-Identifier: AGPL-3.0-only

;; GitHub credentials never enter the X or file-download transports.
(require net/http-client openssl racket/string "common.rkt")
(provide current-github-request current-github-token current-github-sendrecv github-request read-github-response)

(define current-github-token (make-parameter (lambda () (getenv "MCP_GITHUB_TOKEN"))))
(define current-github-sendrecv (make-parameter http-sendrecv))

(define (read-github-response status headers input limit)
  (define matched (regexp-match #rx#"^HTTP/[0-9.]+ ([0-9][0-9][0-9])(?: |$)" status))
  (unless matched (bridge-error "GitHub: invalid HTTP status."))
  (define code (string->number (bytes->string/latin-1 (cadr matched))))
  (unless (= code 200)
    ;; Never echo upstream bodies, redirect targets, or credential-bearing URLs.
    (bridge-error
     (format "GitHub: HTTP ~a. ~a" code
             (cond [(= code 401) "Authentication failed; replace MCP_GITHUB_TOKEN with a valid token."]
                   [(= code 404) "Repository, path, or ref was not found, or is private. Check the inputs and the token's repository access."]
                   [(= code 403) "Access denied or rate limited. Check Contents: read permission, organization authorization, and GitHub rate limits before retrying."]
                   [(= code 429) "Rate limited; wait before retrying."]
                   [(<= 300 code 399) "Redirect refused. Use the repository's current owner/name; credentials were not forwarded."]
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
    (bridge-error "GitHub: truncated response; retry the read."))
  raw)

(define (github-request target accept limit)
  (unless (and (string? target) (regexp-match? #px"^/repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/(?:contents/|git/blobs/)[^\r\n ]+$" target)
               (member accept '("application/vnd.github.object+json" "application/vnd.github.raw+json")))
    (bridge-error "GitHub: invalid internal request target."))
  (define token ((current-github-token)))
  (unless (or (not token) (and (string? token) (regexp-match? #px"^[A-Za-z0-9_]+$" token)))
    (bridge-error "GitHub: MCP_GITHUB_TOKEN must contain only the token, without whitespace."))
  (with-handlers ([exn:fail:bridge? raise]
                  [exn:fail? (lambda (_) (bridge-error "GitHub: connection or TLS failed; check connectivity and trust roots, then retry the read."))])
    (call/bounded
     30
     (lambda ()
       (define-values (status headers input)
         ((current-github-sendrecv) "api.github.com" target #:ssl? (ssl-secure-client-context)
                        #:content-decode '()
                        #:headers (append
                                   (list "User-Agent: master-control-program/0.1"
                                         "X-GitHub-Api-Version: 2026-03-10"
                                         (string-append "Accept: " accept))
                                   (if token (list (string-append "Authorization: Bearer " token)) '()))))
       (dynamic-wind void
                     (lambda () (read-github-response status headers input limit))
                     (lambda () (close-input-port input))))
     "GitHub: request timed out; retry the read.")))

(define current-github-request (make-parameter github-request))
