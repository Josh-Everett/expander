#lang racket/base
(require "../common/phase.rkt"
         (rename-in "syntax.rkt"
                    [syntax->datum raw:syntax->datum]
                    [datum->syntax raw:datum->syntax])
         (rename-in "to-list.rkt"
                    [syntax->list raw:syntax->list])
         (rename-in "scope.rkt"
                    [syntax-e raw:syntax-e]
                    [bound-identifier=? raw:bound-identifier=?]
                    [syntax-shift-phase-level raw:syntax-shift-phase-level])
         (rename-in "binding.rkt"
                    [free-identifier=? raw:free-identifier=?]
                    [identifier-binding raw:identifier-binding]
                    [identifier-binding-symbol raw:identifier-binding-symbol])
         (rename-in "track.rkt"
                    [syntax-track-origin raw:syntax-track-origin])
         "../expand/syntax-local.rkt"
         "srcloc.rkt"
         "../common/contract.rkt"
         (rename-in "read-syntax.rkt"
                    [read-syntax raw:read-syntax]
                    [read-syntax/recursive raw:read-syntax/recursive])
         (rename-in "debug.rkt"
                    [syntax-debug-info raw:syntax-debug-info]))

(provide syntax?
         syntax-e
         syntax-property
         syntax-property-symbol-keys
         syntax-original?
         syntax->datum
         datum->syntax
         syntax->list
         identifier?
         bound-identifier=?
         free-identifier=?
         free-transformer-identifier=?
         free-template-identifier=?
         free-label-identifier=?
         identifier-binding
         identifier-transformer-binding
         identifier-template-binding
         identifier-label-binding
         identifier-binding-symbol
         identifier-prune-lexical-context
         syntax-shift-phase-level
         syntax-track-origin
         syntax-debug-info
         read-syntax
         read-syntax/recursive)

(define (syntax-e s)
  (check 'syntax-e syntax? s)
  (raw:syntax-e s))

(define (syntax->datum s)
  (check 'syntax->datum syntax? s)
  (raw:syntax->datum s))

(define (datum->syntax stx-c s [stx-l #f] [stx-p #f] [ignored #f])
  (unless (or (not stx-c) (syntax? stx-c))
    (raise-argument-error 'datum->syntax "(or #f syntax?)" stx-c))
  (unless (or (not stx-l)
              (syntax? stx-l)
              (encoded-srcloc? stx-l))
    (raise-argument-error 'datum->syntax "(or #f syntax? ...)" stx-l))
  (unless (or (not stx-p) (syntax? stx-p))
    (raise-argument-error 'datum->syntax "(or #f syntax?)" stx-p))
  (raw:datum->syntax stx-c s (to-srcloc-stx stx-l) stx-p))

(define (syntax->list s)
  (check 'syntax->list syntax? s)
  (raw:syntax->list s))

(define (syntax-original? s)
  (check 'syntax-original? syntax? s)
  (and (syntax-property s original-property-sym)
       (not (syntax-any-macro-scopes? s))))

(define (bound-identifier=? a b [phase (syntax-local-phase-level)])
  (check 'bound-identifier=? identifier? a)
  (check 'bound-identifier=? identifier? b)
  (unless (phase? phase)
    (raise-argument-error 'bound-identifier=? phase?-string phase))
  (raw:bound-identifier=? a b phase))

(define (free-identifier=? a b
                           [a-phase (syntax-local-phase-level)]
                           [b-phase a-phase])
  (check 'free-identifier=? identifier? a)
  (check 'free-identifier=? identifier? b)
  (unless (phase? a-phase)
    (raise-argument-error 'free-identifier=? phase?-string a-phase))
  (unless (phase? b-phase)
    (raise-argument-error 'free-identifier=? phase?-string b-phase))
  (raw:free-identifier=? a b a-phase b-phase))

(define (free-transformer-identifier=? a b)
  (check 'free-transformer-identifier=? identifier? a)
  (check 'free-transformer-identifier=? identifier? b)
  (define phase (add1 (syntax-local-phase-level)))
  (raw:free-identifier=? a b phase phase))

(define (free-template-identifier=? a b)
  (check 'free-template-identifier=? identifier? a)
  (check 'free-template-identifier=? identifier? b)
  (define phase (sub1 (syntax-local-phase-level)))
  (raw:free-identifier=? a b phase phase))

(define (free-label-identifier=? a b)
  (check 'free-label-identifier=? identifier? a)
  (check 'free-label-identifier=? identifier? b)
  (raw:free-identifier=? a b #f #f))

(define (identifier-binding id [phase  (syntax-local-phase-level)])
  (check 'identifier-binding identifier? id)
  (unless (phase? phase)
    (raise-argument-error 'identifier-binding phase?-string phase))
  (raw:identifier-binding id phase))

(define (identifier-transformer-binding id)
  (check 'identifier-transformer-binding identifier? id)
  (raw:identifier-binding id (add1 (syntax-local-phase-level))))

(define (identifier-template-binding id)
  (check 'identifier-template-binding identifier? id)
  (raw:identifier-binding id (sub1 (syntax-local-phase-level))))

(define (identifier-label-binding id)
  (check 'identifier-label-binding identifier? id)
  (raw:identifier-binding id #f))

(define (identifier-binding-symbol id [phase (syntax-local-phase-level)])
  (check 'identifier-binding-symbol identifier? id)
  (unless (phase? phase)
    (raise-argument-error 'identifier-binding-symbol phase?-string phase))
  (raw:identifier-binding-symbol id phase))

(define (identifier-prune-lexical-context id [syms null])
  (check 'identifier-prune-lexical-context identifier? id)
  (unless (and (list? syms)
               (andmap symbol? syms))
    (raise-argument-error 'identifier-prune-lexical-context "(listof symbol?)" syms))
  ;; It's a no-op in the Racket v6.5 expander
  id)

(define (syntax-debug-info s [phase (syntax-local-phase-level)] [all-bindings? #f])
  (check 'syntax-debug-info syntax? s)
  (unless (phase? phase)
    (raise-argument-error 'syntax-debug-info phase?-string phase))
  (raw:syntax-debug-info s phase all-bindings?))

(define (syntax-shift-phase-level s phase)
  (check 'syntax-shift-phase-level syntax? s)
  (unless (phase? phase)
    (raise-argument-error 'syntax-shift-phase-level phase?-string phase))
  (raw:syntax-shift-phase-level s phase))

(define (syntax-track-origin new-stx old-stx id)
  (check 'syntax-track-origin syntax? new-stx)
  (check 'syntax-track-origin syntax? old-stx)
  (check 'syntax-track-origin identifier? id)
  (raw:syntax-track-origin new-stx old-stx id))

;; ----------------------------------------

(define (read-syntax [src (object-name (current-input-port))] [in (current-input-port)])
  (check 'read-syntax input-port? in)
  (raw:read-syntax src in))

(define (read-syntax/recursive src in start readtable graph?)
  (check 'read-syntax/recursive input-port? in)
  (unless (or (char? start) (not start))
    (raise-argument-error 'read-syntax/recursive "(or/c char? #f)" start))
  (unless (or (readtable? readtable) (not readtable))
    (raise-argument-error 'read-syntax/recursive "(or/c readtable? #f)" readtable))
  (raw:read-syntax/recursive src in start readtable graph?))
