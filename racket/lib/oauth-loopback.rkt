#lang racket/base

(require net/uri-codec racket/list racket/port racket/tcp "deadline.rkt")
(provide receive-authorization-code parse-callback (struct-out exn:fail:oauth-callback))

(struct exn:fail:oauth-callback exn:fail () #:transparent)
(define (callback-error message)
  (raise (exn:fail:oauth-callback message (current-continuation-marks))))

;; Return a code, 'denied, or #f. Never return/echo untrusted error descriptions.
(define (parse-callback target expected-state #:path [path "/callback"])
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define parts (regexp-match #px"^([^?# ]+)(?:\\?([^# ]*))?$" target))
    (and parts (equal? (cadr parts) path)
         (let* ([query (form-urlencoded->alist (or (caddr parts) ""))]
                [values-for (lambda (key) (map cdr (filter (lambda (entry) (eq? (car entry) key)) query)))]
                [states (values-for 'state)] [codes (values-for 'code)] [errors (values-for 'error)])
           (and (equal? states (list expected-state))
                (cond [(and (null? errors) (= (length codes) 1) (not (equal? (car codes) ""))) (car codes)]
                      [(and (null? codes) (= (length errors) 1)) 'denied]
                      [else #f]))))))

(define (read-target input)
  (define bounded (make-limited-input-port input 8193 #f))
  (define first (read-bytes-line bounded 'return-linefeed))
  (define matched (and (bytes? first) (regexp-match #px#"^GET ([^ ]+) HTTP/1\\.[01]$" first)))
  (and matched
       (let loop ([used (+ (bytes-length first) 2)])
         (define line (read-bytes-line bounded 'return-linefeed))
         (and (bytes? line) (<= (+ used (bytes-length line) 2) 8192)
              (if (zero? (bytes-length line)) (bytes->string/latin-1 (cadr matched))
                  (loop (+ used (bytes-length line) 2)))))))

(define (respond output accepted?)
  (define body (if accepted? "Authorization received. Check the terminal for completion."
                  "Invalid or denied authorization callback. Check the terminal."))
  (fprintf output "HTTP/1.1 ~a\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: ~a\r\n\r\n~a"
           (if accepted? "200 OK" "400 Bad Request") (string-length body) body)
  (flush-output output))

(define (receive-authorization-code state #:port [port 8765] #:path [path "/callback"]
                                    #:timeout [timeout 300] #:on-listening [on-listening void])
  (call-with-deadline
   timeout
   (lambda ()
     (define listener (tcp-listen port 4 #t "127.0.0.1"))
     (dynamic-wind
       void
       (lambda ()
         (define addresses (call-with-values (lambda () (tcp-addresses listener #t)) list))
         (on-listening (cadr addresses))
         (let loop ()
           (sync listener)
           (define result
             (call-with-deadline
              5
              (lambda ()
                ;; Ports belong to this connection's custodian, including on
                ;; malformed, disconnected, or deliberately stalled requests.
                (define-values (input output) (tcp-accept listener))
                (define code
                  (with-handlers ([exn:fail? (lambda (_) #f)])
                    (define target (read-target input))
                    (and target (parse-callback target state #:path path))))
                ;; A browser disconnect after a valid callback must not discard
                ;; the authorization code or leave a denied login waiting.
                (with-handlers ([exn:fail? void]) (respond output (string? code)))
                code)
              (lambda () #f)))
           (cond [(eq? result 'denied) (callback-error "Authorization was denied. Run login again when ready.")]
                 [(string? result) result]
                 [else (loop)])))
       (lambda () (tcp-close listener))))
   (lambda () (callback-error "Login timed out; run login again."))))
