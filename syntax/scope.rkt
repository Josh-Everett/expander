#lang racket/base
(require "../common/set.rkt"
         "../compile/serialize-property.rkt"
         "../compile/serialize-state.rkt"
         "../common/memo.rkt"
         "syntax.rkt"
         "binding-table.rkt"
         "taint.rkt"
         "tamper.rkt"
         "../common/phase.rkt"
         "fallback.rkt"
         "datum-map.rkt"
         "cache.rkt")

(provide new-scope
         new-multi-scope
         add-scope
         add-scopes
         remove-scope
         remove-scopes
         flip-scope
         flip-scopes
         push-scope
         
         syntax-e ; handles lazy scope and taint propagation
         syntax-e/no-taint ; like `syntax-e`, but doesn't explode a dye pack
         
         syntax-scope-set
         syntax-any-scopes?
         syntax-any-macro-scopes?
         
         syntax-shift-phase-level

         syntax-swap-scopes

         add-binding-in-scopes!
         add-bulk-binding-in-scopes!

         resolve

         bound-identifier=?

         top-level-common-scope

         deserialize-scope
         deserialize-scope-fill!
         deserialize-representative-scope
         deserialize-representative-scope-fill!
         deserialize-multi-scope
         deserialize-shifted-multi-scope
         
         generalize-scope
         
         scope?
         scope<?
         shifted-multi-scope?
         shifted-multi-scope<?)

(module+ for-debug
  (provide (struct-out scope)
           (struct-out multi-scope)
           (struct-out representative-scope)
           scope-set-at-fallback))

;; A scope represents a distinct "dimension" of binding. We can attach
;; the bindings for a set of scopes to an arbitrary scope in the set;
;; we pick the most recently allocated scope to make a binding search
;; faster and to improve GC, since non-nested binding contexts will
;; generally not share a most-recent scope.

(struct scope (id             ; internal scope identity; used for sorting
               kind           ; debug info
               [binding-table #:mutable]) ; see "binding-table.rkt"
        ;; Custom printer:
        #:property prop:custom-write
        (lambda (sc port mode)
          (write-string "#<scope:" port)
          (display (scope-id sc) port)
          (write-string ":" port)
          (display (scope-kind sc) port)
          (write-string ">" port))
        #:property prop:serialize
        (lambda (s ser state)
          ;; The result here looks like an expression, but it's
          ;; treated as data and interpreted for deserialization
          (unless (set-member? (serialize-state-reachable-scopes state) s)
            (error "internal error: found supposedly unreachable scope"))
          (if (eq? s top-level-common-scope)
              `(deserialize-scope)
              `(deserialize-scope . ,(scope-kind s))))
        #:property prop:serialize-fill!
        (lambda (s ser state)
          ;; Like the main serialization result, this result
          ;; is data that is interpreted
          (if (binding-table-empty? (scope-binding-table s))
              #f
              `(deserialize-scope-fill!
                ,(ser (binding-table-prune-to-reachable (scope-binding-table s) state)))))
        #:property prop:reach-scopes
        (lambda (s reach)
          ;; the `bindings` field is handled via `prop:scope-with-bindings`
          (void))
        #:property prop:scope-with-bindings
        (lambda (s reachable-scopes reach register-trigger)
          (binding-table-register-reachable (scope-binding-table s)
                                            reachable-scopes
                                            reach
                                            register-trigger)))

(define deserialize-scope
  (case-lambda
    [() top-level-common-scope]
    [(kind)
     (scope (new-deserialize-scope-id!) kind empty-binding-table)]))

(define (deserialize-scope-fill! s bt)
  (set-scope-binding-table! s bt))

;; A "multi-scope" represents a group of scopes, each of which exists
;; only at a specific phase, and each in a distinct phase. This
;; infinite group of scopes is realized on demand. A multi-scope is
;; used to represent the inside of a module, where bindings in
;; different phases are distinguished by the different scopes within
;; the module's multi-scope.
;;
;; To compute a syntax's set of scopes at a given phase, the
;; phase-specific representative of the multi scope is combined with
;; the phase-independent scopes. Since a multi-scope corresponds to
;; a module, the number of multi-scopes in a syntax is expected to
;; be small.
(struct multi-scope (id       ; identity
                     name     ; for debugging
                     scopes   ; phase -> representative-scope
                     shifted  ; interned shifted-multi-scopes for non-label phases
                     label-shifted) ; interned shifted-multi-scopes for label phases
        #:property prop:serialize
        (lambda (ms ser state)
          ;; Data that is interpreted by the deserializer:
          `(deserialize-multi-scope
            ,(ser (multi-scope-name ms))
            ,(ser (multi-scope-scopes ms))))
        #:property prop:reach-scopes
        (lambda (ms reach)
          (reach (multi-scope-scopes ms))))

(define (deserialize-multi-scope name scopes)
  (multi-scope (new-deserialize-scope-id!) name scopes (make-hasheqv) (make-hash)))

(struct representative-scope scope (owner   ; a multi-scope for which this one is a phase-specific identity
                                    phase)  ; phase of this scope
        #:mutable ; to support serialization
        #:property prop:custom-write
        (lambda (sc port mode)
          (write-string "#<scope:" port)
          (display (scope-id sc) port)
          (when (representative-scope-owner sc)
            (write-string "=" port)
            (display (multi-scope-id (representative-scope-owner sc)) port))
          (write-string "@" port)
          (display (representative-scope-phase sc) port)
          (write-string ">" port))
        #:property prop:serialize
        (lambda (s ser state)
          ;; Data that is interpreted by the deserializer:
          `(deserialize-representative-scope
            ,(ser (scope-kind s))
            ,(ser (representative-scope-phase s))))
        #:property prop:serialize-fill!
        (lambda (s ser state)
          `(deserialize-representative-scope-fill!
            ,(ser (binding-table-prune-to-reachable (scope-binding-table s) state))
            ,(ser (representative-scope-owner s))))
        #:property prop:reach-scopes
        (lambda (s reach)
          ;; the inherited `bindings` field is handled via `prop:scope-with-bindings`
          (reach (representative-scope-owner s))))

(define (deserialize-representative-scope kind phase)
  (representative-scope (new-deserialize-scope-id!) kind #f #f phase))

(define (deserialize-representative-scope-fill! s bt owner)
  (deserialize-scope-fill! s bt)
  (set-representative-scope-owner! s owner))

(struct shifted-multi-scope (phase        ; non-label phase shift or shifted-to-label-phase
                             multi-scope) ; a multi-scope
        #:property prop:custom-write
        (lambda (sms port mode)
          (write-string "#<scope:" port)
          (display (multi-scope-id (shifted-multi-scope-multi-scope sms)) port)
          (write-string "@" port)
          (display (shifted-multi-scope-phase sms) port)
          (write-string ">" port))
        #:property prop:serialize
        (lambda (sms ser state)
          ;; Data that is interpreted by the deserializer:
          `(deserialize-shifted-multi-scope
            ,(ser (shifted-multi-scope-phase sms))
            ,(ser (shifted-multi-scope-multi-scope sms))))
        #:property prop:reach-scopes
        (lambda (sms reach)
          (reach (shifted-multi-scope-multi-scope sms))))

(define (deserialize-shifted-multi-scope phase multi-scope)
  (intern-shifted-multi-scope phase multi-scope))

(define (intern-shifted-multi-scope phase multi-scope)
  (cond
   [(phase? phase)
    ;; `eqv?`-hashed by phase
    (or (hash-ref (multi-scope-shifted multi-scope) phase #f)
        (let ([sms (shifted-multi-scope phase multi-scope)])
          (hash-set! (multi-scope-shifted multi-scope) phase sms)
          sms))]
   [else
    ;; `equal?`-hashed by shifted-to-label-phase
    (or (hash-ref (multi-scope-label-shifted multi-scope) phase #f)
        (let ([sms (shifted-multi-scope phase multi-scope)])
          (hash-set! (multi-scope-label-shifted multi-scope) phase sms)
          sms))]))

;; A `shifted-to-label-phase` record in the `phase` field of a
;; `shifted-multi-scope` makes the shift reversible; when we're
;; looking up the label phase, then use the representative scope at
;; phase `from`; when we're looking up a non-label phase, there is no
;; corresponding representative scope
(struct shifted-to-label-phase (from) #:prefab)

;; Each new scope increments the counter, so we can check whether one
;; scope is newer than another.
(define id-counter 0)
(define (new-scope-id!)
  (set! id-counter (add1 id-counter))
  id-counter)

(define (new-deserialize-scope-id!)
  ;; negative scope ensures that new scopes are recognized as such by
  ;; having a larger id
  (- (new-scope-id!)))

;; A shared "outside-edge" scope for all top-level contexts
(define top-level-common-scope (scope 0 'module empty-binding-table))

(define (new-scope kind)
  (scope (new-scope-id!) kind empty-binding-table))

(define (new-multi-scope [name #f])
  (intern-shifted-multi-scope 0 (multi-scope (new-scope-id!) name (make-hasheqv) (make-hasheqv) (make-hash))))

(define (multi-scope-to-scope-at-phase ms phase)
  ;; Get the identity of `ms` at phase`
  (or (hash-ref (multi-scope-scopes ms) phase #f)
      (let ([s (representative-scope (new-scope-id!) 'module
                                     empty-binding-table
                                     ms phase)])
        (hash-set! (multi-scope-scopes ms) phase s)
        s)))

(define (scope>? sc1 sc2)
  ((scope-id sc1) . > . (scope-id sc2)))
(define (scope<? sc1 sc2)
  ((scope-id sc1) . < . (scope-id sc2)))

(define (shifted-multi-scope<? sms1 sms2)
  (define ms1 (shifted-multi-scope-multi-scope sms1))
  (define ms2 (shifted-multi-scope-multi-scope sms2))
  (if (eq? ms1 ms2)
      (let ([p1 (shifted-multi-scope-phase sms1)]
            [p2 (shifted-multi-scope-phase sms2)])
        (cond
         [(shifted-to-label-phase? p1)
          (cond
           [(shifted-to-label-phase? p2)
            (phase<? (shifted-to-label-phase-from p1) (shifted-to-label-phase-from p2))]
           [else #f])]
         [(shifted-to-label-phase? p2) #t]
         [else (phase<? p1 p2)]))
      ((multi-scope-id ms1) . < . (multi-scope-id ms2))))

;; Adding, removing, or flipping a scope is propagated
;; lazily to subforms
(define (apply-scope s sc op prop-op)
  (if (shifted-multi-scope? sc)
      (struct-copy syntax s
                   [shifted-multi-scopes (fallback-update-first (syntax-shifted-multi-scopes s)
                                                                (lambda (smss)
                                                                  (op (fallback-first smss) sc)))]
                   [scope-propagations (and (datum-has-elements? (syntax-content s))
                                            (prop-op (syntax-scope-propagations s)
                                                     sc
                                                     (syntax-scopes s)
                                                     (syntax-shifted-multi-scopes s)))])
      (struct-copy syntax s
                   [scopes (op (syntax-scopes s) sc)]
                   [scope-propagations (and (datum-has-elements? (syntax-content s))
                                            (prop-op (syntax-scope-propagations s)
                                                     sc
                                                     (syntax-scopes s)
                                                     (syntax-shifted-multi-scopes s)))])))

(define (syntax-e/no-taint s)
  (propagate-taint! s)
  (define prop (syntax-scope-propagations s))
  (if prop
      (let ([new-content
             (non-syntax-map (syntax-content s)
                             (lambda (tail? x) x)
                             (lambda (sub-s)
                               (struct-copy syntax sub-s
                                            [scopes (propagation-apply
                                                     prop
                                                     (syntax-scopes sub-s)
                                                     s)]
                                            [shifted-multi-scopes (propagation-apply-shifted
                                                                   prop
                                                                   (syntax-shifted-multi-scopes sub-s)
                                                                   s)]
                                            [scope-propagations (propagation-merge
                                                                 prop
                                                                 (syntax-scope-propagations sub-s)
                                                                 (syntax-scopes sub-s)
                                                                 (syntax-shifted-multi-scopes sub-s))])))])
        (set-syntax-content! s new-content)
        (set-syntax-scope-propagations! s #f)
        new-content)
      (syntax-content s)))

(define (syntax-e s)
  (define content (syntax-e/no-taint s))
  (cond
   [(not (tamper-armed? (syntax-tamper s))) content]
   [(datum-has-elements? content) (taint-content content)]
   [else content]))

;; When a representative-scope is manipulated, we want to
;; manipulate the multi scope, instead (at a particular
;; phase shift)
(define (generalize-scope sc)
  (if (representative-scope? sc)
      (intern-shifted-multi-scope (representative-scope-phase sc)
                                  (representative-scope-owner sc))
      sc))

(define (add-scope s sc)
  (apply-scope s (generalize-scope sc) set-add propagation-add))

(define (add-scopes s scs)
  (for/fold ([s s]) ([sc (in-list scs)])
    (add-scope s sc)))

(define (remove-scope s sc)
  (apply-scope s (generalize-scope sc) set-remove propagation-remove))

(define (remove-scopes s scs)
  (for/fold ([s s]) ([sc (in-list scs)])
    (remove-scope s sc)))

(define (set-flip s e)
  (if (set-member? s e)
      (set-remove s e)
      (set-add s e)))

(define (flip-scope s sc)
  (apply-scope s (generalize-scope sc) set-flip propagation-flip))

(define (flip-scopes s scs)
  (for/fold ([s s]) ([sc (in-list scs)])
    (flip-scope s sc)))

;; Pushes a multi-scope to accomodate multiple top-level namespaces.
;; See "fallback.rkt".
(define (push-scope s sms)
  (define-memo-lite (push smss/maybe-fallbacks)
    (define smss (fallback-first smss/maybe-fallbacks))
    (cond
     [(set-empty? smss) (set-add smss sms)]
     [(set-member? smss sms) smss/maybe-fallbacks]
     [else (fallback-push (set-add smss sms)
                          smss/maybe-fallbacks)]))
  (syntax-map s
              (lambda (tail? x) x)
              (lambda (s d)
                (struct-copy syntax s
                             [content d]
                             [shifted-multi-scopes
                              (push (syntax-shifted-multi-scopes s))]))
              syntax-e/no-taint))

;; ----------------------------------------

(struct propagation (prev-scs prev-smss scope-ops)
        #:property prop:propagation syntax-e)

(define (propagation-add prop sc prev-scs prev-smss)
  (if prop
      (struct-copy propagation prop
                   [scope-ops (hash-set (propagation-scope-ops prop)
                                        sc
                                        'add)])
      (propagation prev-scs prev-smss (hasheq sc 'add))))

(define (propagation-remove prop sc prev-scs prev-smss)
  (if prop
      (struct-copy propagation prop
                   [scope-ops (hash-set (propagation-scope-ops prop)
                                        sc
                                        'remove)])
      (propagation prev-scs prev-smss (hasheq sc 'remove))))

(define (propagation-flip prop sc prev-scs prev-smss)
  (if prop
      (let* ([ops (propagation-scope-ops prop)]
             [current-op (hash-ref ops sc #f)])
        (cond
         [(and (eq? current-op 'flip)
               (= 1 (hash-count ops)))
          ;; Nothing left to propagate
          #f]
         [else
          (struct-copy propagation prop
                       [scope-ops
                        (if (eq? current-op 'flip)
                            (hash-remove ops sc)
                            (hash-set ops sc (case current-op
                                               [(add) 'remove]
                                               [(remove) 'add]
                                               [else 'flip])))])]))
      (propagation prev-scs prev-smss (hasheq sc 'flip))))

(define (propagation-apply prop scs parent-s)
  (cond
   [(not prop) scs]
   [(eq? (propagation-prev-scs prop) scs)
    (syntax-scopes parent-s)]
   [else
    (for/fold ([scs scs]) ([(sc op) (in-immutable-hash (propagation-scope-ops prop))]
                           #:when (not (shifted-multi-scope? sc)))
      (case op
       [(add) (set-add scs sc)]
       [(remove) (set-remove scs sc)]
       [else (set-flip scs sc)]))]))

(define (propagation-apply-shifted prop smss parent-s)
  (cond
   [(not prop) smss]
   [(eq? (propagation-prev-smss prop) smss)
    (syntax-shifted-multi-scopes parent-s)]
   [else
    (for/fold ([smss smss]) ([(sms op) (in-immutable-hash (propagation-scope-ops prop))]
                             #:when (shifted-multi-scope? sms))
      (fallback-update-first
       smss
       (lambda (smss)
         (case op
           [(add) (set-add smss sms)]
           [(remove) (set-remove smss sms)]
           [else (set-flip smss sms)]))))]))

(define (propagation-merge prop base-prop prev-scs prev-smss)
  (cond
   [(not prop) base-prop]
   [(not base-prop) (propagation prev-scs
                                 prev-smss
                                 (propagation-scope-ops prop))]
   [else
    (define new-ops
      (for/fold ([ops (propagation-scope-ops base-prop)]) ([(sc op) (in-immutable-hash (propagation-scope-ops prop))])
        (case op
          [(add) (hash-set ops sc 'add)]
          [(remove) (hash-set ops sc 'remove)]
          [else ; flip
           (define current-op (hash-ref ops sc #f))
           (case current-op
             [(add) (hash-set ops sc 'remove)]
             [(remove) (hash-set ops sc 'add)]
             [(flip) (hash-remove ops sc)]
             [else (hash-set ops sc 'flip)])])))
    (if (zero? (hash-count new-ops))
        #f
        (struct-copy propagation base-prop
                     [scope-ops new-ops]))]))

;; ----------------------------------------

;; To shift a syntax's phase, we only have to shift the phase
;; of any phase-specific scopes. The bindings attached to a
;; scope must be represented in such a way that the binding
;; shift is implicit via the phase in which the binding
;; is resolved.
(define (shift-multi-scope sms delta)
  (cond
   [(zero-phase? delta)
    ;; No-op shift
    sms]
   [(label-phase? delta)
    (cond
     [(shifted-to-label-phase? (shifted-multi-scope-phase sms))
      ;; Shifting to the label phase moves only phase 0, so
      ;; drop a scope that is already collapsed to phase #f
      #f]
     [else
      ;; Move the current phase 0 to the label phase, which
      ;; means recording the negation of the current phase
      (intern-shifted-multi-scope (shifted-to-label-phase (phase- 0 (shifted-multi-scope-phase sms)))
                                  (shifted-multi-scope-multi-scope sms))])]
   [(shifted-to-label-phase? (shifted-multi-scope-phase sms))
    ;; Numeric shift has no effect on bindings in phase #f
    sms]
   [else
    ;; Numeric shift added to an existing numeric shift
    (intern-shifted-multi-scope (phase+ delta (shifted-multi-scope-phase sms))
                                (shifted-multi-scope-multi-scope sms))]))

;; Since we tend to shift rarely and only for whole modules, it's
;; probably not worth making this lazy
(define (syntax-shift-phase-level s phase)
  (if (eqv? phase 0)
      s
      (let ()
        (define-memo-lite (shift-all smss)
          (fallback-map
           smss
           (lambda (smss)
             (for*/seteq ([sms (in-set smss)]
                          [new-sms (in-value (shift-multi-scope sms phase))]
                          #:when new-sms)
               new-sms))))
        (syntax-map s
                    (lambda (tail? d) d)
                    (lambda (s d)
                      (struct-copy syntax s
                                   [content d]
                                   [shifted-multi-scopes
                                    (shift-all (syntax-shifted-multi-scopes s))]))
                    syntax-e/no-taint))))

;; ----------------------------------------

;; Scope swapping is used to make top-level compilation relative to
;; the top level. Each top-level environment has a set of scopes that
;; identify the environment; usually, it's a common outside-edge scope
;; and a namespace-specific inside-edge scope, but there can be
;; additional scopes due to `module->namespace` on a module that was
;; expanded multiple times (where each expansion adds scopes).
(define (syntax-swap-scopes s src-scopes dest-scopes)
  (if (equal? src-scopes dest-scopes)
      s
      (let-values ([(src-smss src-scs)
                    (set-partition (for/seteq ([sc (in-set src-scopes)])
                                     (generalize-scope sc))
                                   shifted-multi-scope?
                                   (seteq)
                                   (seteq))]
                   [(dest-smss dest-scs)
                    (set-partition (for/seteq ([sc (in-set dest-scopes)])
                                     (generalize-scope sc))
                                   shifted-multi-scope?
                                   (seteq)
                                   (seteq))])
        (define-memo-lite (swap-scs scs)
          (if (subset? src-scs scs)
              (set-union (set-subtract scs src-scs) dest-scs)
              scs))
        (define-memo-lite (swap-smss smss)
          (fallback-update-first
           smss
           (lambda (smss)
             (if (subset? src-smss smss)
                 (set-union (set-subtract smss src-smss) dest-smss)
                 smss))))
        (syntax-map s
                    (lambda (tail? d) d)
                    (lambda (s d)
                      (struct-copy syntax s
                                   [content d]
                                   [scopes (swap-scs (syntax-scopes s))]
                                   [shifted-multi-scopes
                                    (swap-smss (syntax-shifted-multi-scopes s))]))
                    syntax-e/no-taint))))

;; ----------------------------------------

;; Assemble the complete set of scopes at a given phase by extracting
;; a phase-specific representative from each multi-scope.
(define (syntax-scope-set s phase)
  (scope-set-at-fallback s (fallback-first (syntax-shifted-multi-scopes s)) phase))
  
(define (scope-set-at-fallback s smss phase)
  (for*/fold ([scopes (syntax-scopes s)]) ([sms (in-set smss)]
                                           #:when (or (label-phase? phase)
                                                      (not (shifted-to-label-phase? (shifted-multi-scope-phase sms)))))
    (set-add scopes (multi-scope-to-scope-at-phase (shifted-multi-scope-multi-scope sms)
                                                   (let ([ph (shifted-multi-scope-phase sms)])
                                                     (if (shifted-to-label-phase? ph)
                                                         (shifted-to-label-phase-from ph)
                                                         (phase- ph phase)))))))

(define (find-max-scope scopes)
  (when (set-empty? scopes)
    (error "cannot bind in empty scope set"))
  (for/fold ([max-sc (set-first scopes)]) ([sc (in-set scopes)])
    (if (scope>? sc max-sc)
        sc
        max-sc)))

(define (add-binding-in-scopes! scopes sym binding)
  (define max-sc (find-max-scope scopes))
  (define bt (binding-table-add (scope-binding-table max-sc) scopes sym binding))
  (set-scope-binding-table! max-sc bt)
  (clear-resolve-cache! sym))

(define (add-bulk-binding-in-scopes! scopes bulk-binding)
  (define max-sc (find-max-scope scopes))
  (define bt (binding-table-add-bulk (scope-binding-table max-sc) scopes bulk-binding))
  (set-scope-binding-table! max-sc bt)
  (clear-resolve-cache!))

(define (syntax-any-scopes? s)
  (not (set-empty? (syntax-scopes s))))

(define (syntax-any-macro-scopes? s)
  (for/or ([sc (in-set (syntax-scopes s))])
    (eq? (scope-kind sc) 'macro)))

;; ----------------------------------------

;; Result is #f for no binding, `ambigious-value` for an ambigious binding,
;; or binding value
(define (resolve s phase
                 #:ambiguous-value [ambiguous-value #f]
                 #:exactly? [exactly? #f]
                 ;; For resolving bulk bindings in `free-identifier=?` chains:
                 #:extra-shifts [extra-shifts null])
  (unless (identifier? s)
    (raise-argument-error 'resolve "identifier?" s))
  (unless (phase? phase)
    (raise-argument-error 'resolve "phase?" phase))
  (let fallback-loop ([smss (syntax-shifted-multi-scopes s)])
    (define scopes (scope-set-at-fallback s (fallback-first smss) phase))
    (define sym (syntax-content s))
    (cond
     [(and (not exactly?)
           (resolve-cache-get sym phase scopes))
      => (lambda (b) b)]
     [else
      (define candidates
        (for*/list ([sc (in-set scopes)]
                    [(b-scopes binding) (in-binding-table sym (scope-binding-table sc) s extra-shifts)]
                    #:when (and b-scopes binding (subset? b-scopes scopes)))
          (cons b-scopes binding)))
      (define max-candidate
        (and (pair? candidates)
             (for/fold ([max-c (car candidates)]) ([c (in-list (cdr candidates))])
               (if ((set-count (car c)) . > . (set-count (car max-c)))
                   c
                   max-c))))
      (cond
       [max-candidate
        (cond
         [(not (for/and ([c (in-list candidates)])
                 (subset? (car c) (car max-candidate))))
          (if (fallback? smss)
              (fallback-loop (fallback-rest smss))
              ambiguous-value)]
         [else
          (resolve-cache-set! sym phase scopes (cdr max-candidate))
          (and (or (not exactly?)
                   (equal? (set-count scopes)
                           (set-count (car max-candidate))))
               (cdr max-candidate))])]
       [else
        (if (fallback? smss)
            (fallback-loop (fallback-rest smss))
            #f)])])))

;; ----------------------------------------

(define (bound-identifier=? a b phase)
  (and (eq? (syntax-e a)
            (syntax-e b))
       (equal? (syntax-scope-set a phase)
               (syntax-scope-set b phase))))
