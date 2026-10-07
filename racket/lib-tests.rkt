#lang racket/base

(require json rackunit racket/list racket/port "lib/json.rkt" "lib/mcp-stdio.rkt")

(define initialize
  (hasheq 'jsonrpc "2.0" 'id 1 'method "initialize"
          'params (hasheq 'protocolVersion "2025-11-25" 'capabilities (hasheq)
                          'clientInfo (hasheq 'name "independent-test" 'version "1"))))
(define initialized (hasheq 'jsonrpc "2.0" 'method "notifications/initialized"))
(define (run messages)
  (define output (open-output-string))
  (serve-tools
   (lambda () '())
   (lambda (name args) (hasheq 'content (list (hasheq 'type "text" 'text (hash-ref args 'text)))))
   #:name "unrelated-project" #:version "2"
   #:input (open-input-string
            (if (string? messages) messages
                (apply string-append (map (lambda (m) (string-append (jsexpr->string m) "\n")) messages))))
   #:output output)
  (for/list ([line (in-lines (open-input-string (get-output-string output)))]) (parse-json line)))

(module+ test
  (test-case "tools transport works without importing X application modules"
    (define responses
      (run (list initialize initialized
                 (hasheq 'jsonrpc "2.0" 'id 2 'method "tools/list")
                 (hasheq 'jsonrpc "2.0" 'id 3 'method "tools/call"
                         'params (hasheq 'name "echo" 'arguments (hasheq 'text "one\ntwo")))
                 (hasheq 'jsonrpc "2.0" 'id 4 'method "ping"))))
    (check-equal? (length responses) 4)
    (check-equal? (hash-ref (hash-ref (hash-ref (car responses) 'result) 'serverInfo) 'name) "unrelated-project")
    (check-equal? (hash-ref (car (hash-ref (hash-ref (caddr responses) 'result) 'content)) 'text) "one\ntwo"))

  (test-case "malformed RPC messages receive valid error envelopes"
    (define responses (run "bad\n[]\n{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"ping\"}\n"))
    (check-equal? (map (lambda (r) (hash-ref (hash-ref r 'error) 'code)) responses) '(-32700 -32600 -32600))
    (check-true (andmap (lambda (r) (eq? (hash-ref r 'id) 'null)) responses)))

  (test-case "oversized frame terminates session without processing trailing data"
    (define responses (run (string-append (make-string (add1 (* 8 1024 1024)) #\x) "\n" (jsexpr->string initialize) "\n")))
    (check-equal? (length responses) 1)
    (check-equal? (hash-ref (hash-ref (car responses) 'error) 'code) -32600))

  (test-case "strict JSON parsing refuses trailing values"
    (check-equal? (parse-json "{} \n\t") (hasheq))
    (check-exn exn:fail? (lambda () (parse-json "{} {}")))
    (check-exn exn:fail? (lambda () (parse-json "")))))
