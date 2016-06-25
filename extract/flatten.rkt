#lang racket/base
(require "../common/set.rkt"
         "../run/status.rkt"
         "link.rkt"
         "linklet-info.rkt"
         "linklet.rkt"
         "symbol.rkt"
         (prefix-in bootstrap: "../run/linklet.rkt"))

(provide flatten!)

;; Represents a variable that is exported by a used linklet:
(struct variable (link   ; link
                  name)  ; symbol
        #:prefab)

(define (flatten! start-link
                  #:linklets linklets
                  #:linklets-in-order linklets-in-order
                  #:needed needed)
  (log-status "Flattening to a single linklet...")
  (define needed-linklets-in-order
    (for/list ([lnk (in-list (unbox linklets-in-order))]
               #:when (hash-ref needed lnk #f))
      lnk))
  
  (define variable-names (pick-variable-names
                          #:linklets linklets
                          #:needed-linklets-in-order needed-linklets-in-order))
  
  (define runtime-imports
    (for*/fold ([ht #hash()]) ([var (in-hash-keys variable-names)]
                               #:when (symbol? (link-name (variable-link var))))
      (hash-update ht (variable-link var) (lambda (l) (cons (variable-name var) l)) null)))
  
  `(linklet
    ;; imports
    ,(for/list ([(i-lnk names) (in-hash runtime-imports)])
       `[,@(for/list ([name (in-list names)])
             `(,name ,(hash-ref variable-names (variable i-lnk name))))])
    ;; exports
    ()
    ;; body
    ,@(apply
       append
       (for/list ([lnk (in-list (reverse needed-linklets-in-order))])
         (body-with-substituted-variable-names lnk
                                               (hash-ref linklets lnk)
                                               variable-names)))))

(define (pick-variable-names #:linklets linklets
                             #:needed-linklets-in-order needed-linklets-in-order)
  ;; We need to pick a name for each needed linklet's definitions plus
  ;; each primitive import. Start by checking which names are
  ;; currently used.
  (define variable-locals (make-hash)) ; variable -> set-of-symbol
  (define otherwise-used-symbols (seteq))
  
  (for ([lnk (in-list needed-linklets-in-order)])
    (define li (hash-ref linklets lnk))
    (define linklet (linklet-info-linklet li))
    (define importss+localss
      (skip-abi-imports (bootstrap:s-expr-linklet-importss+localss linklet)))
    (define exports+locals
      (bootstrap:s-expr-linklet-exports+locals linklet))
    (define all-mentioned-symbols
      (all-used-symbols (bootstrap:s-expr-linklet-body linklet)))
    
    (define (record! lnk external+local)
      (hash-update! variable-locals
                    (variable lnk (car external+local))
                    (lambda (s) (set-add s (cdr external+local)))
                    (seteq)))
    
    (for ([imports+locals (in-list importss+localss)]
          [i-lnk (in-list (linklet-info-imports li))])
      (for ([import+local (in-list imports+locals)])
        (record! i-lnk import+local)))
    
    (for ([export+local (in-list exports+locals)])
      (record! lnk export+local))
                   
    (define all-import-export-locals
      (list->set
       (apply append
              (map cdr exports+locals)
              (for/list ([imports+locals (in-list importss+localss)])
                (map cdr imports+locals)))))
    (set! otherwise-used-symbols
          (set-union otherwise-used-symbols
                     (set-subtract all-mentioned-symbols
                                   all-import-export-locals))))
  
  ;; For each variable name, use the obvious symbol if it won't
  ;; collide, otherwise pick a symbol that's not mentioned anywhere.
  ;; (If a variable was given an alternative name for all imports or
  ;; exports, probably using the obvious symbol would cause a
  ;; collision.)
  (for/hash ([(var current-syms) (in-hash variable-locals)])
    (define sym
      (cond
       [(and (= 1 (set-count current-syms))
             (not (set-member? otherwise-used-symbols (set-first current-syms))))
        (set-first current-syms)]
       [(and (set-member? current-syms (variable-name var))
             (not (set-member? otherwise-used-symbols (variable-name var))))
        (variable-name var)]
       [else (distinct-symbol (variable-name var) otherwise-used-symbols)]))
    (set! otherwise-used-symbols (set-add otherwise-used-symbols sym))
    (values var sym)))

(define (body-with-substituted-variable-names lnk li variable-names)
  (define linklet (linklet-info-linklet li))
  (define importss+localss
    (skip-abi-imports (bootstrap:s-expr-linklet-importss+localss linklet)))
  (define exports+locals
    (bootstrap:s-expr-linklet-exports+locals linklet))

  (define substs (make-hasheq))
  
  (define (add-subst! lnk external+local)
    (hash-set! substs
               (cdr external+local)
               (hash-ref variable-names (variable lnk (car external+local)))))
  
  (for ([imports+locals (in-list importss+localss)]
        [i-lnk (in-list (linklet-info-imports li))])
    (for ([import+local (in-list imports+locals)])
      (add-subst! i-lnk import+local)))
  
  (for ([export+local (in-list exports+locals)])
    (add-subst! lnk export+local))
  
  (define orig-s (bootstrap:s-expr-linklet-body (linklet-info-linklet li)))
  
  (substitute-symbols orig-s substs))
