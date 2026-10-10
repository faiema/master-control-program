#lang racket/base
;; SPDX-License-Identifier: AGPL-3.0-only

(require file/sha1 json net/uri-codec racket/string
         "common.rkt" "media.rkt" "github-http.rkt")
(provide fetch-github-image github-blob-sha)

(define (github-blob-sha raw)
  (sha1 (open-input-bytes
         (bytes-append (string->bytes/utf-8 (format "blob ~a\u0000" (bytes-length raw))) raw))))

(define (fetch-github-image repository path [ref 'null])
  (unless (and (string? repository) (<= (string-length repository) 256)
               (regexp-match? #px"^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$" repository)
               (not (member (cadr (string-split repository "/")) '("." ".."))))
    (bridge-error "Validation: repository_full_name must be owner/repository, not a URL."))
  (unless (and (string? path) (<= 1 (string-length path) 4096)
               (not (regexp-match? #px"[\u0000-\u001f\u007f\\\\]" path))
               (for/and ([part (in-list (string-split path "/" #:trim? #f))])
                 (not (member part '("" "." "..")))))
    (bridge-error "Validation: path must be a relative repository file path without empty or dot segments."))
  (unless (or (eq? ref 'null)
              (and (string? ref) (<= 1 (string-length ref) 1024)
                   (not (regexp-match? #px"[\u0000-\u001f\u007f]" ref))))
    (bridge-error "Validation: ref must be a nonempty branch, tag, or commit SHA."))
  (define root (string-append "/repos/" repository))
  (define target
    (string-append root "/contents/"
                   (string-join (map uri-encode (string-split path "/")) "/")
                   (if (eq? ref 'null) "" (string-append "?ref=" (uri-encode ref)))))
  (define metadata
    (with-handlers ([exn:fail:bridge? raise]
                    [exn:fail? (lambda (_) (bridge-error "GitHub: invalid file metadata response."))])
      (parse-json ((current-github-request) target "application/vnd.github.object+json" (* 2 1024 1024)))))
  (unless (and (hash? metadata) (equal? (hash-ref metadata 'type #f) "file")
               (not (hash-ref metadata 'submodule_git_url #f))
               (equal? (hash-ref metadata 'path #f) path))
    (bridge-error "GitHub: expected a regular repository file at the requested path, not a directory or submodule."))
  (define sha (hash-ref metadata 'sha #f))
  (define size (hash-ref metadata 'size #f))
  (unless (and (string? sha) (regexp-match? #px"^[0-9a-f]{40}$" sha)
               (exact-nonnegative-integer? size))
    (bridge-error "GitHub: file metadata is missing a valid blob SHA or size."))
  (unless (<= 1 size max-image-bytes)
    (bridge-error "GitHub: image must be nonempty and at most 5 MiB (local limit)."))
  ;; Fetch by immutable SHA, not the moving branch or expiring download_url.
  ;; The contents API intentionally leaves content empty for files over 1 MiB.
  (define raw ((current-github-request) (string-append root "/git/blobs/" sha)
                                      "application/vnd.github.raw+json" max-image-bytes))
  (unless (and (= size (bytes-length raw)) (equal? sha (github-blob-sha raw)))
    (bridge-error "GitHub: image size or blob SHA mismatch; the response is truncated or inconsistent. Retry the read."))
  (when (regexp-match? #rx#"^version https://git-lfs.github.com/spec/v1" raw)
    (bridge-error "GitHub: this file is a Git LFS pointer; LFS image retrieval is not supported."))
  (define provenance
    (hash-set* (inspect-image raw)
               'repository_full_name repository 'path path 'ref ref 'blob_sha sha
               'provenance "GitHub contents lookup; original bytes verified against Git blob SHA-1. ref is the requested ref (null means default branch)."))
  (hasheq 'content
          (list (hasheq 'type "text" 'text (jsexpr->string provenance))
                (hasheq 'type "image" 'data (encode-base64 raw)
                        'mimeType (hash-ref provenance 'mime_type)))))
