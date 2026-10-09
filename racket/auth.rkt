#lang racket/base
;; SPDX-License-Identifier: AGPL-3.0-only

(require json net/base64 net/uri-codec racket/file racket/string
         "common.rkt" "http.rkt" "lib/pkce.rkt" "lib/secret-file.rkt")
(provide access-token current-token-provider authorization exchange save-token token-path scopes redirect-uri)

(define redirect-uri "http://127.0.0.1:8765/callback")
(define scopes "tweet.read users.read tweet.write media.write offline.access")
(define (token-path) (or (getenv "MCP_X_TOKEN_FILE") ".secrets/x-token.json"))

(define (valid-token? value)
  (and (string? value) (not (string=? value "")) (not (regexp-match? #rx"[\r\n]" value))))

(define login-required
  "Authentication: token missing, invalid, or expired. Run racket racket/login.rkt locally to grant offline access.")

(define (read-token path)
  (unless (zero? (bitwise-and (file-or-directory-permissions path 'bits) #o077))
    (bridge-error "Authentication: token file permissions must be 0600."))
  (define record (parse-json (file->bytes path)))
  (unless (and (hash? record) (valid-token? (hash-ref record 'access_token #f))
               (real? (hash-ref record 'expires_at #f))
               (< 0 (hash-ref record 'expires_at) +inf.0))
    (bridge-error login-required))
  record)

(define (fresh? record)
  (< (+ (current-seconds) 30) (hash-ref record 'expires_at)))

(define (with-token-lock path thunk)
  (call-with-private-json-lock
   path thunk
   (lambda () (bridge-error "Authentication: token file is busy; retry after the other login or refresh finishes."))))

(define (access-token)
  (define environment-token (getenv "X_ACCESS_TOKEN"))
  (cond
    [(and environment-token (not (string=? environment-token "")))
     (unless (valid-token? environment-token) (bridge-error "Authentication: invalid access token."))
     environment-token]
    [else
     (with-handlers ([exn:fail:bridge? raise]
                     [exn:fail? (lambda (_) (bridge-error login-required))])
       (define path (token-path))
       (define record (read-token path))
       (hash-ref
        (if (fresh? record) record
            (with-token-lock
             path
             (lambda ()
               ;; Another process may have refreshed while this one waited.
               (define latest (read-token path))
               (if (fresh? latest) latest
                   (let ([replacement (refresh latest)])
                     (store-token replacement path)
                     replacement)))))
        'access_token))]))

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
  (token-request form client-id client-secret))

(define (refresh record)
  (define refresh-token (hash-ref record 'refresh_token #f))
  (define client-id (hash-ref record 'client_id #f))
  (unless (and (valid-token? refresh-token) (valid-token? client-id))
    (bridge-error login-required))
  (define client-secret
    (and (hash-ref record 'confidential #f) (getenv "X_CLIENT_SECRET")))
  (when (and (hash-ref record 'confidential #f) (not (valid-token? client-secret)))
    (bridge-error "Authentication: set X_CLIENT_SECRET in the server environment for token refresh."))
  (token-request `((grant_type . "refresh_token") (refresh_token . ,refresh-token)
                   (client_id . ,client-id))
                 client-id client-secret record))

(define (token-request form client-id client-secret [previous #f])
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
    (with-handlers
        ([exn:fail:x-http?
          (lambda (e)
            (bridge-error (string-append (exn-message e)
                                        " Token authorization failed; no upload or post was sent. If credentials were revoked, run racket racket/login.rkt.")))]
         [exn:fail?
          (lambda (_)
            (bridge-error
             "Authentication: token request failed; check connectivity and retry later. If authorization no longer works, run racket racket/login.rkt. No upload or post was sent."))])
      ((current-transport) "https://api.x.com/2/oauth2/token" #:method "POST" #:headers authorized-headers
                           #:body (string->bytes/utf-8 (alist->form-urlencoded form)) #:limit (* 64 1024))))
  (with-handlers ([exn:fail? (lambda (_) (bridge-error "Authentication: token exchange returned invalid data or missing scopes; check app settings."))])
    (define response (parse-json raw))
    (define token (hash-ref response 'access_token))
    (define lifetime (hash-ref response 'expires_in))
    (define refresh-token (hash-ref response 'refresh_token (and previous (hash-ref previous 'refresh_token #f))))
    (define granted-scopes (hash-ref response 'scope (and previous (hash-ref previous 'scope #f))))
    (unless (and (valid-token? token) (valid-token? refresh-token) (real? lifetime) (< 30 lifetime +inf.0)
                 (equal? (string-downcase (hash-ref response 'token_type)) "bearer")
                 (let ([granted (string-split granted-scopes)])
                   (for/and ([scope (in-list (string-split scopes))]) (member scope granted))))
      (error 'exchange "Invalid token response"))
    (hasheq 'access_token token 'expires_at (+ (current-seconds) lifetime)
            'refresh_token refresh-token 'scope granted-scopes 'client_id client-id
            'confidential (and client-secret (not (equal? client-secret "")) #t))))

(define (save-token record [path (token-path)])
  (with-handlers ([exn:fail:bridge? raise]
                  [exn:fail? (lambda (_) (bridge-error "Authentication: token storage failed; check local directory permissions."))])
    (with-token-lock path (lambda () (store-token record path)))))

(define (store-token record path)
  (with-handlers ([exn:fail? (lambda (_) (bridge-error "Authentication: token storage failed; check local directory permissions."))])
    (write-private-json path record)))
