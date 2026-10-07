#lang racket/base

(require json racket/port "json.rkt")
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
  (define (emit value) (write-json value output) (newline output) (flush-output output))
  (define (failure id code message)
    (hasheq 'jsonrpc "2.0" 'id id 'error (hasheq 'code code 'message message)))
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
         #f]
        [else
         (unless (hash? params) (rpc-error -32602 "Parameters must be an object."))
         (define result
           (cond
             [(equal? method "ping") (hasheq)]
             [(equal? method "initialize")
              (unless (eq? phase 'new) (rpc-error -32600 "Session already initialized."))
              (unless (and (string? (hash-ref params 'protocolVersion #f))
                           (hash? (hash-ref params 'capabilities #f))
                           (hash? (hash-ref params 'clientInfo #f)))
                (rpc-error -32602 "Invalid initialization parameters."))
              (set! phase 'initializing)
              (hasheq 'protocolVersion protocol-version 'capabilities (hasheq 'tools (hasheq 'listChanged #f))
                      'serverInfo (hasheq 'name name 'version version))]
             [(not (eq? phase 'ready)) (rpc-error -32600 "Initialize the session first.")]
             [(equal? method "tools/list")
              (when (hash-has-key? params 'cursor) (rpc-error -32602 "This tool list has no pagination cursor."))
              (hasheq 'tools (tool-list))]
             [(equal? method "tools/call") (call-tool (hash-ref params 'name #f) (hash-ref params 'arguments (hasheq)))]
             [else (rpc-error -32601 "Method not found.")]))
         (hasheq 'jsonrpc "2.0" 'id id 'result result)])))
  (let loop ()
    ;; Bounded line reads prevent unbounded allocations before JSON validation.
    (define line (read-bytes-line (make-limited-input-port input (add1 max-frame-bytes) #f) 'linefeed))
    (unless (eof-object? line)
      (cond
        [(> (bytes-length line) max-frame-bytes)
         (emit (failure 'null -32600 "Message exceeds the local 8 MiB limit; reconnect."))]
        [else
         (define reply
           (with-handlers ([exn:fail? (lambda (_) (failure 'null -32700 "Invalid JSON."))])
             (dispatch (parse-json line))))
         (when reply (emit reply))
         (loop)]))))
