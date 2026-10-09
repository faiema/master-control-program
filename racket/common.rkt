#lang racket/base
;; SPDX-License-Identifier: AGPL-3.0-only

(require "lib/json.rkt" "lib/deadline.rkt")
(provide (struct-out exn:fail:bridge) bridge-error call/bounded parse-json)

;; Only these deliberately authored messages may cross the MCP boundary.
(struct exn:fail:bridge exn:fail () #:transparent)
(define (bridge-error message)
  (raise (exn:fail:bridge message (current-continuation-marks))))

(define (call/bounded seconds thunk timeout-message)
  (call-with-deadline seconds thunk (lambda () (bridge-error timeout-message))))
