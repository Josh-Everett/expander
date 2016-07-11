#lang racket/base
(require (for-syntax racket/base)
         "../common/set.rkt"
         "../compile/serialize-property.rkt"
         "../compile/serialize-state.rkt"
         "syntax.rkt")

;; A binding table within a scope maps symbol plus scope set
;; combinations (where the scope binding the binding table is always
;; included in the set).
;;
;; A binding table is one of
;;
;;  - hash of sym -> scope-set -> binding
;;
;;  - (table-with-bulk-bindings hash[as above] list-of-bulk-binding-at)
;;
;; In the latter case, the symbol-keyed hash table overrides bindings
;; supplied (for the same scope sets) in the bulk bindings.

(provide empty-binding-table
         binding-table-add
         binding-table-add-bulk
         binding-table-empty?
         
         in-binding-table
         
         prop:bulk-binding
         (struct-out bulk-binding-class)
         
         binding-table-prune-to-reachable
         binding-table-register-reachable
         
         deserialize-table-with-bulk-bindings
         deserialize-bulk-binding-at)

(define empty-binding-table #hasheq())

(struct table-with-bulk-bindings (syms bulk-bindings)
        #:property prop:serialize
        (lambda (twbb ser state)
          `(deserialize-table-with-bulk-bindings
            ,(ser (table-with-bulk-bindings-syms twbb))
            ,(ser (table-with-bulk-bindings-bulk-bindings twbb)))))

(define (deserialize-table-with-bulk-bindings syms bulk-bindings)
  (table-with-bulk-bindings syms bulk-bindings))

;; ----------------------------------------

(struct bulk-binding-at (scopes ; scope set
                         bulk)  ; bulk-binding
        #:property prop:serialize
        (lambda (bba ser state)
          ;; Data that is interpreted by the deserializer:
          `(deserialize-bulk-binding-at
            ,(ser (bulk-binding-at-scopes bba))
            ,(ser (bulk-binding-at-bulk bba))))
        #:property prop:reach-scopes
        (lambda (sms reach)
          ;; bulk bindings are pruned dependong on whether all scopes
          ;; in `scopes` are reachable, and we shouldn't get here
          ;; when looking for scopes
          (error "shouldn't get here")))

(define (deserialize-bulk-binding-at scopes bulk)
  (bulk-binding-at scopes bulk))

;; Bulk bindings are represented by a property, so that the implementation
;; can be separate and manage serialization:
(define-values (prop:bulk-binding bulk-binding? bulk-binding-ref)
  (make-struct-type-property 'bulk-binding))

;; Value of `prop:bulk-binding`
(struct bulk-binding-class (get-symbols ; bulk-binding list-of-shift -> sym -> binding-info
                            create))    ; bul-binding -> binding-info sym -> binding
(define (bulk-binding-symbols b s extra-shifts)
  ;; Providing the identifier `s` supports its shifts
  ((bulk-binding-class-get-symbols (bulk-binding-ref b))
   b 
   (append extra-shifts (if s (syntax-mpi-shifts s) null))))
(define (bulk-binding-create b)
  (bulk-binding-class-create (bulk-binding-ref b)))

;; ----------------------------------------

(define (binding-table-empty? bt)
  (and (hash? bt) (zero? (hash-count bt))))

;; Adding a binding for a single symbol
(define (binding-table-add bt scopes sym binding)
  (cond
   [(hash? bt)
    (hash-set bt sym (hash-set (hash-ref bt sym #hash()) scopes binding))]
   [else
    (struct-copy table-with-bulk-bindings bt 
                 [syms (binding-table-add (table-with-bulk-bindings-syms bt)
                                          scopes
                                          sym
                                          binding)])]))

;; Adding a binding for a computed-on-demand set of symbols
(define (binding-table-add-bulk bt scopes bulk)
  (cond
   [(table-with-bulk-bindings? bt)
    (table-with-bulk-bindings (remove-matching-bindings (table-with-bulk-bindings-syms bt)
                                                        scopes
                                                        bulk)
                              (cons (bulk-binding-at scopes bulk)
                                    (table-with-bulk-bindings-bulk-bindings bt)))]
   [else
    (binding-table-add-bulk (table-with-bulk-bindings bt null) scopes bulk)]))

;; The bindings of `bulk at `scopes` should shadow any existing
;; mappings in `sym-bindings`
(define (remove-matching-bindings syms scopes bulk)
  (define bulk-symbols (bulk-binding-symbols bulk #f null))
  (cond
   [((hash-count syms) . < . (hash-count bulk-symbols))
    ;; Faster to consider each sym in `sym-binding`
    (for/fold ([syms syms]) ([(sym sym-bindings) (in-immutable-hash syms)])
      (if (hash-ref bulk-symbols sym #f)
          (remove-matching-binding syms sym sym-bindings scopes)
          syms))]
   [else
    ;; Faster to consider each sym in `bulk-symbols`
    (for/fold ([syms syms]) ([sym (in-immutable-hash-keys bulk-symbols)])
      (define sym-bindings (hash-ref syms sym #f))
      (if sym-bindings
          (remove-matching-binding syms sym sym-bindings scopes)
          syms))]))

;; Update an individual symbol's bindings to remove a mapping
;; for a given set of scopes
(define (remove-matching-binding syms sym sym-bindings scopes)
  (hash-set syms sym (hash-remove sym-bindings scopes)))

;; ----------------------------------------

;; Iterate through all scope+binding combinations for a given symbol;
;; the syntax object and extra shifts expressions may be used for
;; loading bulk bindings.
(define-sequence-syntax in-binding-table
  (lambda () #'do-not-use-in-binding-as-an-expression)
  (lambda (stx)
    (syntax-case stx ()
      [[(scopes-id binding-id) (_ sym table-expr s-expr extra-shifts-expr)]
       (identifier? #'sym)
       #'[(scopes-id binding-id)
          (:do-in
           ([(ht bulk-bindings)
             (let ([table table-expr])
               (if (hash? table)
                   (values (hash-ref table sym #hash()) null)
                   (values (hash-ref (table-with-bulk-bindings-syms table) sym #hash())
                           (table-with-bulk-bindings-bulk-bindings table))))]
            [(s) s-expr]
            [(extra-shifts) extra-shifts-expr])
           #t
           ;; The current index is either a number index for a hash table
           ;; (extracted from the symbol-keyed hash table) or it is a pair
           ;; for walking down the list of bulk bindings
           ([i (or (hash-iterate-first ht)
                   bulk-bindings)]
            [already-covered-scopes #hasheq()]) ; scope sets with bindings to overriding bulk bindings
           ;; We're done when we've moved on to the bulk-binding part
           ;; and none are left:
           (not (null? i))
           ;; At each step, extract the current scope set and binding;
           ;; either can be #f, in which case the consumer of the
           ;; sequence should move on the the next result
           ([(scopes-id) (cond
                          [(pair? i)
                           (define scs (bulk-binding-at-scopes (car i)))
                           (and (not (set-member? already-covered-scopes scs))
                                scs)]
                          [else (hash-iterate-key ht i)])]
            [(binding-id) (cond
                           [(pair? i)
                            (define bulk (bulk-binding-at-bulk (car i)))
                            (define b-info (hash-ref (bulk-binding-symbols bulk s extra-shifts) sym #f))
                            (and b-info
                                 ((bulk-binding-create bulk) bulk b-info sym))]
                           [else (hash-iterate-value ht i)])])
           #t
           #t
           [;; Next value for the index `i`:
            (cond
             [(pair? i) (cdr i)]
             [else (or (hash-iterate-next ht i)
                       bulk-bindings)])
            ;; Next value for `already-covered-scopes`; add the just-reported scope set
            ;; if we'll continue to explore bulk bindings
            (cond
             [(and (pair? bulk-bindings)
                   scopes-id
                   binding-id
                   (or (not (pair? i)) (not (null? (cdr i)))))
              (set-add already-covered-scopes scopes-id)]
             [else already-covered-scopes])])]])))

;; ----------------------------------------
;; Pruning functions are called by scope serialization

(define (binding-table-prune-to-reachable bt state)
  (or (hash-ref (serialize-state-bindings-intern state) bt #f)
      (let ([reachable-scopes (serialize-state-reachable-scopes state)])
        (define new-syms
          (for*/hasheq ([(sym bindings-for-sym) (in-immutable-hash
                                                 (if (hash? bt)
                                                     bt
                                                     (table-with-bulk-bindings-syms bt)))]
                        [new-bindings-for-sym
                         (in-value
                          (for/hash ([(scopes binding) (in-immutable-hash bindings-for-sym)]
                                     #:when (subset? scopes reachable-scopes))
                            (values (intern-scopes scopes state) binding)))]
                        #:when (positive? (hash-count new-bindings-for-sym)))
            (values sym new-bindings-for-sym)))
        (define new-bulk-bindings
          (if (hash? bt)
              null
              (for/list ([bba (in-list (table-with-bulk-bindings-bulk-bindings bt))]
                         #:when (subset? (bulk-binding-at-scopes bba) reachable-scopes))
                (struct-copy bulk-binding-at bba
                             [scopes (intern-scopes (bulk-binding-at-scopes bba) state)]))))
        (define new-bt
          (if (pair? new-bulk-bindings)
              (table-with-bulk-bindings new-syms new-bulk-bindings)
              new-syms))
        (hash-set! (serialize-state-bulk-bindings-intern state) bt new-bt)
        new-bt)))

(define (binding-table-register-reachable bt reachable-scopes reach register-trigger)
  (for* ([(sym bindings-for-sym) (in-immutable-hash (if (hash? bt)
                                                        bt
                                                        (table-with-bulk-bindings-syms bt)))]
         [(scopes binding) (in-immutable-hash bindings-for-sym)])
    (scopes-register-reachable scopes binding reachable-scopes reach register-trigger)))

(define (scopes-register-reachable scopes binding reachable-scopes reach register-trigger)
  (define v (and (binding-reach-scopes? binding)
                 ((binding-reach-scopes-ref binding) binding)))
  (when v
    (cond
     [(subset? scopes reachable-scopes)
      (reach v)]
     [else
      (for ([sc (in-set scopes)]
            #:unless (set-member? reachable-scopes sc))
        (register-trigger sc v))])))
