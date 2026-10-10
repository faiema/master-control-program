#lang racket/base
;; SPDX-License-Identifier: AGPL-3.0-only

;; Test-only entrypoint: production server.rkt has no fixture/network override.
(require "../racket/github-http.rkt" "../racket/github-media.rkt" json net/base64 "../racket/common.rkt" "../racket/http.rkt"
         "../racket/auth.rkt" "../racket/server.rkt" "../racket/x-api.rkt" "../racket/chatgpt-file.rkt")
(define png (base64-decode #"iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAIAAAASFvFNAAAAEElEQVR4nGP8zwAFTDAGAwATKQED8NgHhAAAAABJRU5ErkJggg=="))
(define (fixture-transport url #:method [method "GET"] #:headers [headers (hash)] #:body [body #f] #:limit limit)
  (cond
    [(equal? url "https://pbs.twimg.com/media/synthetic.png") (values (hash "content-type" "image/png") png)]
    [(equal? url "https://api.x.com/2/media/upload")
     (unless (equal? (parse-json body) (hasheq 'media (bytes->string/utf-8 (base64-encode png #"")) 'media_category "tweet_image"))
       (error 'fixture "Unexpected upload body"))
     (values (hash) #"{\"data\":{\"id\":\"123\",\"expires_after_secs\":86400}}")]
    [(equal? url "https://api.x.com/2/tweets")
     (unless (equal? (parse-json body) (hasheq 'text "hello" 'media (hasheq 'media_ids '("123"))
                                             'reply (hasheq 'in_reply_to_tweet_id "456")))
       (error 'fixture "Unexpected post body"))
     (values (hash) #"{\"data\":{\"id\":\"789\"}}")]
    [else (error 'fixture "Unexpected URL; test never uses live HTTP")]))
(parameterize ([current-github-request
                (lambda (target accept limit)
                  (cond
                    [(equal? target "/repos/owner/repo/contents/face.png?ref=main")
                     (jsexpr->bytes (hasheq 'type "file" 'path "face.png"
                                           'size (bytes-length png) 'sha (github-blob-sha png)))]
                    [(equal? target (string-append "/repos/owner/repo/git/blobs/" (github-blob-sha png))) png]
                    [else (error 'fixture "Unexpected GitHub target")]))]
               [current-transport fixture-transport]
               [current-file-hosts (file-hosts-from-environment)]
               [current-file-download (lambda (host target)
                                        (unless (and (equal? host "files.example.test")
                                                     (equal? target "/image?signature=synthetic-secret"))
                                          (error 'fixture "Unexpected file URL"))
                                        (values png "image/png"))]
               [current-token-provider (lambda () "synthetic-token")]
               [current-writes-enabled (equal? (getenv "MCP_X_ENABLE_WRITES") "1")])
  (serve))
