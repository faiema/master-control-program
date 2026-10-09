#lang racket/base
;; SPDX-License-Identifier: AGPL-3.0-only

(require json net/base64 net/uri-codec net/url rackunit racket/file racket/list racket/port racket/string racket/tcp
         "auth.rkt" "common.rkt" "http.rkt" "lib/pkce.rkt" "lib/oauth-loopback.rkt" "x-api.rkt")

(define (browser-request port target [partial? #f])
  (define-values (input output) (tcp-connect "127.0.0.1" port))
  (dynamic-wind
    void
    (lambda ()
      (fprintf output "GET ~a HTTP/1.1\r\nHost: 127.0.0.1:~a\r\n~a" target port (if partial? "" "\r\n"))
      (flush-output output)
      (port->string input))
    (lambda () (close-input-port input) (close-output-port output))))

(module+ test
  (test-case "PKCE S256 matches RFC 7636 vector"
    (check-equal? (base64url (sha256-bytes #"dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"))
                  "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    (define-values (verifier challenge) (make-pkce))
    (check-true (regexp-match? #px"^[A-Za-z0-9_-]{64}$" verifier))
    (check-equal? challenge (base64url (sha256-bytes (string->bytes/utf-8 verifier))))
    (check-not-equal? (random-state) (random-state)))

  (test-case "authorization scope and callback contract"
    (define-values (url state verifier) (authorization "synthetic-client"))
    (define query (url-query (string->url url)))
    (check-equal? (cdr (assq 'redirect_uri query)) redirect-uri)
    (check-equal? (cdr (assq 'code_challenge_method query)) "S256")
    (check-equal? (cdr (assq 'state query)) state)
    (check-equal? (cdr (assq 'scope query)) scopes)
    (check-true (regexp-match? #rx"offline.access" url))
    (check-false (regexp-match? (regexp verifier) url)))

  (test-case "public and confidential exchanges match official form API"
    (for ([secret '(#f "" "synthetic-secret")])
      (define calls 0)
      (parameterize ([current-transport
                      (lambda (url #:method method #:headers headers #:body body #:limit limit)
                        (set! calls (add1 calls))
                        (check-equal? url "https://api.x.com/2/oauth2/token")
                        (check-equal? method "POST")
                        (define form (form-urlencoded->alist (bytes->string/utf-8 body)))
                        (check-equal? (cdr (assq 'code_verifier form)) "verifier")
                        (check-equal? (cdr (assq 'code form)) "code")
                        (check-equal? (cdr (assq 'client_id form)) "client")
                        (if (and secret (not (equal? secret "")))
                            (check-equal? (hash-ref headers "Authorization") "Basic Y2xpZW50OnN5bnRoZXRpYy1zZWNyZXQ=")
                            (check-false (hash-has-key? headers "Authorization")))
                        (values (hash) (jsexpr->bytes (hasheq 'access_token "synthetic-token" 'expires_in 7200
                                                              'token_type "bearer" 'refresh_token "synthetic-refresh" 'scope scopes))))])
        (define record (exchange "code" "verifier" "client" secret))
        (check-equal? (hash-ref record 'access_token) "synthetic-token")
        (check-true (> (hash-ref record 'expires_at) (current-seconds)))
        (check-equal? calls 1))))

  (test-case "token exchange rejects malformed data and missing scopes safely"
    (define valid (hasheq 'access_token "synthetic-secret" 'expires_in 7200 'token_type "bearer" 'refresh_token "synthetic-refresh" 'scope scopes))
    (for ([raw (in-list (append (list #"not json" #"[]")
                               (map jsexpr->bytes
                                    (list (hash-remove valid 'refresh_token) (hash-set valid 'refresh_token "")
                                          (hash-set valid 'scope "tweet.read")
                                          (hash-set valid 'token_type "other") (hash-set valid 'expires_in 0)
                                          (hash-set valid 'expires_in #t) (hash-set valid 'access_token "bad\r\nheader")))))])
      (parameterize ([current-transport (lambda (url #:method method #:headers headers #:body body #:limit limit)
                                          (values (hash) raw))])
        (check-exn (lambda (e) (and (exn:fail:bridge? e) (not (regexp-match? #rx"synthetic-secret" (exn-message e)))))
                   (lambda () (exchange "code" "verifier" "client"))))))

  (test-case "OAuth preserves safe rejection reasons and retry timing"
    (for ([status '(400 429)])
      (define calls 0)
      (parameterize
          ([current-transport
            (lambda (url #:method method #:headers headers #:body body #:limit limit)
              (set! calls (add1 calls))
              (read-response (string->bytes/utf-8 (format "HTTP/1.1 ~a Error" status))
                             '(#"Retry-After: 45")
                             (open-input-bytes #"{\"error\":\"invalid_grant\",\"error_description\":\"synthetic-secret\"}")
                             limit #:operation "X authentication"))])
        (define failure (with-handlers ([exn:fail:bridge? values]) (exchange "code" "verifier" "client")))
        (check-true (exn:fail:bridge? failure))
        (define message (exn-message failure))
        (check-true (regexp-match? #rx"invalid_grant" message))
        (check-true (regexp-match? #rx"no upload or post was sent" message))
        (check-false (regexp-match? #rx"synthetic-secret" message))
        (when (= status 429) (check-true (regexp-match? #rx"45 seconds" message)))
        (check-equal? calls 1))))

  (test-case "atomic token storage creates private directory and replaces permissions"
    (define directory (make-temporary-file "mcp-oauth-~a" 'directory "/tmp"))
    (define path (build-path directory "nested" "secrets" "token.json"))
    (dynamic-wind
      void
      (lambda ()
        (define record (hasheq 'access_token "synthetic-token" 'expires_at 9999999999))
        (save-token record path)
        (check-equal? (bitwise-and (file-or-directory-permissions path 'bits) #o777) #o600)
        (check-equal? (bitwise-and (file-or-directory-permissions (build-path directory "nested" "secrets") 'bits) #o777) #o700)
        (check-equal? (parse-json (file->bytes path)) record)
        (file-or-directory-permissions path #o644)
        (save-token record path)
        (check-equal? (bitwise-and (file-or-directory-permissions path 'bits) #o777) #o600)
        (check-equal? (length (directory-list (build-path directory "nested" "secrets"))) 2))
      (lambda () (delete-directory/files directory))))

  (test-case "refresh rotates tokens once before concurrent writes and survives restart"
    (define directory (make-temporary-file "mcp-refresh-~a" 'directory "/tmp"))
    (define path (build-path directory "token.json"))
    (define environment (environment-variables-copy (current-environment-variables)))
    (environment-variables-set! environment #"X_ACCESS_TOKEN" #f)
    (environment-variables-set! environment #"X_CLIENT_SECRET" #f)
    (environment-variables-set! environment #"MCP_X_TOKEN_FILE" (path->bytes path))
    (define expired (hasheq 'access_token "old-access" 'refresh_token "old-refresh"
                           'expires_at 1 'client_id "client" 'scope scopes 'confidential #f))
    (define calls 0)
    (define posts 0)
    (dynamic-wind
      void
      (lambda ()
        (save-token expired path)
        (parameterize
            ([current-environment-variables environment]
             [current-writes-enabled #t]
             [current-transport
              (lambda (url #:method method #:headers headers #:body body #:limit limit)
                (cond
                  [(equal? url "https://api.x.com/2/oauth2/token")
                   (set! calls (add1 calls))
                   (define form (form-urlencoded->alist (bytes->string/utf-8 body)))
                   (check-equal? (cdr (assq 'grant_type form)) "refresh_token")
                   (check-equal? (cdr (assq 'refresh_token form)) "old-refresh")
                   (check-equal? (cdr (assq 'client_id form)) "client")
                   (check-false (assq 'code_verifier form))
                   (check-false (hash-has-key? headers "Authorization"))
                   (sleep 0.05)
                   (values (hash) (jsexpr->bytes (hasheq 'access_token "new-access" 'refresh_token "new-refresh"
                                                        'expires_in 7200 'token_type "bearer" 'scope scopes)))]
                  [else
                   (set! posts (add1 posts))
                   (check-equal? (hash-ref headers "Authorization") "Bearer new-access")
                   (values (hash) #"{\"data\":{\"id\":\"123\"}}")]))])
          (define results (make-channel))
          (for ([i (in-range 4)])
            (thread (lambda () (channel-put results (with-handlers ([exn:fail? values]) (access-token))))))
          (for ([i (in-range 4)]) (check-equal? (sync/timeout 5 results) "new-access"))
          (check-equal? calls 1)
          (check-equal? (hash-ref (parse-json (file->bytes path)) 'refresh_token) "new-refresh")
          (check-equal? (bitwise-and (file-or-directory-permissions path 'bits) #o777) #o600)
          (create-post "synthetic post")
          (check-equal? posts 1)
          (check-equal? calls 1)))
      (lambda () (delete-directory/files directory))))

  (test-case "refresh failure blocks posting and preserves saved credentials"
    (define directory (make-temporary-file "mcp-refresh-failure-~a" 'directory "/tmp"))
    (define path (build-path directory "token.json"))
    (define environment (environment-variables-copy (current-environment-variables)))
    (environment-variables-set! environment #"X_ACCESS_TOKEN" #f)
    (environment-variables-set! environment #"X_CLIENT_SECRET" #"synthetic-secret")
    (environment-variables-set! environment #"MCP_X_TOKEN_FILE" (path->bytes path))
    (define expired (hasheq 'access_token "old-access" 'refresh_token "old-refresh"
                           'expires_at (+ (current-seconds) 10) 'client_id "client" 'scope scopes 'confidential #t))
    (dynamic-wind
      void
      (lambda ()
        (save-token expired path)
        (for ([failure '(revoked network malformed scopes)])
          (define calls 0)
          (parameterize
              ([current-environment-variables environment] [current-writes-enabled #t]
               [current-transport
                (lambda (url #:method method #:headers headers #:body body #:limit limit)
                  (set! calls (add1 calls))
                  (check-equal? url "https://api.x.com/2/oauth2/token")
                  (check-equal? (hash-ref headers "Authorization") "Basic Y2xpZW50OnN5bnRoZXRpYy1zZWNyZXQ=")
                  (case failure
                    [(revoked) (read-response #"HTTP/1.1 400 Bad Request" '()
                                             (open-input-bytes #"{\"error\":\"invalid_grant\",\"error_description\":\"synthetic-secret\"}")
                                             1000 #:operation "X authentication")]
                    [(network) (error "synthetic-secret old-refresh")]
                    [(malformed) (values (hash) #"not json")]
                    [else (values (hash) (jsexpr->bytes (hasheq 'access_token "new-access" 'expires_in 7200
                                                               'token_type "bearer" 'scope "tweet.read")))]))])
            (check-exn (lambda (e) (and (exn:fail:bridge? e)
                                        (not (regexp-match? #rx"synthetic-secret|old-refresh" (exn-message e)))))
                       (lambda () (create-post "must not be sent")))
            (check-equal? calls 1)
            (check-equal? (parse-json (file->bytes path)) expired)))
        ;; Optional refresh response fields retain the previous grant.
        (parameterize
            ([current-environment-variables environment]
             [current-transport (lambda (url #:method method #:headers headers #:body body #:limit limit)
                                  (values (hash) #"{\"access_token\":\"new-access\",\"expires_in\":7200,\"token_type\":\"bearer\"}"))])
          (check-equal? (access-token) "new-access")
          (check-equal? (hash-ref (parse-json (file->bytes path)) 'refresh_token) "old-refresh")))
      (lambda () (delete-directory/files directory))))

  (test-case "callback state, duplicate parameters, denial and malformed requests"
    (check-equal? (parse-callback "/callback?state=expected&code=synthetic%2Bcode" "expected") "synthetic+code")
    (check-equal? (parse-callback "/callback?state=expected&error=access_denied" "expected") 'denied)
    (for ([target '("/other?state=expected&code=x" "/callback?state=wrong&code=x"
                    "/callback?state=expected&state=expected&code=x" "/callback?state=expected&code=x&code=y"
                    "/callback?state=expected&code=" "/callback?state=expected&code=x&error=no"
                    "/callback?state=expected&code=x#fragment" "http://evil/callback?state=expected&code=x")])
      (check-false (parse-callback target "expected"))))

  (test-case "real loopback receives code after rejecting a bad state"
    (define responses (make-channel))
    (define browser-owner (current-custodian))
    (define code
      (receive-authorization-code
       "expected" #:port 0 #:timeout 5
       #:on-listening
       (lambda (port)
         (parameterize ([current-custodian browser-owner])
           (thread
            (lambda ()
              (define bad (browser-request port "/callback?state=wrong&code=no"))
              (define good (browser-request port "/callback?state=expected&code=synthetic-code"))
              (channel-put responses (list bad good))))))))
    (check-equal? code "synthetic-code")
    (define received (sync/timeout 5 responses))
    (check-not-false received)
    (check-true (regexp-match? #rx"400 Bad Request" (car received)))
    (check-true (regexp-match? #rx"200 OK" (cadr received)))
    (check-false (regexp-match? #rx"synthetic-code" (cadr received))))

  (test-case "real loopback reports denial without exchanging a token"
    (check-exn
     #rx"denied"
     (lambda ()
       (receive-authorization-code
        "expected" #:port 0 #:timeout 5
        #:on-listening (lambda (port) (thread (lambda () (browser-request port "/callback?state=expected&error=access_denied"))))))))

  (test-case "overall deadline closes a stalled callback connection"
    (check-exn
     #rx"timed out"
     (lambda ()
       (receive-authorization-code
        "expected" #:port 0 #:timeout 0.1
        #:on-listening (lambda (port) (thread (lambda () (browser-request port "/callback?state=expected&code=x" #t))))))))
)
