#lang racket/base
;; SPDX-License-Identifier: AGPL-3.0-only
(require json racket/file racket/string racket/random file/sha1
         "common.rkt" "media.rkt" "github-media.rkt" "github-http.rkt"
         "github-upload.rkt" "lib/cancellation.rkt")
(provide fetch-github-text upload-github-text patch-github-text call-github-text
         current-github-text-state-directory current-github-text-log)

(define max-text-bytes (* 1024 1024))
(define current-github-text-state-directory
  (make-parameter (getenv "MCP_GITHUB_TEXT_STATE_DIR")))
;; Serialize events from concurrent invocations without logging their contents.
(define log-lock (make-semaphore 1))
(define current-github-text-log
  (make-parameter (lambda (event)
                    (call-with-semaphore log-lock
                      (lambda ()
                        (write-json event (current-error-port))
                        (newline (current-error-port))
                        (flush-output (current-error-port)))))))
(define current-correlation (make-parameter #f))
(define current-text-tool (make-parameter "github_text"))
(define (log-event! stage [details (hasheq)])
  ((current-github-text-log)
   (hash-set* details 'event "github_text" 'request_id (current-correlation)
              'tool (current-text-tool) 'stage stage 'timestamp_ms (current-inexact-milliseconds))))
(define (correlation? id) (and (string? id) (regexp-match? #px"^[0-9a-f]{32}$" id)))
(define (request-counts args)
  (if (not (hash? args)) (hasheq)
      (for/fold ([counts (hasheq 'arguments_json_bytes (bytes-length (jsexpr->bytes args)))]) ([field '(content anchor replacement)])
        (define v (hash-ref args field #f))
        (if (string? v)
            (hash-set counts field (hasheq 'characters (string-length v)
                                          'utf8_bytes (bytes-length (string->bytes/utf-8 v))))
            counts))))
(define current-stage (make-parameter "request_validation"))
(define current-commit (make-parameter #f))
(define current-write-state (make-parameter "not_submitted"))
(struct exn:fail:text exn:fail:bridge (category details) #:transparent)
(define (fail category message [details (hasheq)])
  (raise (exn:fail:text message (current-continuation-marks) category details)))
(define (stage! name) (current-stage name) (log-event! name))
(define (sha? s) (and (string? s) (regexp-match? #px"^[0-9a-f]{40}$" s)))
(define (error-result category message [details (hasheq)])
  (define value
    (hash-set* (if (current-commit)
                   (hash-set* details 'commit_sha (hash-ref (current-commit) 'commit_sha)
                              'commit_url (hash-ref (current-commit) 'commit_url)) details) 'category category 'message message 'stage (current-stage)
               'write_state (current-write-state) 'automatic_retry #f))
  (hasheq 'isError #t 'structuredContent value
          'content (list (hasheq 'type "text" 'text (jsexpr->string value)))))
;; Includes schema validation when called by the server. An upstream block that
;; never reaches this process cannot be classified here. Never infer policy.
(define (exception-result e)
  (cond [(exn:fail:text? e) (error-result (exn:fail:text-category e) (exn-message e) (exn:fail:text-details e))]
        [(exn:fail:github? e)
         (define code (exn:fail:github-status e))
         (error-result (case code [(401) "AUTH_REQUIRED"] [(403) "PERMISSION_DENIED"]
                             [(404) "PATH_NOT_FOUND"] [else "GITHUB_API_ERROR"])
                       (exn-message e) (hasheq 'http_status code))]
        [(exn:fail:bridge? e)
         (error-result (if (equal? (current-stage) "request_validation")
                           "INVALID_CONTENT" "UNKNOWN_UPSTREAM_ERROR") (exn-message e))]
        [else (error-result "UNKNOWN_UPSTREAM_ERROR"
                            "Local processing or transport failed. Inspect the reported stage and write state; do not retry an uncertain write with a new key.")]))
(define (call-github-text thunk #:request-id [supplied #f]
                          #:tool [tool "github_text"] #:arguments [args #f])
  (define id (if (correlation? supplied) supplied (bytes->hex-string (crypto-random-bytes 16))))
  (parameterize ([current-stage "request_validation"] [current-write-state "not_submitted"]
                 [current-commit #f] [current-correlation id] [current-text-tool tool])
    (log-event! "request_received" (request-counts args))
    (define result
      (with-handlers ([exn:fail? (lambda (e)
                                  (define result (exception-result e))
                                  (log-event! "request_failed"
                                              (hasheq 'failure_stage (current-stage)
                                                      'category (hash-ref (hash-ref result 'structuredContent) 'category)
                                                      'write_state (current-write-state)))
                                  result)])
        (stage! "request_validation")
        (unless (or (not supplied) (eq? supplied 'null) (correlation? supplied))
          (fail "INVALID_CONTENT" "request_id must be 32 lowercase hexadecimal characters; use a fresh ID for each invocation."))
        (define value (thunk))
        (log-event! "request_completed"
                    (for/fold ([details (hasheq)]) ([field '(commit_sha blob_sha size_bytes operation)])
                      (if (hash-has-key? value field) (hash-set details field (hash-ref value field)) details)))
        (hasheq 'structuredContent value
                'content (list (hasheq 'type "text" 'text (jsexpr->string value))))))
    ;; Invocation metadata is deliberately outside the durable, replayable receipt.
    (hash-set result '_meta (hasheq 'request_id id))))

(define (metadata repository path ref)
  (define value (parse-json ((current-github-request) (github-file-target repository path ref)
                            "application/vnd.github.object+json" (* 2 max-text-bytes))))
  (unless (and (hash? value) (equal? (hash-ref value 'type #f) "file")
               (equal? (hash-ref value 'path #f) path)
               (not (hash-ref value 'submodule_git_url #f))
               (sha? (hash-ref value 'sha #f))
               (exact-nonnegative-integer? (hash-ref value 'size #f)))
    (fail "GITHUB_API_ERROR" "Expected regular-file metadata with a blob SHA and size."))
  value)
(define (text-bytes value)
  (unless (string? value) (fail "INVALID_CONTENT" "content must be a UTF-8 text string."))
  (define raw (string->bytes/utf-8 value))
  (unless (<= (bytes-length raw) max-text-bytes)
    (fail "INVALID_CONTENT" "Text exceeds the local 1 MiB UTF-8 limit."))
  raw)
(define (read-text repository info)
  (define size (hash-ref info 'size))
  (unless (<= size max-text-bytes) (fail "INVALID_CONTENT" "Text exceeds the local 1 MiB UTF-8 limit."))
  ;; Empty blobs need no HTTP body (the shared image transport rejects empty bodies).
  (define raw (if (zero? size) #""
                  ((current-github-request)
                   (string-append "/repos/" repository "/git/blobs/" (hash-ref info 'sha))
                   "application/vnd.github.raw+json" max-text-bytes)))
  (unless (and (= size (bytes-length raw)) (equal? (github-blob-sha raw) (hash-ref info 'sha)))
    (fail "GITHUB_API_ERROR" "File size or Git blob SHA mismatch; retry the read."))
  (with-handlers ([exn:fail? (lambda (_) (fail "INVALID_CONTENT" "Repository file is not valid UTF-8."))])
    (bytes->string/utf-8 raw #f)))
(define (fetch-github-text repository path [ref 'null])
  (github-file-target repository path ref)
  (stage! "existing_file_lookup")
  (define info (metadata repository path ref))
  (stage! "content_preparation")
  (hasheq 'content (read-text repository info) 'blob_sha (hash-ref info 'sha)
          'repository_full_name repository 'path path 'ref ref 'size_bytes (hash-ref info 'size)))

(define (valid-branch? branch)
  (and (string? branch) (<= 1 (string-length branch) 1024)
       (not (regexp-match? #px"[\u0000-\u0020\u007f~^:?*\\[\\\\]" branch))
       (not (regexp-match? #rx"\\.\\.|@\\{" branch))
       (not (string=? branch "@")) (not (string-prefix? branch "-"))
       (not (string-suffix? branch "."))
       (for/and ([part (in-list (string-split branch "/" #:trim? #f))])
         (and (not (string=? part "")) (not (string-prefix? part "."))
              (not (string-suffix? part ".lock"))))))
(define (existing repository path branch)
  (with-handlers ([exn:fail:github? (lambda (e) (if (= 404 (exn:fail:github-status e)) #f (raise e)))])
    (metadata repository path branch)))
(define (conflict info)
  (fail "SHA_CONFLICT" "Destination differs from the authorized version. Read and review it before supplying a new expected_sha."
        (hasheq 'current_sha (if info (hash-ref info 'sha) 'null))))

;; One directory is an exclusive, cross-process claim. It is never removed or
;; automatically reused. A crash after claiming can sacrifice availability but
;; cannot resubmit a write. Atomic receipts contain hashes/provenance, not prose.
(define write-lock (make-semaphore 1))
(define (journal-write directory name value)
  (call-with-atomic-output-file (build-path directory name)
    (lambda (out temporary) (write-json value out))))
(define (fingerprint value)
  (bytes->hex-string (sha256-bytes (open-input-bytes (jsexpr->bytes value)))))
(define (claim-key key signature)
  (define root (current-github-text-state-directory))
  (unless (and (path-string? root) (absolute-path? root))
    (fail "INVALID_CONTENT" "Idempotency requires an absolute, persistent MCP_GITHUB_TEXT_STATE_DIR on this server."))
  (make-directory* root)
  (define directory (build-path root (fingerprint key)))
  (define fresh?
    (with-handlers ([exn:fail:filesystem:exists? (lambda (_) #f)])
      (make-directory directory) #t))
  (cond [fresh? (file-or-directory-permissions directory #o700)
                (journal-write directory "request.json" (hasheq 'fingerprint signature))]
        [else
         (define request-file (build-path directory "request.json"))
         (unless (file-exists? request-file)
           (fail "UNKNOWN_UPSTREAM_ERROR" "Idempotency claim is incomplete or in progress; no new submission occurred."))
         (unless (equal? signature (hash-ref (call-with-input-file request-file read-json) 'fingerprint #f))
           (fail "INVALID_CONTENT" "Idempotency key was already used for different arguments."))])
  (values directory fresh?))

(define (upload-github-text repository path branch content message
                            #:expected-sha [expected 'null] #:idempotency-key [key 'null])
  (define raw (text-bytes content))
  (write-github-text repository path branch message expected key
                     (list repository path branch (bytes->hex-string (sha256-bytes raw)) expected message)
                     (lambda (_) raw) (if (eq? expected 'null) "create" "replace")))

;; All patches are literal. No regex, normalization, newline insertion or fuzzy matching.
(define (patch-github-text repository path branch expected message operation
                           #:anchor [anchor #f] #:replacement [replacement #f]
                           #:content [content #f] #:idempotency-key [key 'null])
  (unless (sha? expected) (fail "INVALID_CONTENT" "Patches require the current 40-character expected_sha."))
  (unless (member operation '("replace_exact" "insert_after" "append"))
    (fail "INVALID_CONTENT" "operation must be replace_exact, insert_after, or append."))
  (cond [(equal? operation "append")
         (unless (and (string? content) (not anchor) (not replacement))
           (fail "INVALID_CONTENT" "append requires content and forbids anchor and replacement."))]
        [else
         (unless (and (string? anchor) (positive? (string-length anchor))
                      (if (equal? operation "replace_exact")
                          (and (string? replacement) (not content))
                          (and (string? content) (not replacement))))
           (fail "INVALID_CONTENT" "Anchored patches require a nonempty anchor; replace_exact takes replacement, insert_after takes content. Other edit fields must be omitted."))])
  (for ([v (in-list (list anchor replacement content))] #:when v) (text-bytes v))
  (define (prepare info)
    (define old (read-text repository info))
    (stage! "existing_file_fetched")
    (stage! "patch_validation")
    (define next
      (if (equal? operation "append") (string-append old content)
          (let* ([pattern (regexp (regexp-quote anchor))]
                 [match (regexp-match-positions pattern old)])
            (unless match (fail "INVALID_CONTENT" "Patch anchor was not found." (hasheq 'reason "ANCHOR_NOT_FOUND")))
            (define start (caar match))
            (define end (cdar match))
            ;; Start one character later to reject overlapping occurrences too.
            (when (regexp-match-positions pattern old (add1 start))
              (fail "INVALID_CONTENT" "Patch anchor occurs more than once." (hasheq 'reason "ANCHOR_AMBIGUOUS")))
            (string-append (substring old 0 (if (equal? operation "insert_after") end start))
                           (if (equal? operation "replace_exact") replacement content)
                           (substring old end)))))
    (define raw (text-bytes next))
    (stage! "patch_validated")
    raw)
  (write-github-text repository path branch message expected key
                     (list "patch_github_text" repository path branch expected message operation anchor replacement content)
                     prepare operation))

;; Shared write transaction claims retry protection before reading or applying a
;; patch. Recovery verifies the saved immutable blob; it never reapplies a patch.
(define (write-github-text repository path branch message expected key signature prepare operation)
  (define target (github-file-target repository path))
  (unless (valid-branch? branch) (fail "INVALID_CONTENT" "branch must explicitly name a valid destination branch."))
  (unless (and (string? message) (<= 1 (string-length message) 4096)
               (not (string=? (string-trim message) "")) (not (regexp-match? #rx"\u0000" message)))
    (fail "INVALID_CONTENT" "Provide a nonempty commit message of at most 4096 characters."))
  (unless (or (eq? expected 'null) (sha? expected))
    (fail "INVALID_CONTENT" "expected_sha must be the current 40-character blob SHA; omit for create-only."))
  (unless (or (eq? key 'null) (and (string? key) (<= 1 (string-length key) 256)))
    (fail "INVALID_CONTENT" "idempotency_key must contain 1 to 256 characters."))
  (stage! "authorization")
  (unless (current-github-writes-enabled) (fail "PERMISSION_DENIED" "GitHub writes are disabled; enable MCP_GITHUB_ENABLE_WRITES only for authorized edits."))
  (define token ((current-github-token)))
  (unless (and (string? token) (regexp-match? #px"^[A-Za-z0-9_]+$" token))
    (fail "AUTH_REQUIRED" "Provide a valid server-side MCP_GITHUB_TOKEN with Contents: write permission."))
  (stage! "authorization_completed")
  (call-with-semaphore
   write-lock
   (lambda ()
     (define-values (directory fresh?)
       (if (eq? key 'null) (values #f #t)
           (claim-key key (fingerprint signature))))
     (define (verify receipt [raw #f])
       (current-commit receipt)
       (current-write-state "committed")
       (stage! "commit_verification")
       ;; Verify the immutable commit, not a branch that another writer can move.
       (define info (metadata repository path (hash-ref receipt 'commit_sha)))
       (define verified-raw (string->bytes/utf-8 (read-text repository info)))
       (unless (and (equal? (hash-ref receipt 'blob_sha) (hash-ref info 'sha))
                    (= (hash-ref receipt 'size_bytes) (bytes-length verified-raw))
                    (or (not raw) (bytes=? raw verified-raw)))
         (fail "GITHUB_API_ERROR" "Commit exists but verification failed; inspect the commit before any further write."
               (hasheq 'commit_sha (hash-ref receipt 'commit_sha))))
       (stage! "commit_verified")
       (define verified (hash-set receipt 'verified #t))
       (when directory (journal-write directory "result.json" verified))
       verified)
     (with-handlers ([exn:fail?
                      (lambda (e)
                        (when (and directory fresh? (member (current-write-state) '("not_submitted" "rejected")))
                          (journal-write directory "failure.json" (hash-ref (exception-result e) 'structuredContent)))
                        (raise e))])
       (cond
         [(not fresh?)
          (cond [(file-exists? (build-path directory "failure.json"))
                 (define failure (call-with-input-file (build-path directory "failure.json") read-json))
                 (current-stage (hash-ref failure 'stage))
                 (current-write-state (hash-ref failure 'write_state))
                 (fail (hash-ref failure 'category) (hash-ref failure 'message) failure)]
                [(file-exists? (build-path directory "result.json"))
                 (call-with-input-file (build-path directory "result.json") read-json)]
                [(file-exists? (build-path directory "commit.json"))
                 (verify (call-with-input-file (build-path directory "commit.json") read-json))]
                [else (current-write-state "uncertain")
                      (fail "UNKNOWN_UPSTREAM_ERROR" "This key has an unresolved attempt. No new submission occurred. Inspect the destination and server journal before further writes.")])]
         [else
          (stage! "existing_file_lookup")
          (define info (if (eq? expected 'null) (existing repository path branch)
                           (metadata repository path branch)))
          (unless (if (eq? expected 'null) (not info) (and info (equal? expected (hash-ref info 'sha))))
            (conflict info))
          (stage! "sha_verified")
          (stage! "content_preparation")
          (define raw (prepare info))
          (define sha (github-blob-sha raw))
          (define payload (hasheq 'branch branch 'message message 'content (encode-base64 raw)))
          (stage! "github_api_submission")
          (mark-side-effect-started!)
          (current-write-state "uncertain")
          (define response
            (with-handlers ([exn:fail:github?
                             (lambda (e)
                               (define code (exn:fail:github-status e))
                               (when (and (<= 400 code 499) (not (= code 408))) (current-write-state "rejected"))
                               (when (member code '(409 422))
                                 (define now (with-handlers ([exn:fail? (lambda (_) 'unknown)]) (metadata repository path branch)))
                                 (when (and (not (eq? now 'unknown))
                                            (not (equal? (if now (hash-ref now 'sha) 'null) expected)))
                                   (conflict now)))
                               (raise e))])
              (parse-json ((current-github-request) target "application/vnd.github+json" max-text-bytes
                           #:payload (if (eq? expected 'null) payload (hash-set payload 'sha expected))))))
          (define file (and (hash? response) (hash-ref response 'content #f)))
          (define commit (and (hash? response) (hash-ref response 'commit #f)))
          (unless (and (hash? file) (equal? (hash-ref file 'sha #f) sha)
                       (equal? (hash-ref file 'path #f) path) (hash? commit) (sha? (hash-ref commit 'sha #f)))
            (fail "GITHUB_API_ERROR" "Submission response did not confirm the expected commit. Inspect the destination; do not resubmit blindly."))
          (define receipt
            (hasheq 'repository_full_name repository 'path path 'branch branch
                    'blob_sha sha 'commit_sha (hash-ref commit 'sha) 'size_bytes (bytes-length raw)
                    'media_type "text/plain; charset=utf-8"
                    'operation operation
                    'commit_url (string-append "https://github.com/" repository "/commit/" (hash-ref commit 'sha))))
          (stage! "github_commit_submitted")
          (current-commit receipt)
          (current-write-state "committed")
          (when directory (journal-write directory "commit.json" receipt))
          (verify receipt raw)])))))
