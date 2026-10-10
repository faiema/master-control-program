#lang racket/base
;; SPDX-License-Identifier: AGPL-3.0-only

(require racket/string net/uri-codec "common.rkt" "media.rkt" "chatgpt-file.rkt"
         "github-media.rkt" "github-http.rkt")
(provide current-github-writes-enabled upload-github-image)

(define current-github-writes-enabled (make-parameter #f))
(define (sha? value) (and (string? value) (regexp-match? #px"^[0-9a-f]{40}$" value)))

(define (upload-github-image repository path branch message
                             #:image-base64 [encoded #f] #:file [file #f]
                             #:expected-sha [expected-sha 'null])
  ;; Independent of X's write gate. Check before credentials or file downloads.
  (unless (current-github-writes-enabled)
    (bridge-error "Configuration: GitHub writes are disabled. Set MCP_GITHUB_ENABLE_WRITES=1; upload only on explicit user request."))
  (define target (github-file-target repository path))
  (unless (and (string? branch) (<= 1 (string-length branch) 1024)
               (not (regexp-match? #px"[\u0000-\u0020\u007f]" branch)))
    (bridge-error "Validation: branch must name the destination branch explicitly."))
  (unless (and (string? message) (<= 1 (string-length message) 4096)
               (not (string=? (string-trim message) ""))
               (not (regexp-match? #rx"\u0000" message)))
    (bridge-error "Validation: provide a nonempty commit message of at most 4096 characters."))
  (unless (or (eq? expected-sha 'null) (sha? expected-sha))
    (bridge-error "Validation: expected_sha must be the current 40-character blob SHA, or omitted for create-only."))
  (unless (= 1 (+ (if encoded 1 0) (if file 1 0)))
    (bridge-error "Validation: supply exactly one of file or image_base64."))
  (when (and file (not (or (current-file-inputs-enabled) (pair? (current-file-hosts)))))
    (bridge-error "Configuration: ChatGPT file inputs are disabled."))
  (define-values (raw metadata)
    (if file (read-chatgpt-image file) (decode-upload encoded #:allow-webp? #t)))
  (define suffix
    (case (string->symbol (hash-ref metadata 'mime_type))
      [(image/png) #px"(?i:\\.png)$"]
      [(image/jpeg) #px"(?i:\\.jpe?g)$"]
      [(image/webp) #px"(?i:\\.webp)$"]))
  (unless (regexp-match? suffix path)
    (bridge-error "Validation: destination must end in .png, .jpg/.jpeg, or .webp matching the image bytes."))
  (define blob-sha (github-blob-sha raw))
  (define payload (hasheq 'message message 'branch branch 'content (encode-base64 raw)))
  ;; Omitted SHA means create-only at GitHub. Never look up a SHA and silently
  ;; turn a failed create into an overwrite; stale supplied SHAs must conflict.
  (define response
    ((current-github-request) target "application/vnd.github+json" (* 1024 1024)
                              #:payload (if (eq? expected-sha 'null) payload
                                            (hash-set payload 'sha expected-sha))))
  (define value
    (with-handlers ([exn:fail? (lambda (_) (bridge-error "GitHub upload: invalid response. A commit may have succeeded; check the destination before retrying."))])
      (parse-json response)))
  (define content (and (hash? value) (hash-ref value 'content #f)))
  (define commit (and (hash? value) (hash-ref value 'commit #f)))
  (unless (and (hash? content) (equal? (hash-ref content 'path #f) path)
               (equal? (hash-ref content 'sha #f) blob-sha)
               (hash? commit) (sha? (hash-ref commit 'sha #f)))
    (bridge-error "GitHub upload: response does not confirm the expected file and blob SHA. A commit may have succeeded; inspect the destination before retrying."))
  (define commit-sha (hash-ref commit 'sha))
  (hash-set* metadata 'repository_full_name repository 'path path 'branch branch
             'blob_sha blob-sha 'commit_sha commit-sha
             'operation (if (eq? expected-sha 'null) "create" "replace")
             'url (string-append "https://github.com/" repository "/blob/" commit-sha "/"
                                 (string-join (map uri-encode (string-split path "/")) "/"))))
