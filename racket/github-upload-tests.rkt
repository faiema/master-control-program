#lang racket/base
;; SPDX-License-Identifier: AGPL-3.0-only
(require rackunit json net/base64 racket/list racket/runtime-path racket/string
         "common.rkt" "github-http.rkt" "github-media.rkt" "github-upload.rkt"
         "media.rkt" "chatgpt-file.rkt" "server.rkt" "lib/cancellation.rkt")
(define-runtime-path images "../tests/fixtures/images.json")
(define fixtures (call-with-input-file images read-json))
(define png (base64-decode (string->bytes/utf-8 (hash-ref fixtures 'png))))
(define commit-sha (make-string 40 #\a))
(define old-sha (make-string 40 #\b))
(define (receipt raw path)
  (jsexpr->bytes (hasheq 'content (hasheq 'sha (github-blob-sha raw) 'path path)
                        'commit (hasheq 'sha commit-sha))))
(define (upload [encoded (hash-ref fixtures 'png)] #:sha [sha 'null])
  (upload-github-image "owner/repo" "images/face.png" "art" "Add reference"
                       #:image-base64 encoded #:expected-sha sha))
(module+ test
  (test-case "disabled write gate precedes downloads, credentials and requests"
    (parameterize ([current-github-token (lambda () (error "no credentials"))]
                   [current-file-download (lambda args (error "no download"))]
                   [current-github-request (lambda args (error "no request"))])
      (check-exn #rx"writes are disabled" upload)
      (check-false (findf (lambda (t) (equal? (hash-ref t 'name) "upload_github_image")) (tool-list)))))
  (test-case "create and replacement payloads preserve bytes with explicit branch and SHA"
    (for ([sha (list 'null old-sha)])
      (parameterize ([current-github-writes-enabled #t]
                     [current-github-request
                      (lambda (target accept limit #:payload payload)
                        (check-equal? target "/repos/owner/repo/contents/images/face.png")
                        (check-equal? accept "application/vnd.github+json")
                        (check-equal? (hash-ref payload 'branch) "art")
                        (check-equal? (hash-ref payload 'message) "Add reference")
                        (check-equal? (hash-ref payload 'sha 'null) sha)
                        (check-equal? (base64-decode (string->bytes/utf-8 (hash-ref payload 'content))) png)
                        (receipt png "images/face.png"))])
        (define result (upload #:sha sha))
        (check-equal? (hash-ref result 'blob_sha) (github-blob-sha png))
        (check-equal? (hash-ref result 'commit_sha) commit-sha)
        (check-equal? (hash-ref result 'operation) (if (eq? sha 'null) "create" "replace")))))
  (test-case "all image formats supported without conversion"
    (for ([kind '(png jpeg webp)] [path '("ref.png" "ref.jpeg" "ref.webp")])
      (define encoded (hash-ref fixtures kind))
      (define raw (base64-decode (string->bytes/utf-8 encoded)))
      (parameterize ([current-github-writes-enabled #t]
                     [current-github-request
                      (lambda (target accept limit #:payload payload)
                        (check-equal? (hash-ref payload 'content) encoded)
                        (receipt raw path))])
        (check-equal? (hash-ref (upload-github-image "o/r" path "main" "Image" #:image-base64 encoded) 'blob_sha)
                      (github-blob-sha raw)))))
  (test-case "file input uses credential-free downloader and omits signed URL from receipt"
    (parameterize ([current-github-writes-enabled #t]
                   [current-file-inputs-enabled #t]
                   [current-file-hosts '("files.example.test")]
                   [current-file-download (lambda (host target) (values png "image/png"))]
                   [current-github-request (lambda (target accept limit #:payload payload) (receipt png "ref.png"))])
      (define result
        (upload-github-image "o/r" "ref.png" "main" "Image"
                             #:file (hasheq 'download_url "https://files.example.test/image?signature=SECRET" 'file_id "test")))
      (check-false (regexp-match? #rx"SECRET|download_url" (jsexpr->string result)))))
  (test-case "invalid targets, messages, sources, SHAs and mismatched extensions never write"
    (parameterize ([current-github-writes-enabled #t]
                   [current-github-request (lambda args (error "Unexpected write"))])
      (for ([thunk (list
                    (lambda () (upload-github-image "o/r" "../a.png" "main" "Image" #:image-base64 (hash-ref fixtures 'png)))
                    (lambda () (upload-github-image "o/r" "a.png" "" "Image" #:image-base64 (hash-ref fixtures 'png)))
                    (lambda () (upload-github-image "o/r" "a.png" "main" "  " #:image-base64 (hash-ref fixtures 'png)))
                    (lambda () (upload-github-image "o/r" "a.jpg" "main" "Image" #:image-base64 (hash-ref fixtures 'png)))
                    (lambda () (upload #:sha "bad"))
                    (lambda () (upload "not-base64"))
                    (lambda () (upload-github-image "o/r" "a.png" "main" "Image"))
                    (lambda () (upload-github-image "o/r" "a.png" "main" "Image" #:image-base64 "x" #:file (hasheq))))])
        (check-exn exn:fail:bridge? thunk))))
  (test-case "missing credentials fail before submission"
    (parameterize ([current-github-writes-enabled #t]
                   [current-github-token (lambda () #f)]
                   [current-github-sendrecv (lambda args (error "Unexpected request"))])
      (check-exn #rx"Contents: write" upload)))
  (test-case "PUT transport sends auth and JSON; cancellation stops before submission"
    (define state (make-request-state))
    (parameterize ([current-github-writes-enabled #t]
                   [current-request-state state]
                   [current-github-token (lambda () "synthetic_token")]
                   [current-github-sendrecv
                    (lambda (host target #:ssl? ssl #:content-decode decode #:headers headers #:method method #:data body)
                      (check-equal? host "api.github.com")
                      (check-equal? method "PUT")
                      (check-not-false (member "Authorization: Bearer synthetic_token" headers))
                      (check-not-false (member "Content-Type: application/json" headers))
                      (check-equal? (hash-ref (bytes->jsexpr body) 'branch) "art")
                      (check-equal? (request-cancel! state) 'submitted)
                      (values #"HTTP/1.1 201 Created" '() (open-input-bytes (receipt png "images/face.png"))))])
      (check-equal? (hash-ref (upload) 'commit_sha) commit-sha))
    (define cancelled-state (make-request-state))
    (request-cancel! cancelled-state)
    (parameterize ([current-github-writes-enabled #t]
                   [current-request-state cancelled-state]
                   [current-github-token (lambda () "synthetic_token")]
                   [current-github-sendrecv (lambda args (error "Must not submit"))])
      (check-exn exn:cancelled? upload)))
  (test-case "conflicts and uncertain HTTP outcomes never trigger automatic retry"
    (for ([code '(302 403 409 422 500)])
      (define calls 0)
      (parameterize ([current-github-writes-enabled #t]
                     [current-github-token (lambda () "synthetic_token")]
                     [current-github-sendrecv
                      (lambda (host target #:ssl? ssl #:content-decode decode #:headers headers #:method method #:data body)
                        (set! calls (add1 calls))
                        (values (string->bytes/utf-8 (format "HTTP/1.1 ~a Status" code)) '() (open-input-bytes #"SECRET")))])
        (check-exn (lambda (e) (and (exn:fail:bridge? e)
                                   (regexp-match? #rx"No automatic retry" (exn-message e))
                                   (not (regexp-match? #rx"SECRET" (exn-message e)))))
                   (lambda () (upload #:sha old-sha))))
      (check-equal? calls 1)))
  (test-case "malformed or inconsistent successful response warns about uncertain commit"
    (for ([raw (list #"broken" #"{}" (receipt #"other" "images/face.png") (receipt png "wrong.png"))])
      (parameterize ([current-github-writes-enabled #t]
                     [current-github-request (lambda (target accept limit #:payload payload) raw)])
        (check-exn #rx"commit may have succeeded" upload))))
  (test-case "write annotation and file schema are independent of X writes"
    (parameterize ([current-github-writes-enabled #t] [current-file-inputs-enabled #t])
      (define tool (findf (lambda (t) (equal? (hash-ref t 'name) "upload_github_image")) (tool-list)))
      (check-false (hash-ref (hash-ref tool 'annotations) 'readOnlyHint))
      (check-false (hash-ref (hash-ref tool 'annotations) 'idempotentHint))
      (check-true (hash-ref (hash-ref tool 'annotations) 'destructiveHint))
      (check-equal? (hash-ref (hash-ref tool '_meta) 'openai/fileParams) '("file")))))
