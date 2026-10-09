#lang racket/base
;; SPDX-License-Identifier: AGPL-3.0-only

(require json net/base64 racket/list racket/port racket/runtime-path racket/string
         "common.rkt" "http.rkt")
(provide max-image-bytes media-url inspect-image decode-upload fetch-result encode-base64)

(define max-image-bytes (* 5 1024 1024))
(define-runtime-path helper "image-worker.rkt")

(define (media-url value)
  ;; Strict literal grammar avoids URL-parser normalization and credential tricks.
  (define matched
    (and (string? value)
         (regexp-match #px"^https://pbs\\.twimg\\.com/media/[A-Za-z0-9_-]+(?:\\.(?:jpg|jpeg|png|webp))?(?:\\?([^#\r\n]*))?$" value)))
  (define parts (if (and matched (cadr matched) (not (string=? (cadr matched) "")))
                    (string-split (cadr matched) "&" #:trim? #f) '()))
  (define keys (map (lambda (part) (car (regexp-split #rx"=" part))) parts))
  (unless (and matched (= (length keys) (length (remove-duplicates keys)))
               (for/and ([part (in-list parts)])
                 (regexp-match? #px"^(?:format=(?:jpg|jpeg|png|webp)|name=(?:orig|large|medium|small|thumb|900x900|4096x4096))$" part)))
    (bridge-error "Validation: use a direct HTTPS pbs.twimg.com/media/ image URL, without credentials or custom query parameters."))
  value)

(define (encode-base64 raw) (bytes->string/utf-8 (base64-encode raw #"")))

(define (inspect-image raw [declared-mime #f])
  (unless (and (bytes? raw) (<= 1 (bytes-length raw) max-image-bytes))
    (bridge-error "Media: image must be nonempty and at most 5 MiB (local limit)."))
  ;; Native decoding remains a narrow, offline process boundary. Bytes stay here;
  ;; the helper returns metadata only and receives no X credentials.
  (define metadata
    (call/bounded
     15
     (lambda ()
       (define racket (find-executable-path (find-system-path 'exec-file)))
       (unless racket (bridge-error "Media: cannot locate the running Racket executable."))
       (define-values (process stdout stdin stderr)
         (parameterize ([current-environment-variables (make-environment-variables)])
           (subprocess #f #f #f racket helper)))
       (write-bytes raw stdin)
       (close-output-port stdin)
       (define answer (read-bytes 65537 stdout))
       (close-input-port stdout)
       (close-input-port stderr)
       (subprocess-wait process)
       (unless (and (equal? (subprocess-status process) 0) (bytes? answer)
                    (<= (bytes-length answer) 65536))
         (bridge-error "Media: image validator failed. Check the Racket and native codec installation."))
       (define result (parse-json answer))
       (unless (hash? result) (bridge-error "Media: invalid validator response."))
       (when (hash-has-key? result 'error) (bridge-error (hash-ref result 'error)))
       result)
     "Media: image validation timed out; use a smaller image."))
  (when (and declared-mime
             (not (string=? (string-downcase (string-trim (car (regexp-split #rx";" declared-mime))))
                            (hash-ref metadata 'mime_type))))
    (bridge-error "Media: Content-Type does not match the image bytes."))
  metadata)

(define (decode-upload value)
  (unless (and (string? value) (<= (string-length value) (* 4 (quotient (+ max-image-bytes 2) 3))))
    (bridge-error "Validation: base64 image exceeds the local 5 MiB limit or is not a string."))
  (unless (regexp-match? #px"^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$" value)
    (bridge-error "Validation: expected raw base64 image bytes, not a data URL."))
  (define raw (base64-decode (string->bytes/utf-8 value)))
  (define metadata (inspect-image raw))
  (when (equal? (hash-ref metadata 'mime_type) "image/webp")
    (bridge-error "Upload: use JPEG or PNG; WebP upload is not supported by this adapter."))
  (values raw metadata))

(define (fetch-result url [post-id 'null] [media-key 'null])
  (media-url url)
  (define-values (headers raw) ((current-transport) url #:limit max-image-bytes))
  (define mime (hash-ref headers "content-type" #f))
  (unless mime (bridge-error "Media: server omitted Content-Type."))
  (define metadata
    (hash-set* (inspect-image raw mime)
               'source_url url 'source_post_id post-id 'media_key media-key
               'provenance "URL supplied by caller; post ID and media key are caller-provided"))
  (hasheq 'content
          (list (hasheq 'type "text" 'text (jsexpr->string metadata))
                (hasheq 'type "image" 'data (encode-base64 raw) 'mimeType (hash-ref metadata 'mime_type)))))
