#lang racket/base

;; A built-in symbol is one that the compiler must avoid using for a
;; binding. Built-in symbols include the names of run-time primitives
;; and identifiers reserved by the compiler itself (see
;; "reserved-symbol.rkt")

(provide register-built-in-symbol!
         built-in-symbol?
         make-built-in-symbol!)

(define built-in-symbols (make-hasheq))

(define (register-built-in-symbol! s)
  (hash-set! built-in-symbols s #t))

(define (built-in-symbol? s)
  (hash-ref built-in-symbols s #f))

(define (make-built-in-symbol! s)
  ;; Make a symbol that is a little more obscure than just `s`
  (define built-in-s (string->symbol (format ".~s" s)))
  (register-built-in-symbol! built-in-s)
  built-in-s)

;; ----------------------------------------

;; Primitive expression forms
(for-each register-built-in-symbol!
          '(lambda case-lambda
            if begin begin0
            let-values letrec-values
            set! quote
            with-continuation-mark
            #%variable-reference))

;; Temporary linklet glue
(for-each register-built-in-symbol!
          '(check-not-undefined 
            instance-variable-box
            variable-reference
            variable-reference?
            variable-reference->instance
            variable-reference-constant?))
