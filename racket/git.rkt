#lang racket/base
;; SPDX-License-Identifier: AGPL-3.0-only
(require json racket/file racket/list racket/path racket/port racket/string racket/system
         net/base64 "common.rkt" "media.rkt")
(provide git-tools call-git current-git-directory current-git-repositories
         current-git-origin current-git-credential current-git-writes-enabled)

(define current-git-directory (make-parameter (getenv "MCP_GIT_DIRECTORY")))
(define current-git-repositories
  (make-parameter (string-split (or (getenv "MCP_GIT_REPOSITORIES") ""))))
(define current-git-origin (make-parameter (or (getenv "MCP_GIT_ORIGIN") "https://faie.net")))
(define current-git-credential (make-parameter (getenv "MCP_GIT_CREDENTIAL_FILE")))
(define current-git-writes-enabled (make-parameter (equal? (getenv "MCP_GIT_ENABLE_WRITES") "1")))
(define read-actions '("status" "tree" "read" "image" "log" "diff" "branches" "fetch"))
(define write-actions '("write" "delete" "commit" "branch" "checkout" "merge" "abort_merge" "push"))
(define (git-tools)
  (if (and (current-git-directory) (pair? (current-git-repositories)))
      (list
       (hasheq 'name "git_repository"
               'description "Use an allowed faie.net Git repository. Reads: status, tree, read, image (actual image content), log, diff, branches, fetch. With writes enabled: write/delete files, commit all staged edits, branch, checkout, merge, abort_merge, push. Workspaces persist and are shared by this owner's calls. Fetch explicitly for fresh remote state. Conflicted merges stay local for inspection and resolution. Push uses normal fast-forward rules; never blindly retry an uncertain push. No shell commands, force-push, reset, rebase or repository deletion."
               'inputSchema
               (hasheq 'type "object" 'additionalProperties #f 'required '("repository" "action")
                       'properties
                       (hasheq 'repository (hasheq 'type "string" 'enum (current-git-repositories))
                               'action (hasheq 'type "string" 'enum (append read-actions (if (current-git-writes-enabled) write-actions '())))
                               'ref (hasheq 'type "string") 'branch (hasheq 'type "string")
                               'path (hasheq 'type "string") 'content (hasheq 'type "string")
                               'message (hasheq 'type "string") 'expected_commit (hasheq 'type "string")))
               'annotations (hasheq 'readOnlyHint (not (current-git-writes-enabled))
                                    'destructiveHint (current-git-writes-enabled)
                                    'idempotentHint #f 'openWorldHint #t)))
      '()))

;; Git never receives caller-controlled command syntax, remote URLs or config.
(define (run-git directory . args)
  (call/bounded
   120
   (lambda ()
     (define env (environment-variables-copy (current-environment-variables)))
     (for ([key (in-list (environment-variables-names env))]
           #:when (regexp-match? #rx#"^GIT_" key))
       (environment-variables-set! env key #f))
     (define (set key value) (environment-variables-set! env key (string->bytes/utf-8 value)))
     (set #"GIT_TERMINAL_PROMPT" "0")
     (set #"GIT_CONFIG_NOSYSTEM" "1")
     (set #"GIT_CONFIG_GLOBAL" "/dev/null")
     (set #"GIT_AUTHOR_NAME" "Faie") (set #"GIT_COMMITTER_NAME" "Faie")
     (set #"GIT_AUTHOR_EMAIL" "git@faie.net") (set #"GIT_COMMITTER_EMAIL" "git@faie.net")
     (when (current-git-credential)
       (define credential (string-trim (file->string (current-git-credential))))
       (when (regexp-match? #px"[\r\n]" credential) (bridge-error "Git: invalid credential file."))
       (set #"GIT_CONFIG_COUNT" "1")
       (set #"GIT_CONFIG_KEY_0" (string-append "http." (current-git-origin) "/.extraHeader"))
       (set #"GIT_CONFIG_VALUE_0" (string-append "Authorization: Basic "
                                                (bytes->string/utf-8 (base64-encode (string->bytes/utf-8 credential) #"")))))
     (define-values (process stdout stdin stderr)
       (parameterize ([current-environment-variables env]
                      [current-subprocess-custodian-mode 'kill])
         (apply subprocess #f #f #f "/usr/bin/git"
                (append (if directory (list "-C" directory) '())
                        '("-c" "core.hooksPath=/dev/null" "-c" "core.fsmonitor=false"
                          "-c" "credential.helper=" "-c" "http.followRedirects=false"
                          "-c" "protocol.file.allow=never" "-c" "protocol.ext.allow=never"
                          "-c" "commit.gpgSign=false" "-c" "tag.gpgSign=false") args))))
     (close-output-port stdin)
     ;; Suppress raw diagnostics: they can contain credentials, URLs or document text.
     (thread (lambda () (copy-port stderr (open-output-nowhere))))
     (define output (read-bytes (add1 (* 6 1024 1024)) stdout))
     (when (and (bytes? output) (> (bytes-length output) (* 6 1024 1024)))
       (bridge-error "Git: output exceeds 6 MiB; narrow the read."))
     (subprocess-wait process)
     (unless (zero? (subprocess-status process))
       (bridge-error "Git command failed. Inspect status for conflicts, check the ref and authentication. A push may have succeeded; fetch and inspect before retrying."))
     (if (eof-object? output) #"" output))
   "Git timed out. Inspect local status and remote refs before retrying a write."))

(define (revision value)
  (unless (and (string? value) (<= 1 (string-length value) 256)
               (regexp-match? #px"^[A-Za-z0-9][A-Za-z0-9._/-]*$" value)
               (not (string-contains? value "..")))
    (bridge-error "Git: ref must be a branch, tag or commit ID without revision expressions."))
  value)
(define (file-path value)
  (unless (and (string? value) (<= 1 (string-length value) 4096)
               (not (regexp-match? #px"[\u0000-\u001f\u007f\\\\]" value))
               (andmap (lambda (part) (and (not (member part '("" "." "..")))
                                           (not (string-ci=? part ".git"))))
                       (string-split value "/" #:trim? #f)))
    (bridge-error "Git: use a relative file path without dot segments or .git."))
  value)
(define (text raw)
  (with-handlers ([exn:fail? (lambda (_) (bridge-error "Git: file is not UTF-8 text; use image for supported images."))])
    (bytes->string/utf-8 raw)))
(define (result value) (hasheq 'content (list (hasheq 'type "text" 'text (jsexpr->string value)))))

(define (call-git arguments)
  (with-handlers ([exn:fail:bridge? (lambda (e) (hasheq 'isError #t 'content (list (hasheq 'type "text" 'text (exn-message e)))))]
                  [exn:fail? (lambda (_) (hasheq 'isError #t 'content (list (hasheq 'type "text" 'text "Git: local operation failed. Inspect status before retrying a write."))))])
    (unless (and (hash? arguments)
                 (for/and ([(key value) (in-hash arguments)])
                   (and (member key '(repository action ref branch path content message expected_commit)) (string? value))))
      (bridge-error "Git: invalid arguments."))
    (define repository (hash-ref arguments 'repository #f))
    (define action (hash-ref arguments 'action #f))
    (unless (and (member repository (current-git-repositories))
                 (regexp-match? #px"^[A-Za-z0-9][A-Za-z0-9._-]*[.]git$" repository)
                 (member action (append read-actions (if (current-git-writes-enabled) write-actions '()))))
      (bridge-error "Git: repository or action is disabled."))
    (unless (regexp-match? #px"^https://[A-Za-z0-9.-]+(:[0-9]+)?$" (current-git-origin))
      (bridge-error "Git: configure an HTTPS origin without credentials or a path."))
    (define cache (path->complete-path (current-git-directory)))
    (make-directory* cache)
    (file-or-directory-permissions cache #o700)
    (define lock (build-path cache (string-append repository ".lock")))
    (with-handlers ([exn:fail:filesystem? (lambda (_) (bridge-error "Git: repository busy. Retry after the current operation; inspect a stale lock after a process crash."))])
      (make-directory lock))
    (dynamic-wind
     void
     (lambda ()
       (define checkout (build-path cache repository))
       (define directory (path->string checkout))
       (when (link-exists? checkout) (bridge-error "Git: workspace cannot be a symlink."))
       (unless (directory-exists? checkout)
         (define staging (make-temporary-file "clone~a" 'directory cache))
         (dynamic-wind
          void
          (lambda ()
            (run-git #f "clone" "--origin" "origin" "--"
                     (string-append (current-git-origin) "/git/" repository) (path->string staging))
            (rename-file-or-directory staging checkout))
          (lambda () (when (directory-exists? staging) (delete-directory/files staging)))))
       (define (git . args) (apply run-git directory args))
       (define (arg key) (hash-ref arguments key (lambda () (bridge-error (format "Git: missing ~a." key)))))
       (define (commit-of ref) (string-trim (text (git "rev-parse" "--verify" (string-append (revision ref) "^{commit}")))))
       (define (head)
         (with-handlers ([exn:fail:bridge? (lambda (_) (make-string 40 #\0))])
           (commit-of "HEAD")))
       (when (member action write-actions)
         (define expected (arg 'expected_commit))
         (unless (and (regexp-match? #px"^[0-9a-f]{40,64}$" expected) (equal? expected (head)))
           (bridge-error "Git: expected_commit differs from local HEAD. Inspect status and history before editing.")))
       (define ref (hash-ref arguments 'ref "HEAD"))
       (define raw
         (cond
           [(equal? action "status") (git "status" "--porcelain=v1" "--branch")]
           [(equal? action "branches") (git "branch" "--all" "--no-color" "--verbose")]
           [(equal? action "fetch") (git "fetch" "--prune" "origin")]
           [(equal? action "tree") (git "ls-tree" "-r" "--long" (commit-of ref))]
           [(equal? action "log") (git "log" "-30" "--format=%H %P %s" (commit-of ref) "--")]
           [(equal? action "diff") (git "diff" "--no-ext-diff" "--no-textconv" (commit-of ref) "--")]
           [(member action '("read" "image"))
            (define path (file-path (arg 'path)))
            (git "show" (string-append (commit-of ref) ":" path))]
           [(member action '("write" "delete"))
            (define path (file-path (arg 'path)))
            (define destination
              (for/fold ([parent checkout]) ([part (in-list (string-split path "/"))])
                (define next (build-path parent part))
                (when (link-exists? next) (bridge-error "Git: editing symlinks is disabled."))
                next))
            (if (equal? action "delete")
                (git "rm" "--" path)
                (begin
                  (when (> (bytes-length (string->bytes/utf-8 (arg 'content))) (* 1024 1024))
                    (bridge-error "Git: text write exceeds 1 MiB."))
                  (make-directory* (path-only destination))
                  (call-with-output-file destination (lambda (out) (display (arg 'content) out)) #:exists 'truncate/replace)
                  (git "add" "--" path)))]
           [(equal? action "commit")
            (define message (arg 'message))
            (unless (<= 1 (string-length message) 4096) (bridge-error "Git: invalid commit message."))
            (git "commit" "-m" message)]
           [(equal? action "branch") (git "branch" "--" (revision (arg 'branch)))]
           [(equal? action "checkout") (git "switch" "--no-guess" (revision (arg 'branch)))]
           [(equal? action "merge") (git "merge" "--no-edit" "--" (commit-of ref))]
           [(equal? action "abort_merge") (git "merge" "--abort")]
           [(equal? action "push")
            (define branch (revision (arg 'branch)))
            (git "check-ref-format" (string-append "refs/heads/" branch))
            (git "push" "origin" (string-append "HEAD:refs/heads/" branch))]))
       (if (equal? action "image")
           (let ([metadata (hash-set* (inspect-image raw) 'repository repository 'commit (commit-of ref) 'path (arg 'path))])
             (hasheq 'content (list (hasheq 'type "text" 'text (jsexpr->string metadata))
                                    (hasheq 'type "image" 'mimeType (hash-ref metadata 'mime_type) 'data (encode-base64 raw)))))
           (result (hasheq 'repository repository 'action action 'head (head) 'output (text raw)))))
     (lambda () (delete-directory lock)))))
