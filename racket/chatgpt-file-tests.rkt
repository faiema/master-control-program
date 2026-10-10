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
                    '("fetch_x_media" "fetch_github_image" "inspect_chatgpt_image"))
      (define tool (caddr (tool-list)))
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

  (test-case "configuration accepts exact hostnames only"
    (define env (make-environment-variables))
    (parameterize ([current-environment-variables env])
      (check-equal? (file-hosts-from-environment) '())
      (environment-variables-set! env #"MCP_CHATGPT_FILE_HOSTS" #"files.example.test")
      (check-equal? (file-hosts-from-environment) '("files.example.test"))
      (for ([bad '(#"*.example.test" #"https://files.example.test" #"127.0.0.1" #"localhost" #"files.example.test:443")])
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
