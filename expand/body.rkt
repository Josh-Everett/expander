#lang racket/base
(require "../syntax/syntax.rkt"
         "../syntax/scope.rkt"
         "../syntax/taint.rkt"
         "../syntax/match.rkt"
         "../namespace/module.rkt"
         "../syntax/binding.rkt"
         "env.rkt"
         "../syntax/track.rkt"
         "../syntax/error.rkt"
         "dup-check.rkt"
         "use-site.rkt"
         "../namespace/core.rkt"
         "../boot/runtime-primitive.rkt"
         "context.rkt"
         "liberal-def-ctx.rkt"
         "reference-record.rkt"
         "log.rkt"
         "main.rkt")

(provide expand-body
         expand-and-split-bindings-by-reference)

;; Expand a sequence of body forms in a definition context
(define (expand-body bodys ctx
                     #:source s #:disarmed-source disarmed-s
                     #:stratified? [stratified? #f]
                     #:track? [track? #f])
  (log-expand ctx 'enter-block)
  ;; The outside-edge scope identifies the original content of the
  ;; definition context
  (define outside-sc (new-scope 'local))
  ;; The inside-edge scope identifiers any form that appears (perhaps
  ;; through macro expansion) in the definition context
  (define inside-sc (new-scope 'intdef))
  (define init-bodys
    (for/list ([body (in-list bodys)])
      (add-scope (add-scope body outside-sc) inside-sc)))
  (log-expand ctx 'block-renames (datum->syntax #f init-bodys) (datum->syntax #f bodys))
  (define phase (expand-context-phase ctx))
  (define frame-id (make-reference-record)) ; accumulates info on referenced variables
  (define def-ctx-scopes (box null))
  ;; Create an expansion context for expanding only immediate macros;
  ;; this partial-expansion phase uncovers macro- and variable
  ;; definitions in the definition context
  (define body-ctx (struct-copy expand-context ctx
                                [context (list (make-liberal-define-context))]
                                [name #f]
                                [only-immediate? #t]
                                [def-ctx-scopes def-ctx-scopes]
                                [post-expansion-scope #:parent root-expand-context inside-sc]
                                [post-expansion-scope-action add-scope]
                                [scopes (list* outside-sc
                                               inside-sc
                                               (expand-context-scopes ctx))]
                                [use-site-scopes #:parent root-expand-context (box null)]
                                [frame-id #:parent root-expand-context frame-id]
                                [reference-records (cons frame-id
                                                         (expand-context-reference-records ctx))]
                                [all-scopes-stx
                                 #:parent root-expand-context
                                 (add-scope
                                  (add-scope (root-expand-context-all-scopes-stx ctx)
                                             outside-sc)
                                  inside-sc)]))
  (define name (expand-context-name ctx))
  ;; Loop through the body forms for partial expansion
  (let loop ([body-ctx body-ctx]
             [bodys init-bodys]
             [done-bodys null] ; accumulated expressions
             [val-idss null]   ; accumulated binding identifiers
             [val-keyss null]  ; accumulated binding keys
             [val-rhss null]   ; accumulated binding right-hand sides
             [track-stxs null] ; accumulated syntax for tracking
             [trans-idss null] ; accumulated `define-syntaxes` identifiers that have disappeared
             [dups (make-check-no-duplicate-table)])
    (cond
     [(null? bodys)
      ;; Partial expansion is complete, so finish by rewriting to
      ;; `letrec-values`
      (log-expand body-ctx (if (null? val-idss) 'block->list 'block->letrec))
      (define result-s
        (finish-expanding-body body-ctx frame-id def-ctx-scopes
                               (reverse val-idss) (reverse val-keyss) (reverse val-rhss) (reverse track-stxs)
                               (reverse done-bodys)
                               #:source s #:disarmed-source disarmed-s
                               #:stratified? stratified?
                               #:track? track?
                               #:name name))
      (attach-disappeared-transformer-bindings result-s (reverse trans-idss))]
     [else
      (log-expand body-ctx 'next)
      (define exp-body (expand (syntax-disarm (car bodys)) (if (and name (null? (cdr bodys)))
                                                               (struct-copy expand-context body-ctx
                                                                            [name name])
                                                               body-ctx)))
      (define disarmed-exp-body (syntax-disarm exp-body))
      (case (core-form-sym disarmed-exp-body phase)
        [(begin)
         ;; Splice a `begin` form
         (log-expand body-ctx 'prim-begin)
         (define-match m disarmed-exp-body '(begin e ...))
         (define (track e) (syntax-track-origin e exp-body))
         (define splice-bodys (append (map track (m 'e)) (cdr bodys)))
         (log-expand body-ctx 'splice splice-bodys)
         (loop body-ctx
               splice-bodys
               done-bodys
               val-idss
               val-keyss
               val-rhss
               track-stxs
               trans-idss
               dups)]
        [(define-values)
         ;; Found a variable definition; add bindings, extend the
         ;; environment, and continue
         (log-expand body-ctx 'prim-define-values)
         (define-match m disarmed-exp-body '(define-values (id ...) rhs))
         (define ids (remove-use-site-scopes (m 'id) body-ctx))
         (log-expand body-ctx 'rename-one (datum->syntax #f (list ids (m 'rhs))))
         (define new-dups (check-no-duplicate-ids ids phase exp-body dups))
         (define counter (root-expand-context-counter ctx))
         (define keys (for/list ([id (in-list ids)])
                        (add-local-binding! id phase counter #:frame-id frame-id #:in exp-body)))
         (define extended-env (for/fold ([env (expand-context-env body-ctx)]) ([key (in-list keys)]
                                                                               [id (in-list ids)])
                                (env-extend env key (local-variable id))))
         (loop (struct-copy expand-context body-ctx
                            [env extended-env])
               (cdr bodys)
               null
               ;; If we had accumulated some expressions, we
               ;; need to turn each into the equivalent of
               ;;  (defined-values () (begin <expr> (values)))
               ;; form so it can be kept with definitions to
               ;; preserved order
               (cons ids (append
                          (for/list ([done-body (in-list done-bodys)])
                            null)
                          val-idss))
               (cons keys (append
                           (for/list ([done-body (in-list done-bodys)])
                             null)
                           val-keyss))
               (cons (m 'rhs) (append
                               (for/list ([done-body (in-list done-bodys)])
                                 (no-binds done-body s phase))
                               val-rhss))
               (cons exp-body (append
                               (for/list ([done-body (in-list done-bodys)])
                                 #f)
                               track-stxs))
               trans-idss
               new-dups)]
        [(define-syntaxes)
         ;; Found a macro definition; add bindings, evaluate the
         ;; compile-time right-hand side, install the compile-time
         ;; values in the environment, and continue
         (log-expand body-ctx 'prim-define-syntaxes)
         (define-match m disarmed-exp-body '(define-syntaxes (id ...) rhs))
         (define ids (remove-use-site-scopes (m 'id) body-ctx))
         (log-expand body-ctx 'rename-one (datum->syntax #f (list ids (m 'rhs))))
         (define new-dups (check-no-duplicate-ids ids phase exp-body dups))
         (define counter (root-expand-context-counter ctx))
         (define keys (for/list ([id (in-list ids)])
                        (add-local-binding! id phase counter #:frame-id frame-id #:in exp-body)))
         (log-expand body-ctx 'prepare-env)
         (define vals (eval-for-syntaxes-binding (m 'rhs) ids body-ctx))
         (define extended-env (for/fold ([env (expand-context-env body-ctx)]) ([key (in-list keys)]
                                                                               [val (in-list vals)]
                                                                               [id (in-list ids)])
                                (maybe-install-free=id! val id phase)
                                (env-extend env key val)))
         (loop (struct-copy expand-context body-ctx
                            [env extended-env])
               (cdr bodys)
               done-bodys
               val-idss
               val-keyss
               val-rhss
               track-stxs
               (cons ids trans-idss)
               new-dups)]
        [else
         (cond
          [stratified?
           ;; Found an expression, so no more definitions are allowed
           (loop body-ctx
                 null
                 (append (reverse bodys) (cons exp-body done-bodys))
                 val-idss
                 val-keyss
                 val-rhss
                 track-stxs
                 trans-idss
                 dups)]
          [else
           ;; Found an expression; accumulate it and continue
           (loop body-ctx
                 (cdr bodys)
                 (cons exp-body done-bodys)
                 val-idss
                 val-keyss
                 val-rhss
                 track-stxs
                 trans-idss
                 dups)])])])))

;; Partial expansion is complete, so assumble the result as a
;; `letrec-values` form and continue expanding
(define (finish-expanding-body body-ctx frame-id def-ctx-scopes
                               val-idss val-keyss val-rhss track-stxs
                               done-bodys
                               #:source s #:disarmed-source disarmed-s
                               #:stratified? stratified?
                               #:track? track?
                               #:name name)
  (when (null? done-bodys)
    (raise-syntax-error #f "no expression after a sequence of internal definitions" s))
  ;; To reference core forms at the current expansion phase:
  (define s-core-stx
    (syntax-shift-phase-level core-stx (expand-context-phase body-ctx)))
  ;; As we finish expanding, we're no longer in a definition context
  (define finish-ctx (struct-copy expand-context (accumulate-def-ctx-scopes body-ctx def-ctx-scopes)
                                  [context 'expression]
                                  [use-site-scopes #:parent root-expand-context #f]
                                  [scopes (append
                                           (unbox (root-expand-context-use-site-scopes body-ctx))
                                           (expand-context-scopes body-ctx))]
                                  [only-immediate? #f]
                                  [def-ctx-scopes #f]
                                  [post-expansion-scope #:parent root-expand-context #f]))
  ;; Helper to expand and wrap the ending expressions in `begin`, if needed:
  (define (finish-bodys track?)
    (define block->list? (null? val-idss))
    (unless block->list? (log-expand body-ctx 'next-group)) ; to go with 'block->letrec
    (cond
     [(null? (cdr done-bodys))
      (define last-ctx (struct-copy expand-context finish-ctx
                                    [name name]
                                    [reference-records (cdr (expand-context-reference-records finish-ctx))]))
      (define exp-body (expand (car done-bodys) last-ctx))
      (if track?
          (let ([result-s (syntax-track-origin exp-body s)])
            (log-expand body-ctx 'tag result-s)
            result-s)
          exp-body)]
     [else
      (unless block->list? (log-expand body-ctx 'prim-begin))
      (define last-i (sub1 (length done-bodys)))
      (log-expand body-ctx 'enter-list exp-bodys)
      (define exp-bodys (for/list ([body (in-list done-bodys)]
                                   [i (in-naturals)])
                          (log-expand body-ctx 'next)
                          (expand body (if (and name (= i last-i))
                                           (struct-copy expand-context finish-ctx
                                                        [name name])
                                           finish-ctx))))
      (log-expand body-ctx 'exit-list exp-bodys)
      (rebuild
       #:track? track?
       s disarmed-s
       `(,(datum->syntax s-core-stx 'begin)
         ,@exp-bodys))]))
  (cond
   [(null? val-idss)
    ;; No definitions, so no `letrec-values` wrapper needed:
    (finish-bodys track?)]
   [else
    ;; Roughly, finish expanding the right-hand sides, finish the body
    ;; expression, then add a `letrec-values` wrapper:
    (expand-and-split-bindings-by-reference
     val-idss val-keyss val-rhss track-stxs
     #:split? (not stratified?)
     #:frame-id frame-id #:ctx finish-ctx
     #:source s #:disarmed-source disarmed-s
     #:get-body finish-bodys #:track? track?)]))

;; Roughly, create a `letrec-values` for for the given ids, right-hand sides, and
;; body. While expanding right-hand sides, though, keep track of whether any
;; forward references appear, and if not, generate a `let-values` form, instead,
;; at each binding clause. Similar, end a `letrec-values` form and start a new
;; one if there were forward references up to the clause but not beyond.
(define (expand-and-split-bindings-by-reference idss keyss rhss track-stxs
                                                #:split? split?
                                                #:frame-id frame-id #:ctx ctx 
                                                #:source s #:disarmed-source disarmed-s
                                                #:get-body get-body #:track? track?)
  (define s-core-stx
    (syntax-shift-phase-level core-stx (expand-context-phase ctx)))
  (let loop ([idss idss] [keyss keyss] [rhss rhss] [track-stxs track-stxs]
             [accum-idss null] [accum-rhss null] [accum-track-stxs null]
             [track? track?])
    (cond
     [(null? idss)
      (cond
       [(null? accum-idss) (get-body track?)]
       [else
        (rebuild
         #:track? track?
         s disarmed-s
         `(,(datum->syntax s-core-stx 'letrec-values)
           ,(build-clauses accum-idss accum-rhss accum-track-stxs)
           ,(get-body #f)))])]
     [else
      (log-expand ctx 'next)
      (define ids (car idss))
      (define expanded-rhs (expand (car rhss) (as-named-context ctx ids)))
      (define track-stx (car track-stxs))
      
      (define local-or-forward-references? (reference-record-forward-references? frame-id))
      (reference-record-bound! frame-id (car keyss))
      (define forward-references? (reference-record-forward-references? frame-id))
      
      (cond
       [(and (not local-or-forward-references?)
             split?)
        (unless (null? accum-idss) (error "internal error: accumulated ids not empty"))
        (rebuild
         #:track? track?
         s disarmed-s
         `(,(datum->syntax s-core-stx 'let-values)
           (,(build-clause ids expanded-rhs track-stx))
           ,(loop (cdr idss) (cdr keyss) (cdr rhss) (cdr track-stxs)
                  null null null
                  #f)))]
       [(and (not forward-references?)
             (or split? (null? (cdr idss))))
        (rebuild
         #:track? track?
         s disarmed-s
         `(,(datum->syntax s-core-stx 'letrec-values)
           ,(build-clauses (cons ids accum-idss)
                           (cons expanded-rhs accum-rhss)
                           (cons track-stx accum-track-stxs))
           ,(loop (cdr idss) (cdr keyss) (cdr rhss) (cdr track-stxs)
                  null null null
                  #f)))]
       [else
        (loop (cdr idss) (cdr keyss) (cdr rhss) (cdr track-stxs)
              (cons ids accum-idss) (cons expanded-rhs accum-rhss) (cons track-stx accum-track-stxs)
              track?)])])))

(define (build-clauses accum-idss accum-rhss accum-track-stxs)
  (map build-clause
       (reverse accum-idss)
       (reverse accum-rhss)
       (reverse accum-track-stxs)))

(define (build-clause ids rhs track-stx)
  (define clause (datum->syntax #f `[,ids ,rhs]))
  (if track-stx
      (syntax-track-origin clause track-stx)
      clause))

;; Helper to turn an expression into a binding clause with zero
;; bindings
(define (no-binds expr s phase)
  (define s-core-stx (syntax-shift-phase-level core-stx phase))
  (define s-runtime-stx (syntax-shift-phase-level runtime-stx phase))
  (datum->syntax #f
                 `(,(datum->syntax s-core-stx 'begin)
                   ,expr
                   (,(datum->syntax s-core-stx '#%app)
                    ,(datum->syntax s-runtime-stx 'values)))
                 s))
