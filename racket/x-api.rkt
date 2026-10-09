#lang racket/base
;; SPDX-License-Identifier: AGPL-3.0-only

(require racket/list racket/string "auth.rkt" "common.rkt" "http.rkt" "media.rkt" "lib/cancellation.rkt")
(provide x-id post-body upload-media create-post current-writes-enabled)

(define current-writes-enabled (make-parameter #f))
(define (require-writes)
  (unless (current-writes-enabled)
    (bridge-error "Configuration: writes are disabled. Set MCP_X_ENABLE_WRITES=1; publish only on explicit user request.")))

(define (x-id value)
  (unless (and (string? value) (regexp-match? #px"^[0-9]{1,30}$" value))
    (bridge-error "Validation: X IDs must be decimal strings."))
  value)

(define (post-body [text ""] [media-ids '()] [reply-to 'null])
  (define ids (if (eq? media-ids 'null) '() media-ids))
  (unless (and (string? text) (list? ids) (<= (length ids) 4))
    (bridge-error "Validation: provide text and at most four image media IDs."))
  (when (and (string=? (string-trim text) "") (null? ids))
    (bridge-error "Validation: a post needs text or media."))
  (for-each x-id ids)
  (unless (= (length ids) (length (remove-duplicates ids)))
    (bridge-error "Validation: duplicate media IDs."))
  (define body (if (string=? text "") (hasheq) (hasheq 'text text)))
  (define with-media (if (null? ids) body (hash-set body 'media (hasheq 'media_ids ids))))
  (if (eq? reply-to 'null) with-media
      (hash-set with-media 'reply (hasheq 'in_reply_to_tweet_id (x-id reply-to)))))

(define (write-api path payload)
  (require-writes)
  (define token ((current-token-provider)))
  ;; Atomically refuse a pending cancellation or cross the irreversible boundary.
  ;; From here, preserve the bounded HTTP result instead of claiming a rollback.
  (mark-side-effect-started!)
  (define value (json-request (string-append "https://api.x.com/2/" path)
                              #:method "POST" #:payload payload
                              #:headers (hash "Authorization" (string-append "Bearer " token))))
  (define data (hash-ref value 'data #f))
  (unless (hash? data) (bridge-error "X API: missing response data. A write may have succeeded; check X before retrying."))
  (with-handlers ([exn:fail:bridge? (lambda (_) (bridge-error "X API: missing or invalid response ID. Check X before retrying this write."))])
    (x-id (hash-ref data 'id #f)))
  data)

(define (upload-media encoded)
  (require-writes)
  (define-values (raw metadata) (decode-upload encoded))
  (define data (write-api "media/upload" (hasheq 'media (encode-base64 raw) 'media_category "tweet_image")))
  (define processing (hash-ref data 'processing_info #f))
  (when (and processing
             (not (and (hash? processing) (equal? (hash-ref processing 'state #f) "succeeded"))))
    (bridge-error "X upload: media is not ready. Asynchronous processing is unsupported; do not attach it yet."))
  (hash-set* metadata 'media_id (hash-ref data 'id)
             'media_key (hash-ref data 'media_key 'null)
             'expires_after_secs (hash-ref data 'expires_after_secs 'null)))

(define (create-post [text ""] [media-ids '()] [reply-to 'null])
  (require-writes)
  (define data (write-api "tweets" (post-body text media-ids reply-to)))
  (hasheq 'id (hash-ref data 'id) 'url (string-append "https://x.com/i/status/" (hash-ref data 'id))))
