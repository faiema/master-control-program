#lang racket/base

(require json net/base64 net/uri-codec racket/file racket/string
         "common.rkt" "http.rkt" "lib/pkce.rkt" "lib/secret-file.rkt")
(provide access-token current-token-provider authorization exchange save-token token-path scopes redirect-uri)

(define redirect-uri "http://127.0.0.1:8765/callback")
(define scopes "tweet.read users.read tweet.write media.write")
(define (token-path) (or (getenv "MCP_X_TOKEN_FILE") ".secrets/x-token.json"))

(define (valid-token? value)
  (and (string? value) (not (string=? value "")) (not (regexp-match? #rx"[\r\n]" value))))

(define (access-token)
  (define environment-token (getenv "X_ACCESS_TOKEN"))
  (cond
    [(and environment-token (not (string=? environment-token "")))
     (unless (valid-token? environment-token) (bridge-error "Authentication: invalid access token."))
     environment-token]
    [else
     (with-handlers ([exn:fail:bridge? raise]
                     [exn:fail? (lambda (_) (bridge-error "Authentication: token missing, invalid, or expired. Run racket racket/login.rkt locally."))])
       (define path (token-path))
       (unless (zero? (bitwise-and (file-or-directory-permissions path 'bits) #o077))
         (bridge-error "Authentication: token file permissions must be 0600."))
       (define record (parse-json (file->bytes path)))
       (define token (hash-ref record 'access_token #f))
       (define expires (hash-ref record 'expires_at #f))
       (unless (and (valid-token? token) (real? expires) (< (+ (current-seconds) 30) expires +inf.0))
         (bridge-error "Authentication: token missing, invalid, or expired. Run racket racket/login.rkt locally."))
       token)]))

(define current-token-provider (make-parameter access-token))

(define (authorization client-id)
  (define-values (verifier challenge) (make-pkce))
  (define state (random-state))
  (values
   (string-append "https://x.com/i/oauth2/authorize?"
                  (alist->form-urlencoded
                   `((response_type . "code") (client_id . ,client-id) (redirect_uri . ,redirect-uri)
                     (scope . ,scopes) (state . ,state) (code_challenge . ,challenge)
                     (code_challenge_method . "S256"))))
   state verifier))

(define (exchange code verifier client-id [client-secret #f])
  (define form `((grant_type . "authorization_code") (code . ,code) (redirect_uri . ,redirect-uri)
                (code_verifier . ,verifier) (client_id . ,client-id)))
  (define headers (hash "Content-Type" "application/x-www-form-urlencoded"))
  (define authorized-headers
    (if (and client-secret (not (equal? client-secret "")))
        (hash-set headers "Authorization"
                  (string-append "Basic "
                                 (bytes->string/utf-8
                                  (base64-encode
                                   (string->bytes/utf-8
                                    (string-append (form-urlencoded-encode client-id) ":" (form-urlencoded-encode client-secret))) #""))))
        headers))
  (define-values (_ raw)
    ((current-transport) "https://api.x.com/2/oauth2/token" #:method "POST" #:headers authorized-headers
                         #:body (string->bytes/utf-8 (alist->form-urlencoded form)) #:limit (* 64 1024)))
  (with-handlers ([exn:fail? (lambda (_) (bridge-error "Authentication: token exchange returned invalid data or missing scopes; check app settings."))])
    (define response (parse-json raw))
    (define token (hash-ref response 'access_token))
    (define lifetime (hash-ref response 'expires_in))
    (unless (and (valid-token? token) (real? lifetime) (< 0 lifetime +inf.0)
                 (equal? (string-downcase (hash-ref response 'token_type)) "bearer")
                 (let ([granted (string-split (hash-ref response 'scope))])
                   (for/and ([scope (in-list (string-split scopes))]) (member scope granted))))
      (error 'exchange "Invalid token response"))
    (hasheq 'access_token token 'expires_at (+ (current-seconds) lifetime))))

(define (save-token record [path (token-path)])
  (with-handlers ([exn:fail? (lambda (_) (bridge-error "Authentication: token storage failed; check local directory permissions."))])
    (write-private-json path record)))
