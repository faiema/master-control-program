#lang racket/base
;; SPDX-License-Identifier: AGPL-3.0-only

(require json racket/port "json.rkt" "cancellation.rkt")
(provide serve-tools rpc-error)

;; A tools-only MCP 2025-11-25 transport. The application supplies tool listing
;; and invocation functions; this module has no knowledge of X or image media.
(define protocol-version "2025-11-25")
(define max-frame-bytes (* 8 1024 1024))

(struct exn:fail:rpc exn:fail (code) #:transparent)
(define (rpc-error code message)
  (raise (exn:fail:rpc message (current-continuation-marks) code)))
(define (serve-tools tool-list call-tool #:name name #:version [version "0.1.0"]
                     #:input [input (current-input-port)] #:output [output (current-output-port)])
  (define phase 'new)
  (define owner (make-custodian))
  (define frames (make-channel))
  (define completions (make-channel))
  (define jobs (make-hash))
  (struct job (id owner state))
  (define (emit value) (write-json value output) (newline output) (flush-output output))
  (define (failure id code message)
    (hasheq 'jsonrpc "2.0" 'id id 'error (hasheq 'code code 'message message)))
  (define (start-tool id params)
    (when (>= (hash-count jobs) 8)
      (rpc-error -32000 "Too many active tool calls; wait for completion."))
    (define task (job id (make-custodian owner) (make-request-state)))
    (hash-set! jobs id task)
    (parameterize ([current-custodian (job-owner task)]
                   [current-subprocess-custodian-mode 'kill]
                   [current-request-state (job-state task)])
      (thread
       (lambda ()
         (define response
           (with-handlers ([exn:cancelled? (lambda (_) #f)]
                           [exn:fail:rpc? (lambda (e) (failure id (exn:fail:rpc-code e) (exn-message e)))]
                           [exn:fail? (lambda (_) (failure id -32603 "Internal error; check the operation's outcome before retrying."))])
             (hasheq 'jsonrpc "2.0" 'id id
                     'result (call-tool (hash-ref params 'name #f) (hash-ref params 'arguments (hasheq))))))
         (channel-put completions (cons task response)))))
    'pending)
  (define (cancel-tool params)
    (when (and (hash? params)
               (or (not (hash-has-key? params 'reason)) (string? (hash-ref params 'reason))))
      (define id (hash-ref params 'requestId #f))
      (define task (and (or (string? id) (exact-integer? id)) (hash-ref jobs id #f)))
      (when task
        (case (request-cancel! (job-state task))
          [(cancelled)
           (hash-remove! jobs id)
           (custodian-shutdown-all (job-owner task))
           (eprintf "Request cancelled before side-effect submission.\n")]
          [(deferred) (eprintf "Cancellation deferred until credential update completes.\n")]
          [(submitted) (eprintf "Cancellation arrived after side-effect submission; awaiting outcome. Do not retry.\n")]))))
  (define (dispatch message)
    (define supplied-id (if (hash? message) (hash-ref message 'id 'null) 'null))
    (define id (if (or (string? supplied-id) (exact-integer? supplied-id)) supplied-id 'null))
    (with-handlers ([exn:fail:rpc? (lambda (e) (failure id (exn:fail:rpc-code e) (exn-message e)))]
                    [exn:fail? (lambda (_) (failure id -32603 "Internal error; check the operation's outcome before retrying."))])
      (unless (and (hash? message) (equal? (hash-ref message 'jsonrpc #f) "2.0")
                   (string? (hash-ref message 'method #f))
                   (not (hash-has-key? message 'result)) (not (hash-has-key? message 'error))
                   (or (not (hash-has-key? message 'id)) (string? id) (exact-integer? id)))
        (rpc-error -32600 "Invalid JSON-RPC request."))
      (define method (hash-ref message 'method))
      (define params (hash-ref message 'params (hasheq)))
      (cond
        [(not (hash-has-key? message 'id))
         ;; Notifications never trigger tools, including write operations.
         (when (and (equal? method "notifications/initialized") (eq? phase 'initializing))
           (set! phase 'ready))
         (when (equal? method "notifications/cancelled") (cancel-tool params))
         #f]
        [else
         (unless (hash? params) (rpc-error -32602 "Parameters must be an object."))
         (when (hash-has-key? jobs id) (rpc-error -32600 "Request ID is already active."))
         (define result
           (cond
             [(equal? method "ping") (hasheq)]
             [(equal? method "initialize")
              (unless (and (string? (hash-ref params 'protocolVersion #f))
                           (hash? (hash-ref params 'capabilities #f))
                           (hash? (hash-ref params 'clientInfo #f)))
                (rpc-error -32602 "Invalid initialization parameters."))
              ;; A tunnel can repeat discovery against the same stdio child.
              ;; Re-send metadata without revoking an already completed handshake.
              (when (eq? phase 'new) (set! phase 'initializing))
              (hasheq 'protocolVersion protocol-version 'capabilities (hasheq 'tools (hasheq 'listChanged #f))
                      'serverInfo (hasheq 'name name 'version version))]
             [(not (eq? phase 'ready)) (rpc-error -32600 "Initialize the session first.")]
             [(equal? method "tools/list")
              (when (hash-has-key? params 'cursor) (rpc-error -32602 "This tool list has no pagination cursor."))
              (hasheq 'tools (tool-list))]
             [(equal? method "tools/call") (start-tool id params)]
             [else (rpc-error -32601 "Method not found.")]))
         (and (not (eq? result 'pending)) (hasheq 'jsonrpc "2.0" 'id id 'result result))])))
  (dynamic-wind
    void
    (lambda ()
      (parameterize ([current-custodian owner])
        (thread
         (lambda ()
           (with-handlers ([exn:fail? (lambda (_) (channel-put frames 'read-failed))])
             (let read-loop ()
               ;; Only one bounded frame can wait for dispatch; no unbounded queue.
               (define line (read-bytes-line (make-limited-input-port input (add1 max-frame-bytes) #f) 'linefeed))
               (channel-put frames line)
               (unless (or (eof-object? line) (> (bytes-length line) max-frame-bytes)) (read-loop)))))))
      (let loop ([ended? #f])
        (unless (and ended? (zero? (hash-count jobs)))
          (define event
            (sync (if ended? never-evt (wrap-evt frames (lambda (v) (cons 'frame v))))
                  (wrap-evt completions (lambda (v) (cons 'complete v)))))
          (cond
            [(eq? (car event) 'complete)
             (define task (cadr event))
             (when (eq? task (hash-ref jobs (job-id task) #f))
               (hash-remove! jobs (job-id task))
               (unless (request-cancelled? (job-state task))
                 (when (cddr event) (emit (cddr event)))))
             (custodian-shutdown-all (job-owner task))
             (loop ended?)]
            [else
             (define line (cdr event))
             (cond
               [(eof-object? line) (loop #t)]
               [(eq? line 'read-failed) (void)]
               [(> (bytes-length line) max-frame-bytes)
                (emit (failure 'null -32600 "Message exceeds the local 8 MiB limit; reconnect."))]
               [else
                (define reply
                  (with-handlers ([exn:fail? (lambda (_) (failure 'null -32700 "Invalid JSON."))])
                    (dispatch (parse-json line))))
                (when reply (emit reply))
                (loop ended?)])]))))
    (lambda () (custodian-shutdown-all owner))))
