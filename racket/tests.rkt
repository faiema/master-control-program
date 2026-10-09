#lang racket/base
;; SPDX-License-Identifier: AGPL-3.0-only

(require json net/base64 rackunit racket/file racket/list racket/port racket/runtime-path
         "auth.rkt" "common.rkt" "http.rkt" "media.rkt" "server.rkt" "x-api.rkt"
         (prefix-in codec: "lib/image.rkt"))

;; Synthetic 3x2 red PNG, also used by the Python contract tests.
(define png (base64-decode #"iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAIAAAASFvFNAAAAEElEQVR4nGP8zwAFTDAGAwATKQED8NgHhAAAAABJRU5ErkJggg=="))
(define image-url "https://pbs.twimg.com/media/synthetic.png")
(define-runtime-path images-path "../tests/fixtures/images.json")
(define images (parse-json (file->bytes images-path)))
(define (fixture name) (base64-decode (string->bytes/utf-8 (hash-ref images name))))
(define (media-transport url #:limit limit)
  (values (hash "content-type" "image/png") png))
(define (response-transport raw)
  (lambda (url #:method method #:headers headers #:body body #:limit limit)
    (values (hash) raw)))
(define (rpc messages)
  (define output (open-output-string))
  (serve (open-input-string (string-append (apply string-append
                                                (map (lambda (m) (string-append (jsexpr->string m) "\n")) messages))))
         output)
  (define input (open-input-string (get-output-string output)))
  (let loop ([results '()])
    (define value (read-json input))
    (if (eof-object? value) (reverse results) (loop (cons value results)))))
(define initialize
  (hasheq 'jsonrpc "2.0" 'id 1 'method "initialize"
          'params (hasheq 'protocolVersion "2025-11-25" 'capabilities (hasheq)
                          'clientInfo (hasheq 'name "test" 'version "1"))))
(define initialized (hasheq 'jsonrpc "2.0" 'method "notifications/initialized"))

(module+ test
  (test-case "strict CDN URL allowlist"
    (check-equal? (media-url image-url) image-url)
    (check-equal? (media-url "https://pbs.twimg.com/media/a?format=jpg&name=orig")
                  "https://pbs.twimg.com/media/a?format=jpg&name=orig")
    (for ([url (in-list '("http://pbs.twimg.com/media/a.png" "https://pbs.twimg.com.evil/media/a.png"
                         "https://pbs.twimg.com@localhost/media/a.png" "file:///etc/passwd"
                         "https://pbs.twimg.com:443/media/a.png" "https://pbs.twimg.com/media/../a.png"
                         "https://pbs.twimg.com/media/a.png?token=secret" "https://pbs.twimg.com/media/a.png#x"
                         "https://pbs.twimg.com/media/a?format=jpg&format=png"
                         "https://pbs.twimg.com/media/a?name=orig&" "https://127.0.0.1/a"
                         "https://pbs.twimg.com/media/a.png\r\nHost: evil"))])
      (check-exn exn:fail:bridge? (lambda () (media-url url)))))

  (test-case "native decoder preserves metadata and original MCP bytes"
    (parameterize ([current-transport media-transport])
      (define result (fetch-result image-url "123" "3_456"))
      (define content (hash-ref result 'content))
      (define metadata (parse-json (hash-ref (car content) 'text)))
      (check-equal? (hash-ref metadata 'width) 3)
      (check-equal? (hash-ref metadata 'height) 2)
      (check-equal? (hash-ref metadata 'source_post_id) "123")
      (check-equal? (hash-ref (cadr content) 'mimeType) "image/png")
      (check-equal? (base64-decode (string->bytes/utf-8 (hash-ref (cadr content) 'data))) png)))

  (test-case "decoder rejects MIME mismatch, truncation, empty and unsupported bytes"
    (check-exn exn:fail:bridge? (lambda () (inspect-image png "image/jpeg")))
    (for ([raw (in-list (list #"" #"not an image" (subbytes png 0 24) (make-bytes (add1 max-image-bytes))))])
      (check-exn exn:fail:bridge? (lambda () (inspect-image raw)))))

  (test-case "missing MIME"
    (parameterize ([current-transport (lambda (url #:limit limit) (values (hash) png))])
      (check-exn exn:fail:bridge? (lambda () (fetch-result image-url)))))

  (test-case "JPEG PNG WebP and animation contracts through real helper"
    (for ([name '(jpeg png webp)] [mime '("image/jpeg" "image/png" "image/webp")])
      (define metadata (inspect-image (fixture name) mime))
      (check-equal? (hash-ref metadata 'mime_type) mime)
      (check-equal? (hash-ref metadata 'width) 3)
      (check-equal? (hash-ref metadata 'height) 2))
    (for ([name '(gif animated_png animated_webp)])
      (check-exn #rx"only static" (lambda () (inspect-image (fixture name))))))

  (test-case "WebP upload unsupported and blank MIME fails safely"
    (check-exn #rx"use JPEG or PNG" (lambda () (decode-upload (hash-ref images 'webp))))
    (check-exn #rx"Content-Type" (lambda () (inspect-image png ";"))))

  (test-case "native codecs support ordinary color modes and progressive JPEG"
    (for ([name '(jpeg_progressive jpeg_gray jpeg_cmyk png_alpha png_palette webp_lossless)])
      (define info (codec:inspect-static-image (fixture name) #:max-bytes max-image-bytes #:max-pixels 40000000))
      (check-equal? (codec:image-info-width info) 3)
      (check-equal? (codec:image-info-height info) 2)))

  (test-case "native codecs reject truncation and enforce limits before pixel allocation"
    (for ([name '(jpeg png webp)])
      (define raw (fixture name))
      (check-exn codec:exn:fail:image?
                 (lambda () (codec:inspect-static-image raw #:max-bytes max-image-bytes #:max-pixels 1)))
      (for ([end (list 1 (quotient (bytes-length raw) 2) (sub1 (bytes-length raw)))])
        (check-exn codec:exn:fail:image?
                   (lambda () (codec:inspect-static-image (subbytes raw 0 end) #:max-bytes max-image-bytes #:max-pixels 40000000)))))
    (define corrupt (bytes-copy png))
    (bytes-set! corrupt 50 (bitwise-xor 1 (bytes-ref corrupt 50)))
    (check-exn codec:exn:fail:image?
               (lambda () (codec:inspect-static-image corrupt #:max-bytes max-image-bytes #:max-pixels 40000000))))

  (test-case "strict base64 and upload bounds"
    (for ([encoded (in-list (list "not base64!" "data:image/png;base64,AA==" "AA" "AA==\n" (make-string (* 7 1024 1024) #\A)))])
      (check-exn exn:fail:bridge? (lambda () (decode-upload encoded))))
    (define-values (raw metadata) (decode-upload (encode-base64 png)))
    (check-equal? raw png)
    (check-equal? (hash-ref metadata 'mime_type) "image/png"))

  (test-case "HTTP status, redirection, body bounds, case-normalized MIME"
    (define-values (headers raw) (read-response #"HTTP/1.1 200 OK" '(#"Content-Type: image/png") (open-input-bytes png) 1000))
    (check-equal? raw png)
    (check-equal? (hash-ref headers "content-type") "image/png")
    (for ([code '(302 401 403 429 500)])
      (check-exn (regexp (number->string code))
                 (lambda () (read-response (string->bytes/utf-8 (format "HTTP/1.1 ~a secret" code)) '() (open-input-bytes #"secret") 10))))
    (check-exn exn:fail:bridge? (lambda () (read-response #"HTTP/1.1 200 OK" '() (open-input-bytes png) 5))))

  (test-case "bounded operations time out and propagate safe errors"
    (check-exn #rx"timeout" (lambda () (call/bounded 0.01 (lambda () (sync never-evt)) "timeout")))
    (check-exn #rx"safe" (lambda () (call/bounded 1 (lambda () (bridge-error "safe")) "timeout"))))

  (test-case "JSON schema and partial errors"
    (for ([raw (in-list '(#"[]" #"not json" #"{} {}" #"{\"data\":{},\"errors\":[{\"detail\":\"secret\"}]}"))])
      (parameterize ([current-transport (response-transport raw)])
        (check-exn (lambda (e) (and (exn:fail:bridge? e) (not (regexp-match? #rx"secret" (exn-message e)))))
                   (lambda () (json-request "https://api.x.com/2/tweets"))))))

  (test-case "post request construction and string IDs"
    (check-equal? (post-body "hello" '("123") "456")
                  (hasheq 'text "hello" 'media (hasheq 'media_ids '("123"))
                          'reply (hasheq 'in_reply_to_tweet_id "456")))
    (check-equal? (post-body "" '("123")) (hasheq 'media (hasheq 'media_ids '("123"))))
    (for ([args (in-list '(("" () null) ("hi" (123) null) ("hi" ("1" "1") null)
                          ("hi" () "bad") ("hi" ("1" "2" "3" "4" "5") null)))])
      (check-exn exn:fail:bridge? (lambda () (apply post-body args)))))

  (test-case "disabled writes precede credentials and HTTP"
    (parameterize ([current-token-provider (lambda () (error "must not read token"))]
                   [current-transport (lambda args (error "must not call HTTP"))])
      (check-exn #rx"writes are disabled" (lambda () (create-post "hi")))
      (check-exn #rx"writes are disabled" (lambda () (upload-media "invalid")))))

  (test-case "upload and post wrappers use official paths and never retry"
    (define calls '())
    (parameterize ([current-writes-enabled #t]
                   [current-token-provider (lambda () "synthetic-token")]
                   [current-transport
                    (lambda (url #:method method #:headers headers #:body body #:limit limit)
                      (set! calls (append calls (list (list url method headers (parse-json body)))))
                      (values (hash) #"{\"data\":{\"id\":\"123\",\"expires_after_secs\":86400}}"))])
      (check-equal? (hash-ref (upload-media (encode-base64 png)) 'media_id) "123")
      (check-equal? (hash-ref (create-post "hi" '("123") "456") 'id) "123"))
    (check-equal? (length calls) 2)
    (check-equal? (caar calls) "https://api.x.com/2/media/upload")
    (check-equal? (car (cadr calls)) "https://api.x.com/2/tweets")
    (check-equal? (hash-ref (caddar calls) "Authorization") "Bearer synthetic-token")
    (check-equal? (cadddr (car calls)) (hasheq 'media (encode-base64 png) 'media_category "tweet_image")))

  (test-case "invalid write IDs and pending uploads fail without retry"
    (for ([raw (in-list '(#"{\"data\":{\"id\":123}}" #"{\"data\":{\"id\":\"123\",\"processing_info\":{\"state\":\"pending\"}}}"))])
      (parameterize ([current-writes-enabled #t] [current-token-provider (lambda () "fake")]
                     [current-transport (response-transport raw)])
        (check-exn exn:fail:bridge? (lambda () (upload-media (encode-base64 png)))))))

  (test-case "token file compatibility, expiry, permissions, and environment override"
    (define path (make-temporary-file "mcp-token-~a.json" #f "/tmp"))
    (define environment (environment-variables-copy (current-environment-variables)))
    (environment-variables-set! environment #"X_ACCESS_TOKEN" #f)
    (environment-variables-set! environment #"MCP_X_TOKEN_FILE" (path->bytes path))
    (dynamic-wind
      void
      (lambda ()
        (parameterize ([current-environment-variables environment])
          (call-with-output-file path #:exists 'truncate (lambda (out) (write-json (hasheq 'access_token "synthetic-token" 'expires_at 9999999999) out)))
          (file-or-directory-permissions path #o600)
          (check-equal? (access-token) "synthetic-token")
          (file-or-directory-permissions path #o644)
          (check-exn #rx"0600" access-token)
          (file-or-directory-permissions path #o600)
          (call-with-output-file path #:exists 'truncate (lambda (out) (write-json (hasheq 'access_token "synthetic-token" 'expires_at 1) out)))
          (check-exn #rx"expired" access-token)
          (environment-variables-set! environment #"X_ACCESS_TOKEN" #"override")
          (check-equal? (access-token) "override")))
      (lambda () (delete-file path))))

  (test-case "MCP lifecycle and tools, notifications cannot publish"
    (parameterize ([current-writes-enabled #t]
                   [current-transport (lambda args (error "must not publish"))])
      (define replies (rpc (list initialize initialized
                                 (hasheq 'jsonrpc "2.0" 'method "tools/call" 'params (hasheq 'name "create_x_post" 'arguments (hasheq 'text "no")))
                                 (hasheq 'jsonrpc "2.0" 'id 2 'method "tools/list"))))
      (check-equal? (length replies) 2)
      (check-equal? (hash-ref (hash-ref (car replies) 'result) 'protocolVersion) "2025-11-25")
      (define tools (hash-ref (hash-ref (cadr replies) 'result) 'tools))
      (check-equal? (length tools) 3)
      (check-false (hash-ref (hash-ref (cadr tools) 'annotations) 'readOnlyHint))))

  (test-case "MCP rejects malformed input and uninitialized calls"
    (define output (open-output-string))
    (serve (open-input-string "bad json\n[]\n") output)
    (check-true (regexp-match? #rx"-32700" (get-output-string output)))
    (check-true (regexp-match? #rx"-32600" (get-output-string output)))
    (check-true (hash-has-key? (car (rpc (list (hasheq 'jsonrpc "2.0" 'id 1 'method "tools/list")))) 'error)))

  (test-case "safe tool validation, default read-only surface and unknown tools"
    (check-equal? (map (lambda (t) (hash-ref t 'name)) (tool-list)) '("fetch_x_media"))
    (check-exn exn:fail? (lambda () (call-tool "create_x_post" (hasheq 'text "no"))))
    (check-true (hash-ref (call-tool "fetch_x_media" (hasheq 'url "https://localhost/secret")) 'isError))
    (check-true (hash-ref (call-tool "fetch_x_media" (hasheq 'url 42)) 'isError))
    (parameterize ([current-transport (lambda args (error "synthetic-secret"))])
      (define result (call-tool "fetch_x_media" (hasheq 'url image-url)))
      (check-true (hash-ref result 'isError))
      (check-false (regexp-match? #rx"synthetic-secret" (jsexpr->string result))))))
