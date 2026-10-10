#lang racket/base
;; SPDX-License-Identifier: AGPL-3.0-only

(require json racket/list "common.rkt" "media.rkt" "github-media.rkt" "github-upload.rkt" "x-api.rkt" "chatgpt-file.rkt" "lib/mcp-stdio.rkt")
(provide serve tool-list call-tool)

(define string-schema (hasheq 'type "string"))
(define optional-string-schema (hasheq 'type '("string" "null")))
(define (schema properties [required '()])
  (hasheq 'type "object" 'properties properties 'required required 'additionalProperties #f))
(define (annotations write?)
  (hasheq 'readOnlyHint (not write?) 'destructiveHint write?
          'idempotentHint (not write?) 'openWorldHint #t))

(define (tool-list)
  (define files? (or (current-file-inputs-enabled) (pair? (current-file-hosts))))
  (append
   (list (hasheq 'name "fetch_x_media"
                 'description "See an X image: pass a pbs.twimg.com/media URL from the official X MCP. Returns original image content and provenance. Optional IDs are caller-provided, not verified."
                 'inputSchema (schema (hasheq 'url string-schema 'post_id optional-string-schema
                                               'media_key optional-string-schema) '("url"))
                 'annotations (annotations #f))
         (hasheq 'name "fetch_github_image"
                 'description "Read an original PNG/JPEG/WebP from a GitHub repository (max 5 MiB). Returns actual image content and verified blob provenance. Optional ref selects a branch, tag, or commit; private repositories require server-side GitHub credentials."
                 'inputSchema (schema (hasheq 'repository_full_name string-schema 'path string-schema
                                               'ref optional-string-schema) '("repository_full_name" "path"))
                 'annotations (annotations #f)))
   (if files?
       (list (hasheq 'name "inspect_chatgpt_image"
                     'description "Read a ChatGPT image file and return its original image content for visual inspection. Does not upload to X."
                     'inputSchema (schema (hasheq 'file file-schema) '("file"))
                     '_meta (hasheq 'openai/fileParams '("file"))
                     'annotations (annotations #f)))
       '())
   (if (current-github-writes-enabled)
       (list
        (hasheq 'name "upload_github_image"
                'description "WRITE: commit an original PNG/JPEG/WebP (max 5 MiB) to an explicitly chosen GitHub repository, branch and path. Requires user authorization. Omit expected_sha to create only; supply the current blob SHA to authorize replacement. Supply exactly one image source. Never transcribe base64 or retry an uncertain commit blindly."
                'inputSchema
                (let* ([properties (hasheq 'repository_full_name string-schema 'path string-schema
                                          'branch string-schema 'message string-schema
                                          'expected_sha optional-string-schema 'image_base64 string-schema)]
                       [base (schema (if files? (hash-set properties 'file file-schema) properties)
                                     '("repository_full_name" "path" "branch" "message"))])
                  (if files?
                      (hash-set base 'oneOf (list (hasheq 'required '("image_base64"))
                                                  (hasheq 'required '("file"))))
                      (hash-set base 'required '("repository_full_name" "path" "branch" "message" "image_base64"))))
                '_meta (if files? (hasheq 'openai/fileParams '("file")) (hasheq))
                'annotations (annotations #t)))
       '())
   (if (current-writes-enabled)
       (list
        (hasheq 'name "upload_x_media"
                'description "WRITE: upload JPEG/PNG (max 5 MiB) to X on explicit user request. Supply exactly one image source: raw base64 or, when available, a ChatGPT file reference. Never transcribe image base64. Returns an expiring media ID. Never retry blindly."
                'inputSchema (if files?
                                 (hash-set (schema (hasheq 'image_base64 string-schema 'file file-schema))
                                           'oneOf (list (hasheq 'required '("image_base64"))
                                                        (hasheq 'required '("file"))))
                                 (schema (hasheq 'image_base64 string-schema) '("image_base64")))
                '_meta (if files? (hasheq 'openai/fileParams '("file")) (hasheq))
                'annotations (annotations #t))
        (hasheq 'name "create_x_post"
                'description "WRITE: publish a real X post only when explicitly requested. Supports uploaded image IDs and a reply target. Never automatically retry."
                'inputSchema (schema (hasheq 'text string-schema 'reply_to optional-string-schema
                                              'media_ids (hasheq 'type '("array" "null") 'items string-schema 'maxItems 4)))
                'annotations (annotations #t)))
       '())))

(define (text-result value)
  (hasheq 'content (list (hasheq 'type "text" 'text (jsexpr->string value)))))
(define (tool-error message)
  (hasheq 'isError #t 'content (list (hasheq 'type "text" 'text message))))

(define (call-tool name arguments)
  (define tool (findf (lambda (tool) (equal? name (hash-ref tool 'name))) (tool-list)))
  (unless tool (rpc-error -32602 "Unknown or disabled tool."))
  (unless (hash? arguments) (rpc-error -32602 "Tool arguments must be an object."))
  (define properties (hash-ref (hash-ref tool 'inputSchema) 'properties))
  (unless (for/and ([key (in-hash-keys arguments)]) (hash-has-key? properties key))
    (rpc-error -32602 "Unknown tool argument."))
  (with-handlers ([exn:fail:bridge? (lambda (e) (tool-error (exn-message e)))]
                  [exn:fail? (lambda (_) (tool-error "Local processing: unexpected failure. Inspect with synthetic inputs before retrying; a write may have succeeded."))])
    (for ([key (in-list (hash-ref (hash-ref tool 'inputSchema) 'required))])
      (unless (hash-has-key? arguments (string->symbol key))
        (bridge-error "Validation: a required tool argument is missing.")))
    (for ([(key value) (in-hash arguments)])
      (unless (case key
                [(url text image_base64 repository_full_name path branch message) (string? value)]
                [(file) (hash? value)]
                [(post_id media_key reply_to ref expected_sha) (or (string? value) (eq? value 'null))]
                [(media_ids) (or (eq? value 'null) (and (list? value) (andmap string? value)))])
        (bridge-error "Validation: tool argument has the wrong type.")))
    (cond
      [(equal? name "fetch_x_media")
       (fetch-result (hash-ref arguments 'url) (hash-ref arguments 'post_id 'null) (hash-ref arguments 'media_key 'null))]
      [(equal? name "fetch_github_image")
       (fetch-github-image (hash-ref arguments 'repository_full_name) (hash-ref arguments 'path)
                           (hash-ref arguments 'ref 'null))]
      [(equal? name "inspect_chatgpt_image") (inspect-chatgpt-image (hash-ref arguments 'file))]
      [(equal? name "upload_github_image")
       (text-result
        (upload-github-image (hash-ref arguments 'repository_full_name) (hash-ref arguments 'path)
                             (hash-ref arguments 'branch) (hash-ref arguments 'message)
                             #:image-base64 (hash-ref arguments 'image_base64 #f)
                             #:file (hash-ref arguments 'file #f)
                             #:expected-sha (hash-ref arguments 'expected_sha 'null)))]
      [(equal? name "upload_x_media")
       (unless (= 1 (+ (if (hash-has-key? arguments 'file) 1 0)
                       (if (hash-has-key? arguments 'image_base64) 1 0)))
         (bridge-error "Validation: supply exactly one of file or image_base64."))
       (text-result
        (if (hash-has-key? arguments 'file)
            (let-values ([(raw metadata) (read-chatgpt-image (hash-ref arguments 'file))])
              (upload-media (encode-base64 raw)))
            (upload-media (hash-ref arguments 'image_base64))))]
      [else (text-result (create-post (hash-ref arguments 'text "")
                                      (hash-ref arguments 'media_ids '()) (hash-ref arguments 'reply_to 'null)))])))

(define (serve [input (current-input-port)] [output (current-output-port)])
  (serve-tools tool-list call-tool #:name "master-control-program-racket"
               #:input input #:output output))

(module+ main
  (parameterize ([current-github-writes-enabled (equal? (getenv "MCP_GITHUB_ENABLE_WRITES") "1")]
                 [current-writes-enabled (equal? (getenv "MCP_X_ENABLE_WRITES") "1")]
                 [current-file-inputs-enabled (equal? (getenv "MCP_CHATGPT_FILES") "1")]
                 [current-file-hosts (file-hosts-from-environment)])
    (serve)))
