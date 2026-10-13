#lang racket/base
;; SPDX-License-Identifier: AGPL-3.0-only

(require json rackunit racket/list "chatgpt-file.rkt" "common.rkt" "media.rkt"
         "server.rkt" "auth.rkt" "http.rkt" "x-api.rkt")
(define png64 "iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAIAAAASFvFNAAAAEElEQVR4nGP8zwAFTDAGAwATKQED8NgHhAAAAABJRU5ErkJggg==")
(define-values (png metadata) (decode-upload png64))
(define url "https://files.example.test/image?signature=synthetic-secret")
(define file (hasheq 'download_url url 'file_id "synthetic-file"))
(define (download host target)
  (check-equal? host "files.example.test")
  (check-equal? target "/image?signature=synthetic-secret")
  (values png "application/octet-stream"))

(module+ test
  (test-case "file tools are opt-in, read-only handoff preserves bytes and hides capabilities"
    (parameterize ([current-file-hosts '("files.example.test")]
                   [current-file-download download]
                   [current-token-provider (lambda () (error "must not read credentials"))]
                   [current-transport (lambda args (error "must not call X"))])
      (check-equal? (map (lambda (t) (hash-ref t 'name)) (tool-list))
                    '("fetch_x_media" "fetch_github_image" "fetch_github_text" "inspect_chatgpt_image"))
      (define tool (cadddr (tool-list)))
      (check-equal? (hash-ref (hash-ref tool '_meta) 'openai/fileParams) '("file"))
      (define result (call-tool "inspect_chatgpt_image" (hasheq 'file file)))
      (check-equal? (hash-ref (cadr (hash-ref result 'content)) 'data) png64)
      (check-false (regexp-match? #rx"synthetic-secret|synthetic-file|download_url" (jsexpr->string result)))))

  (test-case "file references reject unapproved destinations and malformed objects before I/O"
    (parameterize ([current-file-hosts '("files.example.test")]
                   [current-file-download (lambda args (error "download should not occur"))])
      (for ([bad-url (list "http://files.example.test/image" "https://127.0.0.1/image"
                          "https://files.example.test.evil/image" "https://files.example.test:443/image"
                          "https://files.example.test@localhost/image" "https://files.example.test/image#fragment"
                          "https://files.example.test/image\r\nX: bad" "https://files.example.test\\@localhost/image")])
        (check-exn exn:fail:bridge? (lambda () (read-chatgpt-image (hash-set file 'download_url bad-url)))))
      (for ([bad (list (hasheq) (hash-remove file 'file_id) (hash-set file 'file_id "")
                       (hash-set file 'extra "bad") (hash-set file 'mime_type 42))])
        (check-exn exn:fail:bridge? (lambda () (read-chatgpt-image bad)))))
    (check-exn exn:fail:bridge? (lambda () (read-chatgpt-image file))))

  (test-case "file MIME and actual image validation precede uploads"
    (parameterize ([current-file-hosts '("files.example.test")]
                   [current-file-download download])
      (check-exn #rx"MIME" (lambda () (read-chatgpt-image (hash-set file 'mime_type "image/jpeg")))))
    (for ([raw (list #"not an image" (make-bytes (add1 max-image-bytes)))])
      (parameterize ([current-file-hosts '("files.example.test")]
                     [current-file-download (lambda args (values raw #f))])
        (check-exn exn:fail:bridge? (lambda () (read-chatgpt-image file))))))

  (test-case "file upload is gated, mutually exclusive and translates original bytes once"
    (define writes 0)
    (parameterize ([current-file-hosts '("files.example.test")]
                   [current-file-download download]
                   [current-token-provider (lambda () "synthetic-token")]
                   [current-transport
                    (lambda (url #:method method #:headers headers #:body body #:limit limit)
                      (set! writes (add1 writes))
                      (check-equal? url "https://api.x.com/2/media/upload")
                      (check-equal? (hash-ref (parse-json body) 'media) png64)
                      (values (hash) #"{\"data\":{\"id\":\"123\"}}"))])
      (check-exn exn:fail? (lambda () (call-tool "upload_x_media" (hasheq 'file file))))
      (parameterize ([current-writes-enabled #t])
        (check-true (hash-ref (call-tool "upload_x_media" (hasheq)) 'isError))
        (check-true (hash-ref (call-tool "upload_x_media" (hasheq 'file file 'image_base64 png64)) 'isError))
        (check-equal? writes 0)
        (define result (call-tool "upload_x_media" (hasheq 'file file)))
        (check-false (hash-ref result 'isError #f))
        (check-false (regexp-match? #rx"synthetic-secret" (jsexpr->string result))))
      (check-equal? writes 1)))

  (test-case "storage family wildcard is opt-in and tightly bounded"
    (define (reference host)
      (hash-set file 'download_url (string-append "https://" host "/image?signature=synthetic-secret")))
    (define approved '("oaisdmntprwestus.blob.core.windows.net"
                       "oaisdmntprwestus3.blob.core.windows.net"
                       "oaisdmntpreastus2.blob.core.windows.net"))
    (parameterize ([current-file-hosts '()]
                   [current-file-download (lambda args (error "must not download"))])
      (for ([host approved])
        (check-exn exn:fail:bridge? (lambda () (read-chatgpt-image (reference host))))))
    (parameterize ([current-file-hosts '("oaisdmntpr*.blob.core.windows.net")]
                   [current-file-download (lambda (host target) (values png "image/png"))])
      (for ([host (append approved (list (string-append "oaisdmntpr" (make-string 15 #\a) ".blob.core.windows.net")))])
        (define-values (raw info) (read-chatgpt-image (reference host)))
        (check-equal? raw png))
      (parameterize ([current-file-download (lambda args (error "must not download"))])
        (for ([host (list "other.blob.core.windows.net" "oaisdmntpr.blob.core.windows.net"
                          "oaisdmntprwestus.blob.core.windows.net.evil.test"
                          "oaisdmntprwestus.evil.blob.core.windows.net"
                          "oaisdmntpr-westus.blob.core.windows.net"
                          "oaisdmntprWestus.blob.core.windows.net"
                          "oaisdmntprwestus.blob.core.windows.net:443"
                          "oaisdmntprwestus.blob.core.windows.net@localhost"
                          (string-append "oaisdmntpr" (make-string 16 #\a) ".blob.core.windows.net"))])
          (check-exn exn:fail:bridge? (lambda () (read-chatgpt-image (reference host))))))))

  (test-case "configuration accepts exact hosts and the one supported family wildcard"
    (define env (make-environment-variables))
    (parameterize ([current-environment-variables env])
      (check-equal? (file-hosts-from-environment) '())
      (environment-variables-set! env #"MCP_CHATGPT_FILE_HOSTS" #"files.example.test")
      (check-equal? (file-hosts-from-environment) '("files.example.test"))
      (environment-variables-set! env #"MCP_CHATGPT_FILE_HOSTS" #"files.example.test,oaisdmntpr*.blob.core.windows.net")
      (check-equal? (file-hosts-from-environment) '("files.example.test" "oaisdmntpr*.blob.core.windows.net"))
      (for ([bad '(#"*.example.test" #"*.blob.core.windows.net" #"oaisdmntpr*.evil.test" #"https://files.example.test" #"127.0.0.1" #"localhost" #"files.example.test:443")])
        (environment-variables-set! env #"MCP_CHATGPT_FILE_HOSTS" bad)
        (check-exn exn:fail:bridge? file-hosts-from-environment)))))

(module+ test
  (test-case "discovery mode reports only unapproved hostname, never signed URL"
    (parameterize ([current-file-inputs-enabled #t]
                   [current-file-download (lambda args (error "must not download"))])
      (define result (call-tool "inspect_chatgpt_image" (hasheq 'file file)))
      (check-true (hash-ref result 'isError))
      (check-true (regexp-match? #rx"files.example.test" (jsexpr->string result)))
      (check-false (regexp-match? #rx"signature|synthetic-secret" (jsexpr->string result))))))
