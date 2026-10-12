#lang racket/base
;; SPDX-License-Identifier: AGPL-3.0-only
(require rackunit json net/base64 racket/file racket/string
         "github-text.rkt" "github-http.rkt" "github-media.rkt" "github-upload.rkt"
         "server.rkt" "common.rkt" "lib/cancellation.rkt")
(define prose "# Faië and Maië\r\n\r\n“I love you, but I need time,” she said.\n\n**Trust** takes work.\n")
(define commit (make-string 40 #\c))
(define old-sha (github-blob-sha #"old"))
(define (http-error code)
  (raise (exn:fail:github "Synthetic GitHub failure; check access or destination." (current-continuation-marks) code)))
(define (run content #:sha [sha 'null] #:key [key 'null])
  (call-tool "upload_github_text"
             (hasheq 'repository_full_name "owner/repo" 'path "canon/character.md" 'branch "test"
                     'content content 'message "Update canon" 'expected_sha sha 'idempotency_key key)))
(define (value result) (hash-ref result 'structuredContent))
(define (category result) (hash-ref (value result) 'category))
(define (fixture thunk #:initial [initial #f] #:put-error [put-error #f] #:verify-error [verify-error #f])
  (define raw initial)
  (define puts 0)
  (define (request target accept limit #:payload [payload #f])
    (cond [payload
           (set! puts (add1 puts))
           (check-equal? (hash-ref payload 'branch) "test")
           (check-equal? (hash-ref payload 'sha 'null) (if raw (github-blob-sha raw) 'null))
           (set! raw (base64-decode (string->bytes/utf-8 (hash-ref payload 'content))))
           (when put-error (put-error))
           (jsexpr->bytes (hasheq 'content (hasheq 'path "canon/character.md" 'sha (github-blob-sha raw))
                                  'commit (hasheq 'sha commit)))]
          [(string-contains? target "/git/blobs/") raw]
          [else
           (when (and verify-error (string-contains? target commit)) (verify-error))
           (unless raw (http-error 404))
           (jsexpr->bytes (hasheq 'type "file" 'path "canon/character.md"
                                  'sha (github-blob-sha raw) 'size (bytes-length raw)))]))
  (parameterize ([current-github-writes-enabled #t]
                 [current-github-token (lambda () "synthetic_token")]
                 [current-github-text-log void]
                 [current-github-request request])
    (thunk (lambda () puts) (lambda () raw))))
(module+ test
  (test-case "create and replace verify exact Unicode, CRLF, Markdown and dialogue"
    (for ([initial (list #f #"old")])
      (fixture
       (lambda (puts raw)
         (define result (run prose #:sha (if initial old-sha 'null)))
         (check-false (hash-ref result 'isError #f))
         (check-true (hash-ref (value result) 'verified))
         (check-equal? (hash-ref (value result) 'commit_url) (string-append "https://github.com/owner/repo/commit/" commit))
         (check-equal? (raw) (string->bytes/utf-8 prose))
         (check-equal? (puts) 1)
         (define read (call-tool "fetch_github_text" (hasheq 'repository_full_name "owner/repo" 'path "canon/character.md" 'ref "test")))
         (check-equal? (hash-ref (value read) 'content) prose)) #:initial initial)))
  (test-case "empty text preserves the empty Git blob"
    (fixture (lambda (puts raw) (check-true (hash-ref (value (run "")) 'verified)) (check-equal? (raw) #""))))
  (test-case "stale replacements and creates at existing paths never submit"
    (for ([expected (list 'null (make-string 40 #\a))])
      (fixture (lambda (puts raw)
                 (define result (run prose #:sha expected))
                 (check-equal? (category result) "SHA_CONFLICT")
                 (check-equal? (hash-ref (value result) 'current_sha) old-sha)
                 (check-equal? (puts) 0)) #:initial #"old")))
  (test-case "missing replacement refuses to create"
    (fixture (lambda (puts raw) (check-equal? (category (run prose #:sha old-sha)) "PATH_NOT_FOUND") (check-equal? (puts) 0))))
  (test-case "invalid UTF-8 read and oversized write"
    (fixture (lambda (puts raw)
               (check-equal? (category (call-tool "fetch_github_text" (hasheq 'repository_full_name "owner/repo" 'path "canon/character.md"))) "INVALID_CONTENT")
               (check-equal? (category (run (make-string 1048577 #\x))) "INVALID_CONTENT")
               (check-equal? (puts) 0)) #:initial #"\377"))
  (test-case "durable receipt replays without another request, changed key arguments fail"
    (define directory (make-temporary-file "github-text~a" 'directory))
    (dynamic-wind void
                  (lambda ()
                    (parameterize ([current-github-text-state-directory directory])
                      (fixture
                       (lambda (puts raw)
                         (define first (run prose #:key "key"))
                         (check-false (hash-ref first 'isError #f))
                         (parameterize ([current-github-request (lambda args (error "No request on replay"))])
                           (check-equal? (value (run prose #:key "key")) (value first)))
                         (check-equal? (category (run "changed" #:key "key")) "INVALID_CONTENT")
                         (check-equal? (puts) 1)))))
                  (lambda () (delete-directory/files directory))))
  (test-case "lost submission response cannot duplicate commit, including no-op replacement"
    (define directory (make-temporary-file "github-text~a" 'directory))
    (dynamic-wind void
                  (lambda ()
                    (parameterize ([current-github-text-state-directory directory])
                      (fixture
                       (lambda (puts raw)
                         (define first (run "old" #:sha old-sha #:key "interrupted"))
                         (check-equal? (category first) "UNKNOWN_UPSTREAM_ERROR")
                         (check-equal? (hash-ref (value first) 'write_state) "uncertain")
                         (check-equal? (category (run "old" #:sha old-sha #:key "interrupted")) "UNKNOWN_UPSTREAM_ERROR")
                         (check-equal? (puts) 1))
                       #:initial #"old" #:put-error (lambda () (error "connection lost with SECRET")))) )
                  (lambda () (delete-directory/files directory))))
  (test-case "verification failure recovers from saved commit without resubmission"
    (define directory (make-temporary-file "github-text~a" 'directory))
    (define broken? #t)
    (dynamic-wind void
                  (lambda ()
                    (parameterize ([current-github-text-state-directory directory])
                      (fixture
                       (lambda (puts raw)
                         (define first (run prose #:key "verify"))
                         (check-equal? (hash-ref (value first) 'write_state) "committed")
                         (set! broken? #f)
                         (check-true (hash-ref (value (run prose #:key "verify")) 'verified))
                         (check-equal? (puts) 1))
                       #:verify-error (lambda () (when broken? (http-error 503))))))
                  (lambda () (delete-directory/files directory))))
  (test-case "authorization, validation and errors do not infer policy or expose contents"
    (fixture
     (lambda (puts raw)
       (parameterize ([current-github-token (lambda () #f)])
         (check-equal? (category (run prose)) "AUTH_REQUIRED"))
       (parameterize ([current-github-writes-enabled #f])
         (check-exn exn:fail:bridge? (lambda () (upload-github-text "o/r" "a.md" "main" prose "Update"))))
       (for ([code '(401 403 404 429 500)] [expected '("AUTH_REQUIRED" "PERMISSION_DENIED" "PATH_NOT_FOUND" "GITHUB_API_ERROR" "GITHUB_API_ERROR")])
         (parameterize ([current-github-request (lambda args (http-error code))])
           (define result (call-tool "fetch_github_text" (hasheq 'repository_full_name "owner/repo" 'path "canon/character.md")))
           (check-equal? (category result) expected)
           (check-false (string-contains? (jsexpr->string result) prose))))
       (check-equal? (category (call-tool "upload_github_text" (hasheq 'path "x"))) "INVALID_CONTENT")
       (check-equal? (puts) 0))))
  (test-case "cancelled write cannot submit"
    (fixture (lambda (puts raw)
               (define state (make-request-state))
               (request-cancel! state)
               (parameterize ([current-request-state state]) (check-exn exn:cancelled? (lambda () (run prose))))
               (check-equal? (puts) 0))))
  (test-case "race at submission reports current SHA without retry"
    (define writes 0)
    (define sha old-sha)
    (parameterize ([current-github-writes-enabled #t] [current-github-token (lambda () "synthetic")]
                   [current-github-text-log void]
                   [current-github-request
                    (lambda (target accept limit #:payload [payload #f])
                      (when payload
                        (set! writes (add1 writes))
                        (set! sha (make-string 40 #\d))
                        (http-error 409))
                      (jsexpr->bytes (hasheq 'type "file" 'path "canon/character.md" 'size 3 'sha sha)))])
      (define result (run prose #:sha old-sha))
      (check-equal? (category result) "SHA_CONFLICT")
      (check-equal? (hash-ref (value result) 'current_sha) sha)
      (check-equal? (hash-ref (value result) 'write_state) "rejected")
      (check-equal? writes 1)))
  (test-case "known conflict is replayed accurately from journal"
    (define directory (make-temporary-file "github-text~a" 'directory))
    (dynamic-wind void
                  (lambda ()
                    (parameterize ([current-github-text-state-directory directory])
                      (fixture (lambda (puts raw)
                                 (define first (run prose #:key "conflict"))
                                 (check-equal? (category first) "SHA_CONFLICT")
                                 (check-equal? (value (run prose #:key "conflict")) (value first))
                                 (check-equal? (puts) 0)) #:initial #"old")))
                  (lambda () (delete-directory/files directory))))
  (test-case "malformed API and corrupted read never report verified success"
    (fixture (lambda (puts raw)
               (define request (current-github-request))
               (parameterize ([current-github-request
                               (lambda (target accept limit #:payload [payload #f])
                                 (if payload #"{}" (request target accept limit)))])
                 (define result (run prose))
                 (check-equal? (category result) "GITHUB_API_ERROR")
                 (check-equal? (hash-ref (value result) 'write_state) "uncertain"))))
    (fixture (lambda (puts raw)
               (define request (current-github-request))
               (parameterize ([current-github-request
                               (lambda (target accept limit)
                                 (if (string-contains? target "/git/blobs/") #"bad" (request target accept limit)))])
                 (check-equal? (category (call-tool "fetch_github_text" (hasheq 'repository_full_name "owner/repo" 'path "canon/character.md")))
                               "GITHUB_API_ERROR"))) #:initial #"old"))
  (test-case "invalid paths branches and input structure never reach GitHub"
    (parameterize ([current-github-writes-enabled #t] [current-github-text-log void]
                   [current-github-request (lambda args (error "No requests permitted"))])
      (for ([branch '("" "../main" "main.lock" "main..test" "a b" "a@{b" "a/" "a[" "a\\b")])
        (check-equal? (category (call-github-text (lambda () (upload-github-text "o/r" "a.md" branch prose "Edit")))) "INVALID_CONTENT"))
      (for ([args (list (hasheq 'repository_full_name "o/r" 'path "../x")
                        (hasheq 'repository_full_name "o/r" 'path "x" 'extra "x")
                        (hasheq 'repository_full_name "o/r" 'path 12) '())])
        (check-equal? (category (call-tool "fetch_github_text" args)) "INVALID_CONTENT"))))
  (test-case "HTTP status survives shared transport without raw upstream body"
    (parameterize ([current-github-token (lambda () "synthetic_token")]
                   [current-github-sendrecv
                    (lambda (host target #:ssl? ssl #:content-decode decode #:headers headers #:method method #:data body)
                      (values #"HTTP/1.1 403 Forbidden" '() (open-input-bytes #"SECRET")))])
      (define result (call-github-text (lambda () (fetch-github-text "o/r" "a.md"))))
      (check-equal? (category result) "PERMISSION_DENIED")
      (check-false (string-contains? (jsexpr->string result) "SECRET")))))

(define (patch operation #:sha [sha old-sha] #:key [key 'null] #:fields [fields (hasheq)])
  (call-tool "patch_github_text"
             (for/fold ([args (hasheq 'repository_full_name "owner/repo" 'path "canon/character.md"
                                     'branch "test" 'expected_sha sha 'message "Patch canon"
                                     'operation operation 'idempotency_key key)])
                       ([(k v) (in-hash fields)]) (hash-set args k v))))
(define (with-journal thunk)
  (define directory (make-temporary-file "github-patch~a" 'directory))
  (dynamic-wind void (lambda () (parameterize ([current-github-text-state-directory directory]) (thunk directory)))
                (lambda () (delete-directory/files directory))))
(module+ test
  (test-case "literal patches preserve BOM, Unicode, mixed newlines and unrelated bytes"
    (define before "\uFEFF# Faië\r\nMaië: .* [anchor]\n日本語 🌿\r\n")
    (for ([op '("append" "replace_exact" "insert_after")]
          [fields (list (hasheq 'content "\nNext")
                        (hasheq 'anchor ".* [anchor]" 'replacement "**new**")
                        (hasheq 'anchor "Maië:" 'content " hello"))]
          [after (list (string-append before "\nNext")
                       "\uFEFF# Faië\r\nMaië: **new**\n日本語 🌿\r\n"
                       "\uFEFF# Faië\r\nMaië: hello .* [anchor]\n日本語 🌿\r\n")])
      (fixture (lambda (puts raw)
                 (define result (patch op #:sha (github-blob-sha (raw)) #:fields fields))
                 (check-false (hash-ref result 'isError #f))
                 (check-true (hash-ref (value result) 'verified))
                 (check-equal? (hash-ref (value result) 'operation) op)
                 (check-equal? (hash-ref (value result) 'blob_sha) (github-blob-sha (string->bytes/utf-8 after)))
                 (check-equal? (raw) (string->bytes/utf-8 after)) (check-equal? (puts) 1))
               #:initial (string->bytes/utf-8 before))))
  (test-case "missing, ambiguous and overlapping anchors never submit"
    (for ([initial '(#"old" #"old old" #"aaa")]
          [anchor '("absent" "old" "aa")]
          [reason '("ANCHOR_NOT_FOUND" "ANCHOR_AMBIGUOUS" "ANCHOR_AMBIGUOUS")])
      (fixture (lambda (puts raw)
                 (define result (patch "replace_exact" #:sha (github-blob-sha initial)
                                       #:fields (hasheq 'anchor anchor 'replacement "new")))
                 (check-equal? (category result) "INVALID_CONTENT")
                 (check-equal? (hash-ref (value result) 'reason) reason)
                 (check-equal? (hash-ref (value result) 'stage) "patch_validation")
                 (check-equal? (raw) initial) (check-equal? (puts) 0)) #:initial initial)))
  (test-case "patch requires existing file, fresh SHA and valid UTF-8"
    (for ([initial (list #f #"old" #"\377")]
          [sha (list old-sha (make-string 40 #\b) (github-blob-sha #"\377"))]
          [expected '("PATH_NOT_FOUND" "SHA_CONFLICT" "INVALID_CONTENT")])
      (fixture (lambda (puts raw)
                 (check-equal? (category (patch "append" #:sha sha #:fields (hasheq 'content "x"))) expected)
                 (check-equal? (puts) 0)) #:initial initial)))
  (test-case "patch rejects ambiguous field combinations, null SHA and oversized result"
    (fixture (lambda (puts raw)
               (for ([op '("append" "insert_after" "replace_exact" "bad" "append" "replace_exact")]
                     [fields (list (hasheq 'content "x" 'anchor "old")
                                   (hasheq 'anchor "old" 'replacement "x")
                                   (hasheq 'anchor "" 'replacement "x")
                                   (hasheq) (hasheq 'content "x" 'replacement "")
                                   (hasheq 'anchor "old" 'replacement "x" 'content ""))])
                 (check-equal? (category (patch op #:fields fields)) "INVALID_CONTENT"))
               (check-equal? (category (patch "append" #:sha 'null #:fields (hasheq 'content "x"))) "INVALID_CONTENT")
               (check-equal? (category (patch "append" #:fields (hasheq 'content (make-string 1048576 #\x)))) "INVALID_CONTENT")
               (check-equal? (puts) 0)) #:initial #"old"))
  (test-case "empty append target and empty replacement are supported"
    (fixture (lambda (puts raw)
               (check-true (hash-ref (value (patch "append" #:sha (github-blob-sha #"") #:fields (hasheq 'content "Maië"))) 'verified))
               (check-equal? (raw) (string->bytes/utf-8 "Maië"))) #:initial #"")
    (fixture (lambda (puts raw)
               (check-true (hash-ref (value (patch "replace_exact" #:fields (hasheq 'anchor "old" 'replacement ""))) 'verified))
               (check-equal? (raw) #"")) #:initial #"old"))
  (test-case "patch replay precedes lookup and never applies twice; changed args fail"
    (with-journal
     (lambda (directory)
       (fixture (lambda (puts raw)
                  (define first (patch "append" #:key "patch" #:fields (hasheq 'content " new")))
                  (check-true (hash-ref (value first) 'verified))
                  (parameterize ([current-github-request (lambda args (error "No requests on replay"))])
                    (check-equal? (value (patch "append" #:key "patch" #:fields (hasheq 'content " new"))) (value first)))
                  (check-equal? (category (patch "append" #:key "patch" #:fields (hasheq 'content " changed"))) "INVALID_CONTENT")
                  (check-equal? (category (run "old new" #:sha old-sha #:key "patch")) "INVALID_CONTENT")
                  (check-equal? (puts) 1)
                  (for ([file (in-directory directory)] #:when (file-exists? file))
                    (check-false (string-contains? (file->string file) "old new")))) #:initial #"old"))))
  (test-case "patch recovery verifies saved immutable commit without reapplying"
    (with-journal
     (lambda (_)
       (define broken? #t)
       (fixture (lambda (puts raw)
                  (define first (patch "append" #:key "recover" #:fields (hasheq 'content " new")))
                  (check-equal? (hash-ref (value first) 'write_state) "committed")
                  (set! broken? #f)
                  (check-true (hash-ref (value (patch "append" #:key "recover" #:fields (hasheq 'content " new"))) 'verified))
                  (check-equal? (raw) #"old new") (check-equal? (puts) 1))
                #:initial #"old" #:verify-error (lambda () (when broken? (http-error 503)))))))
  (test-case "uncertain patch cannot resubmit and cancelled patch cannot submit"
    (with-journal
     (lambda (_)
       (fixture (lambda (puts raw)
                  (for ([i (in-range 2)])
                    (define result (patch "append" #:key "uncertain" #:fields (hasheq 'content " new")))
                    (check-equal? (hash-ref (value result) 'write_state) "uncertain"))
                  (check-equal? (puts) 1)) #:initial #"old" #:put-error (lambda () (error "lost")))))
    (fixture (lambda (puts raw)
               (define state (make-request-state))
               (request-cancel! state)
               (parameterize ([current-request-state state])
                 (check-exn exn:cancelled? (lambda () (patch "append" #:fields (hasheq 'content "x")))))
               (check-equal? (puts) 0)) #:initial #"old"))
  (test-case "correlation records receipt stages, counts and failures without document text"
    (fixture
     (lambda (puts raw)
       (define events '())
       (define id (make-string 32 #\a))
       (parameterize ([current-github-text-log (lambda (event) (set! events (append events (list event))))])
         (define result (patch "append" #:fields (hasheq 'content "SECRET-Faië" 'request_id id)))
         (check-equal? (hash-ref (hash-ref result '_meta) 'request_id) id)
         (check-true (andmap (lambda (event) (equal? (hash-ref event 'request_id) id)) events))
         (define stages (map (lambda (event) (hash-ref event 'stage)) events))
         (for ([stage '("request_received" "authorization_completed" "sha_verified" "existing_file_fetched"
                       "patch_validated" "github_commit_submitted" "commit_verified" "request_completed")])
           (check-not-false (member stage stages)))
         (check-equal? (hash-ref (hash-ref (car events) 'content) 'characters) 11)
         (check-equal? (hash-ref (hash-ref (car events) 'content) 'utf8_bytes) 12)
         (check-false (string-contains? (jsexpr->string events) "SECRET"))
         (set! events '())
         (define bad (patch "append" #:fields (hasheq 'content "x" 'request_id "bad\ninjection")))
         (check-equal? (category bad) "INVALID_CONTENT")
         (check-equal? (map (lambda (e) (hash-ref e 'stage)) events)
                       '("request_received" "request_validation" "request_failed"))
         (check-false (string-contains? (jsexpr->string events) "injection")))) #:initial #"old"))
  (test-case "patch honors write gate and missing credentials"
    (fixture (lambda (puts raw)
               (parameterize ([current-github-token (lambda () #f)])
                 (check-equal? (category (patch "append" #:fields (hasheq 'content "x"))) "AUTH_REQUIRED"))
               (parameterize ([current-github-writes-enabled #f])
                 (check-false (ormap (lambda (t) (equal? (hash-ref t 'name) "patch_github_text")) (tool-list)))
                 (check-equal? (category (call-github-text (lambda () (patch-github-text "owner/repo" "canon/character.md" "test" old-sha "Edit" "append" #:content "x")))) "PERMISSION_DENIED"))
               (check-equal? (puts) 0)) #:initial #"old")))
