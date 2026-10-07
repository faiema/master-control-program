#lang racket/base

(require json racket/list "common.rkt" "media.rkt" "x-api.rkt" "lib/mcp-stdio.rkt")
(provide serve tool-list call-tool)

(define string-schema (hasheq 'type "string"))
(define optional-string-schema (hasheq 'type '("string" "null")))
(define (schema properties [required '()])
  (hasheq 'type "object" 'properties properties 'required required 'additionalProperties #f))
(define (annotations write?)
  (hasheq 'readOnlyHint (not write?) 'destructiveHint write?
          'idempotentHint (not write?) 'openWorldHint #t))

(define (tool-list)
  (append
   (list (hasheq 'name "fetch_x_media"
                 'description "See an X image: pass a pbs.twimg.com/media URL from the official X MCP. Returns original image content and provenance. Optional IDs are caller-provided, not verified."
                 'inputSchema (schema (hasheq 'url string-schema 'post_id optional-string-schema
                                               'media_key optional-string-schema) '("url"))
                 'annotations (annotations #f)))
   (if (current-writes-enabled)
       (list
        (hasheq 'name "upload_x_media"
                'description "WRITE: upload raw base64 JPEG/PNG (max 5 MiB) to X on explicit user request. Returns an expiring media ID. Never retry blindly."
                'inputSchema (schema (hasheq 'image_base64 string-schema) '("image_base64"))
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
                [(url text image_base64) (string? value)]
                [(post_id media_key reply_to) (or (string? value) (eq? value 'null))]
                [(media_ids) (or (eq? value 'null) (and (list? value) (andmap string? value)))])
        (bridge-error "Validation: tool argument has the wrong type.")))
    (cond
      [(equal? name "fetch_x_media")
       (fetch-result (hash-ref arguments 'url) (hash-ref arguments 'post_id 'null) (hash-ref arguments 'media_key 'null))]
      [(equal? name "upload_x_media") (text-result (upload-media (hash-ref arguments 'image_base64)))]
      [else (text-result (create-post (hash-ref arguments 'text "")
                                      (hash-ref arguments 'media_ids '()) (hash-ref arguments 'reply_to 'null)))])))

(define (serve [input (current-input-port)] [output (current-output-port)])
  (serve-tools tool-list call-tool #:name "master-control-program-racket"
               #:input input #:output output))

(module+ main
  (parameterize ([current-writes-enabled (equal? (getenv "MCP_X_ENABLE_WRITES") "1")])
    (serve)))
