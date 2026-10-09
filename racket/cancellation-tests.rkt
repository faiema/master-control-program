#lang racket/base
;; SPDX-License-Identifier: AGPL-3.0-only
(require json rackunit racket/file racket/port racket/runtime-path
         "common.rkt" "auth.rkt" "http.rkt" "x-api.rkt" "server.rkt"
         "lib/mcp-stdio.rkt")

(define-runtime-path resource-path "../tests/fixtures/images.json")

(define (with-session handler test)
  (define owner (make-custodian))
  (define diagnostics (open-output-string))
  (dynamic-wind
    void
    (lambda ()
      (parameterize ([current-custodian owner] [current-error-port diagnostics])
        (define-values (server-in client-out) (make-pipe))
        (define-values (client-in server-out) (make-pipe))
        (define replies (make-channel))
        (define server
          (thread (lambda () (serve-tools (lambda () '()) handler #:name "test"
                                          #:input server-in #:output server-out))))
        (thread (lambda () (let loop ()
                            (define line (read-line client-in))
                            (unless (eof-object? line)
                              (channel-put replies (parse-json line)) (loop)))))
        (define (send method [id #f] [params (hasheq)])
          (write-json (if id (hasheq 'jsonrpc "2.0" 'id id 'method method 'params params)
                          (hasheq 'jsonrpc "2.0" 'method method 'params params)) client-out)
          (newline client-out) (flush-output client-out))
        (define (receive)
          (define reply (sync/timeout 5 replies))
          (unless reply (error 'test "Timed out waiting for MCP response"))
          reply)
        (define (finish)
          (close-output-port client-out)
          (check-not-false (sync/timeout 5 server)))
        (send "initialize" 1 (hasheq 'protocolVersion "2025-11-25" 'capabilities (hasheq) 'clientInfo (hasheq)))
        (receive)
        (send "notifications/initialized")
        (test send receive finish replies)
        (check-false (regexp-match? #rx"synthetic-secret" (get-output-string diagnostics)))))
    (lambda () (custodian-shutdown-all owner))))

(define (call send id) (send "tools/call" id (hasheq 'name "create_x_post" 'arguments (hasheq 'text "synthetic"))))
(define (cancel send id) (send "notifications/cancelled" #f (hasheq 'requestId id 'reason "synthetic-secret")))
(define (ping send receive id)
  (send "ping" id)
  (check-equal? (hash-ref (receive) 'id) id))

(module+ test
  (test-case "cancels running read, releases resources, responds to ping without a tool response"
    (define started (make-semaphore 0))
    (define resource #f)
    (define child #f)
    (with-session
     (lambda (name args)
       (set! resource (open-input-file resource-path))
       (define-values (process out in err)
         (subprocess #f #f #f (find-executable-path "racket") "-e" "(sync never-evt)"))
       (set! child process)
       (semaphore-post started)
       (sync never-evt))
     (lambda (send receive finish replies)
       (call send "read")
       (check-not-false (sync/timeout 5 started))
       (cancel send "read")
       (ping send receive 3)
       (check-true (port-closed? resource))
       (check-not-false (sync/timeout 5 child))
       (finish)
       (check-false (sync/timeout 0 replies)))))

  (test-case "cancel before write submission prevents all X requests"
    (define started (make-semaphore 0))
    (define writes 0)
    (parameterize ([current-writes-enabled #t]
                   [current-token-provider (lambda () (semaphore-post started) (sync never-evt))]
                   [current-transport (lambda args (set! writes (add1 writes)) (error "must not send"))])
      (with-session call-tool
        (lambda (send receive finish replies)
          (call send 2)
          (check-not-false (sync/timeout 5 started))
          (cancel send 2)
          (ping send receive 3)
          (finish)
          (check-equal? writes 0)
          (check-false (sync/timeout 0 replies))))))

  (test-case "cancel after submission preserves success or uncertain failure with exactly one write"
    (for ([fail? '(#f #t)])
      (define started (make-semaphore 0))
      (define release (make-semaphore 0))
      (define writes 0)
      (parameterize
          ([current-writes-enabled #t] [current-token-provider (lambda () "synthetic-token")]
           [current-transport
            (lambda (url #:method method #:headers headers #:body body #:limit limit)
              (set! writes (add1 writes))
              (semaphore-post started)
              (semaphore-wait release)
              (if fail? (bridge-error "X post creation: request timed out. A write may have succeeded; check X before resubmitting.")
                  (values (hash) #"{\"data\":{\"id\":\"123\"}}")))])
        (with-session call-tool
          (lambda (send receive finish replies)
            (call send 2)
            (check-not-false (sync/timeout 5 started))
            (cancel send 2)
            (ping send receive 3)
            (semaphore-post release)
            (define result (hash-ref (receive) 'result))
            (check-equal? (hash-ref result 'isError #f) fail?)
            (check-true (regexp-match? (if fail? #rx"may have succeeded" #rx"123") (jsexpr->string result)))
            (check-equal? writes 1)
            (finish))))))

  (test-case "malformed, unknown and repeated cancellation cannot cancel another request"
    (define started (make-semaphore 0))
    (with-session (lambda (name args) (semaphore-post started) (sync never-evt))
      (lambda (send receive finish replies)
        (call send 2)
        (check-not-false (sync/timeout 5 started))
        (cancel send "2")
        (cancel send 1)
        (send "notifications/cancelled" #f (hasheq 'requestId 2 'reason 42))
        (call send 2)
        (check-equal? (hash-ref (hash-ref (receive) 'error) 'code) -32600)
        (cancel send 2)
        (cancel send 2)
        (ping send receive 3)
        (finish)
        (check-false (sync/timeout 0 replies)))))

  (test-case "active request limit stays responsive and cancelled IDs release capacity"
    (with-session (lambda (name args) (sync never-evt))
      (lambda (send receive finish replies)
        (for ([id (in-range 10 18)]) (call send id))
        (call send 18)
        (check-equal? (hash-ref (hash-ref (receive) 'error) 'code) -32000)
        (for ([id (in-range 10 18)]) (cancel send id))
        (ping send receive 3)
        (call send 19)
        (cancel send 19)
        (ping send receive 4)
        (finish)
        (check-false (sync/timeout 0 replies)))))

  (test-case "cancellation during refresh saves rotated tokens then prevents the post"
    (define directory (make-temporary-file "mcp-cancel-refresh-~a" 'directory "/tmp"))
    (define path (build-path directory "token.json"))
    (define env (environment-variables-copy (current-environment-variables)))
    (environment-variables-set! env #"X_ACCESS_TOKEN" #f)
    (environment-variables-set! env #"MCP_X_TOKEN_FILE" (path->bytes path))
    (define started (make-semaphore 0))
    (define release (make-semaphore 0))
    (define requests 0)
    (dynamic-wind
      void
      (lambda ()
        (save-token (hasheq 'access_token "old" 'refresh_token "old-refresh" 'expires_at 1
                            'client_id "synthetic-client" 'scope scopes 'confidential #f) path)
        (parameterize
            ([current-environment-variables env] [current-writes-enabled #t]
             [current-transport
              (lambda (url #:method method #:headers headers #:body body #:limit limit)
                (set! requests (add1 requests))
                (check-equal? url "https://api.x.com/2/oauth2/token")
                (semaphore-post started)
                (semaphore-wait release)
                (values (hash) (jsexpr->bytes (hasheq 'access_token "new" 'refresh_token "new-refresh"
                                                     'expires_in 7200 'token_type "bearer" 'scope scopes))))])
          (with-session call-tool
            (lambda (send receive finish replies)
              (call send 2)
              (check-not-false (sync/timeout 5 started))
              (cancel send 2)
              (ping send receive 3)
              (semaphore-post release)
              (finish)
              (check-equal? requests 1)
              (check-equal? (hash-ref (parse-json (file->bytes path)) 'refresh_token) "new-refresh")
              ;; Cancellation must also release the shared storage semaphore.
              (define saved (parse-json (file->bytes path)))
              (define saved-again (thread (lambda () (save-token saved path))))
              (check-not-false (sync/timeout 5 saved-again))
              (check-false (sync/timeout 0 replies))))))
      (lambda () (delete-directory/files directory)))))
