#lang racket/base
;; SPDX-License-Identifier: AGPL-3.0-only

;; ChatGPT file references are capabilities: never echo their signed URLs.
(require json net/http-client openssl racket/list racket/string
         "common.rkt" "media.rkt")
(provide current-file-hosts current-file-inputs-enabled current-file-download file-hosts-from-environment
         read-chatgpt-image inspect-chatgpt-image file-schema)

(define current-file-hosts (make-parameter '()))
(define current-file-inputs-enabled (make-parameter #f))
(define file-schema
  (hasheq 'type "object"
          'properties (hasheq 'download_url (hasheq 'type "string")
                              'file_id (hasheq 'type "string")
                              'mime_type (hasheq 'type "string")
                              'file_name (hasheq 'type "string"))
          'required '("download_url" "file_id") 'additionalProperties #f))

(define (file-hosts-from-environment)
  (define hosts (string-split (or (getenv "MCP_CHATGPT_FILE_HOSTS") "") ","))
  (for ([host (in-list hosts)])
    (unless (and (<= (string-length host) 253)
                 (regexp-match? #px"^[a-z][a-z0-9-]*(?:\\.[a-z0-9][a-z0-9-]*)*\\.[a-z]{2,}$" host))
      (bridge-error "Configuration: MCP_CHATGPT_FILE_HOSTS needs comma-separated exact lowercase DNS names, without ports or wildcards.")))
  hosts)

(define (download host target)
  ;; Separate from X transport: no OAuth headers, redirects, or response logging.
  (with-handlers ([exn:fail:bridge? raise]
                  [exn:fail? (lambda (_) (bridge-error "ChatGPT file: download or TLS failed; request a fresh file reference and check connectivity."))])
    (call/bounded
     30
     (lambda ()
       (define-values (status headers input)
         (http-sendrecv host target #:ssl? (ssl-secure-client-context)
                        #:content-decode '()
                        #:headers '("User-Agent: master-control-program/0.1")))
       (dynamic-wind
         void
         (lambda ()
           (unless (regexp-match? #rx#"^HTTP/[0-9.]+ 200(?: |$)" status)
             (bridge-error "ChatGPT file: download rejected or redirected; request a fresh file reference. No upload occurred."))
           (define raw (read-bytes (add1 max-image-bytes) input))
           (unless (and (bytes? raw) (<= 1 (bytes-length raw) max-image-bytes))
             (bridge-error "ChatGPT file: image must be nonempty and at most 5 MiB."))
           (define mime
             (for/or ([header (in-list headers)])
               (define match (regexp-match #px#"(?i:^content-type:[ \t]*(.*)$)" header))
               (and match (bytes->string/latin-1 (cadr match)))))
           (values raw mime))
         (lambda () (close-input-port input))))
     "ChatGPT file: download timed out; request a fresh file reference. No upload occurred.")))

(define current-file-download (make-parameter download))

(define (read-chatgpt-image file)
  (unless (and (hash? file)
               (for/and ([(key value) (in-hash file)])
                 (and (memq key '(download_url file_id mime_type file_name)) (string? value)))
               (let ([id (hash-ref file 'file_id #f)])
                 (and (string? id) (<= 1 (string-length id) 512))))
    (bridge-error "ChatGPT file: expected a file reference with download_url and file_id."))
  (define url (hash-ref file 'download_url #f))
  (define match
    (and (string? url) (<= (string-length url) 16384)
         (regexp-match #px"^https://([a-z0-9.-]+)(/[^\u0000-\u0020\u007f#\\\\]*)$" url)))
  (unless match
    (bridge-error "ChatGPT file: download host is not allowed. Configure MCP_CHATGPT_FILE_HOSTS with the verified file service hostname; URLs must use HTTPS without credentials, ports, or fragments."))
  (unless (member (cadr match) (current-file-hosts))
    ;; Only the hostname is diagnostic; never include the path or signed query.
    (bridge-error (format "ChatGPT file: host ~a is not allowed. Verify this file service, then add its exact hostname to MCP_CHATGPT_FILE_HOSTS. No download occurred."
                          (cadr match))))
  (define-values (raw mime) ((current-file-download) (cadr match) (caddr match)))
  ;; Generic binary downloads are common. Actual decoded bytes decide the type.
  (define declared (hash-ref file 'mime_type #f))
  (define metadata (inspect-image raw (and mime (not (equal? (string-downcase (string-trim (car (regexp-split #rx";" mime)))) "application/octet-stream")) mime)))
  (when (and declared (not (equal? declared (hash-ref metadata 'mime_type))))
    (bridge-error "ChatGPT file: declared MIME type does not match the image bytes."))
  (values raw metadata))

(define (inspect-chatgpt-image file)
  (define-values (raw metadata) (read-chatgpt-image file))
  (hasheq 'content
          (list (hasheq 'type "text" 'text (jsexpr->string metadata))
                (hasheq 'type "image" 'data (encode-base64 raw)
                        'mimeType (hash-ref metadata 'mime_type)))))
