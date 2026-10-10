#lang racket/base
;; SPDX-License-Identifier: AGPL-3.0-only
(require rackunit json net/base64 racket/list racket/runtime-path racket/string
         "common.rkt" "github-http.rkt" "github-media.rkt" "media.rkt" "server.rkt")
(define-runtime-path images "../tests/fixtures/images.json")
(define fixtures (call-with-input-file images read-json))
(define png (base64-decode (string->bytes/utf-8 (hash-ref fixtures 'png))))
(define (metadata raw [path "face.png"])
  (hasheq 'type "file" 'path path 'sha (github-blob-sha raw) 'size (bytes-length raw)
          'content "" 'encoding "none" 'download_url "https://untrusted.invalid/secret"))
(define (fixture raw [info (metadata raw)])
  (lambda (target accept limit)
    (if (equal? accept "application/vnd.github.object+json")
        (jsexpr->bytes info)
        (begin
          (check-equal? target (string-append "/repos/owner/repo/git/blobs/" (hash-ref info 'sha)))
          (check-equal? limit max-image-bytes)
          raw))))

(module+ test
  (test-case "original formats become MCP image blocks with verified provenance"
    (for ([kind '(png jpeg webp)])
      (define raw (base64-decode (string->bytes/utf-8 (hash-ref fixtures kind))))
      (parameterize ([current-github-request (fixture raw)])
        (define result (fetch-github-image "owner/repo" "face.png" "main"))
        (define content (hash-ref result 'content))
        (define info (string->jsexpr (hash-ref (first content) 'text)))
        (check-equal? (hash-ref info 'blob_sha) (github-blob-sha raw))
        (check-equal? (hash-ref info 'ref) "main")
        (check-equal? (hash-ref (second content) 'type) "image")
        (check-equal? (base64-decode (string->bytes/utf-8 (hash-ref (second content) 'data))) raw))))
  (test-case "URL components are encoded and blob download ignores supplied URLs"
    (define seen '())
    (parameterize ([current-github-request
                    (lambda (target accept limit)
                      (set! seen (cons target seen))
                      ((fixture png (metadata png "faces/a #?.png")) target accept limit))])
      (fetch-github-image "owner/repo" "faces/a #?.png" "feature/test&other=x"))
    (check-equal? (last seen) "/repos/owner/repo/contents/faces/a%20%23%3F.png?ref=feature%2Ftest%26other%3Dx"))
  (test-case "invalid inputs fail before any network request"
    (parameterize ([current-github-request (lambda args (error 'test "Unexpected network"))])
      (for ([repo '("https://github.com/o/r" "o/.." "o/r/x" "o/r?x")])
        (check-exn exn:fail:bridge? (lambda () (fetch-github-image repo "face.png"))))
      (for ([path '("/face.png" "../face.png" "a/./b" "a//b" "a\\b" "a\n")])
        (check-exn exn:fail:bridge? (lambda () (fetch-github-image "o/r" path))))
      (check-exn exn:fail:bridge? (lambda () (fetch-github-image "o/r" "face.png" "")))))
  (test-case "bad metadata rejected before blob download"
    (for ([info (list (hash-set (metadata png) 'type "dir")
                     (hash-set (metadata png) 'path "other.png")
                     (hash-set (metadata png) 'size 0)
                     (hash-set (metadata png) 'size (add1 max-image-bytes))
                     (hash-set (metadata png) 'sha "bad")
                     (hash-set (metadata png) 'submodule_git_url "https://other.invalid"))])
      (parameterize ([current-github-request
                      (lambda (target accept limit)
                        (check-equal? accept "application/vnd.github.object+json")
                        (jsexpr->bytes info))])
        (check-exn exn:fail:bridge? (lambda () (fetch-github-image "o/r" "face.png"))))))
  (test-case "truncation and content replacement fail integrity checks"
    (for ([raw (list (subbytes png 0 (sub1 (bytes-length png)))
                     (bytes-append #"X" (subbytes png 1)))])
      (parameterize ([current-github-request (fixture raw (metadata png))])
        (check-exn #rx"blob SHA mismatch" (lambda () (fetch-github-image "owner/repo" "face.png"))))))
  (test-case "unsupported bytes and LFS pointers are actionable"
    (for ([raw (list #"not an image" #"version https://git-lfs.github.com/spec/v1\noid sha256:abc\n")])
      (parameterize ([current-github-request (fixture raw)])
        (check-exn exn:fail:bridge? (lambda () (fetch-github-image "owner/repo" "face.png"))))))
  (test-case "public requests omit authorization; private requests isolate credentials"
    (for ([token (list #f "synthetic_github_token")])
      (parameterize ([current-github-token (lambda () token)]
                     [current-github-sendrecv
                      (lambda (host target #:ssl? ssl #:content-decode decode #:headers headers)
                        (check-equal? host "api.github.com")
                        (check-equal? (filter (lambda (h) (string-prefix? h "Authorization:")) headers)
                                      (if token '("Authorization: Bearer synthetic_github_token") '()))
                        (values #"HTTP/1.1 200 OK" '(#"Content-Length: 3") (open-input-bytes #"abc")))])
        (check-equal? (github-request "/repos/o/r/contents/f.png" "application/vnd.github.object+json" 100) #"abc"))))
  (test-case "HTTP errors suppress upstream secret-bearing response bodies"
    (for ([code '(301 401 403 404 429 500)])
      (check-exn
       (lambda (e) (and (exn:fail:bridge? e)
                        (regexp-match? (regexp (number->string code)) (exn-message e))
                        (not (regexp-match? #rx"SECRET" (exn-message e)))))
       (lambda () (read-github-response (string->bytes/utf-8 (format "HTTP/1.1 ~a Status" code))
                                        '(#"Location: https://SECRET.invalid") (open-input-bytes #"SECRET") 100)))))
  (test-case "empty, oversized and truncated HTTP bodies rejected"
    (for ([raw '(#"" #"12345" #"12")])
      (check-exn exn:fail:bridge?
                 (lambda () (read-github-response #"HTTP/1.1 200 OK" '(#"Content-Length: 3")
                                                  (open-input-bytes raw) 3)))))
  (test-case "invalid JSON and malformed images never produce an image result"
    (parameterize ([current-github-request (lambda args #"{broken")])
      (check-exn #rx"invalid file metadata" (lambda () (fetch-github-image "o/r" "face.png"))))
    ;; A matching blob hash is not enough: still require a complete image decode.
    (define broken (subbytes png 0 (- (bytes-length png) 12)))
    (parameterize ([current-github-request (fixture broken)])
      (check-exn exn:fail:bridge? (lambda () (fetch-github-image "owner/repo" "face.png")))))
  (test-case "transport exceptions hide credentials and redirects are never followed"
    (parameterize ([current-github-token (lambda () "synthetic_token")]
                   [current-github-sendrecv
                    (lambda (host target #:ssl? ssl #:content-decode decode #:headers headers)
                      (error "SECRET transport diagnostic"))])
      (check-exn (lambda (e) (and (exn:fail:bridge? e)
                                 (not (regexp-match? #rx"SECRET|synthetic_token" (exn-message e)))))
                 (lambda () (github-request "/repos/o/r/contents/f.png" "application/vnd.github.object+json" 100))))
    (define calls 0)
    (parameterize ([current-github-token (lambda () #f)]
                   [current-github-sendrecv
                    (lambda (host target #:ssl? ssl #:content-decode decode #:headers headers)
                      (set! calls (add1 calls))
                      (values #"HTTP/1.1 302 Found" '(#"Location: https://other.invalid/secret")
                              (open-input-bytes #"")))])
      (check-exn #rx"Redirect refused"
                 (lambda () (github-request "/repos/o/r/contents/f.png" "application/vnd.github.object+json" 100))))
    (check-equal? calls 1))
  (test-case "MCP exposes read-only tool and validates required argument types"
    (define tool (findf (lambda (t) (equal? (hash-ref t 'name) "fetch_github_image")) (tool-list)))
    (check-true (hash-ref (hash-ref tool 'annotations) 'readOnlyHint))
    (check-false (hash-ref (hash-ref tool 'annotations) 'destructiveHint))
    (for ([args (list (hasheq) (hasheq 'repository_full_name 42 'path "a.png"))])
      (check-true (hash-ref (call-tool "fetch_github_image" args) 'isError)))))
