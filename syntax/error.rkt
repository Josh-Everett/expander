#lang racket/base
(require "../common/contract.rkt"
         "syntax.rkt"
         "scope.rkt"
         "taint.rkt")

(provide (struct-out exn:fail:syntax)
         make-exn:fail:syntax
         
         raise-syntax-error)

(struct exn:fail:syntax exn:fail (exprs)
        #:extra-constructor-name make-exn:fail:syntax
        #:transparent
        #:property prop:exn:srclocs (lambda (e) (exn:fail:syntax-exprs e))
        #:guard (lambda (str cm exprs info)
                  (unless (and (list? exprs)
                               (andmap syntax? exprs))
                    (raise-argument-error 'exn:fail:syntax "(listof syntax?)" exprs))
                  (values str cm exprs)))

(define (raise-syntax-error given-name message
                            [expr #f] [sub-expr #f]
                            [extra-sources null]
                            [message-suffix ""])
  (unless (or (not given-name) (symbol? given-name))
    (raise-argument-error 'raise-syntax-error "(or/c symbol? #f)" given-name))
  (check 'raise-syntax-error string? message)
  (unless (and (list? extra-sources)
               (andmap syntax? extra-sources))
    (raise-argument-error 'raise-syntax-error "(listof syntax?)" extra-sources))
  (check 'raise-syntax-error string? message-suffix)
  (define name
    (format "~a" (or given-name
                     (extract-form-name expr)
                     '?)))
  (define at-message
    (or (and sub-expr
             (error-print-source-location)
             (format "\n  at: ~.s" (syntax->datum (datum->syntax #f sub-expr))))
        ""))
  (define in-message
    (or (and expr
             (error-print-source-location)
             (format "\n  in: ~.s" (syntax->datum (datum->syntax #f expr))))
        ""))
  (define src-loc-str
    (or (extract-source-location sub-expr)
        (extract-source-location expr)
        ""))
  (raise (exn:fail:syntax
          (string-append src-loc-str
                         name ": "
                         message
                         at-message
                         in-message
                         message-suffix)
          (current-continuation-marks)
          (map syntax-taint
               (if (or sub-expr expr)
                   (cons (datum->syntax #f (or sub-expr expr))
                         extra-sources)
                   extra-sources)))))

(define (extract-form-name s)
  (cond
   [(syntax? s)
    (define e (syntax-e s))
    (cond
     [(symbol? e) e]
     [(and (pair? e)
           (identifier? (car e)))
      (syntax-e (car e))]
     [else #f])]
   [else #f]))

(define (extract-source-location s)
  (and (syntax? s)
       (syntax-srcloc s)
       (let ([str (srcloc->string (syntax-srcloc s))])
         (and str
              (string-append str ": ")))))

