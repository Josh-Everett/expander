#lang racket/base
(require racket/cmdline
         racket/pretty
         "common/set.rkt"
         "main.rkt"
         "namespace/namespace.rkt"
         "common/module-path.rkt"
         "eval/module-read.rkt"
         "boot/kernel.rkt"
         "run/cache.rkt"
         "boot/runtime-primitive.rkt"
         "host/linklet.rkt"
         "run/reader-bridge.rkt"
         "run/status.rkt"
         "run/submodule.rkt"
         "host/correlate.rkt"
         "extract/main.rkt"
         (only-in "run/linklet.rkt" linklet-compile-to-s-expr))

(define extract? #f)
(define expand? #f)
(define linklets? #f)
(define cache-dir #f)
(define cache-read-only? #f)
(define cache-save-only #f)
(define cache-skip-first? #f)
(define time-expand? #f)
(define print-extracted-to #f)
(define extract-to-c? #f)
(define quiet-load? #f)
(define startup-module (path->complete-path "main.rkt"))
(define submod-name #f)
(define load-file #f)
(define args
  (command-line
   #:once-any
   [("-x" "--extract") "Extract bootstrap linklet"
    (set! extract? #t)]
   [("-e" "--expand") "Expand instead of running"
    (set! expand? #t)]
   [("--linklets") "Compile to linklets instead of running"
    (set! linklets? #t)]
   #:once-each
   [("-c" "--cache") dir "Save and load from <dir>"
    (set! cache-dir (path->complete-path dir))]
   [("-r" "--read-only") "Use cache in read-only mode"
    (set! cache-read-only? #t)]
   [("-y" "--cache-only") file "Cache only for sources listed in <file>"
    (set! cache-save-only (call-with-input-file* file read))]
   [("-i" "--skip-initial") "Don't use cache for the initial load"
    (set! cache-skip-first? #t)]
   [("-s" "--s-expr") "Compile to S-expression instead of bytecode"
    (linklet-compile-to-s-expr #t)]
   [("-q" "--quiet") "Quiet load status"
    (set! quiet-load? #t)]
   [("--time") "Time re-expansion"
    (set! time-expand? #t)]
   [("-o" "--output") file "Print extracted bootstrap linklet to <file>"
    (set! print-extracted-to file)]
   [("-C") "Print extracted bootstrap as a C encoding"
    (set! extract-to-c? #t)]
   #:once-any
   [("-t") file "Load specified file"
    (set! startup-module (path->complete-path file))]
   [("-l") lib "Load specified library"
    (set! startup-module `(lib ,lib))]
   [("-f") file "Load non-module file in `racket/base` namespace"
    (set! startup-module 'racket/base)
    (set! load-file file)]
   #:once-each
   [("--submod") name "Load specified submodule"
    (set! submod-name (string->symbol name))]
   #:args args args))

(define cache (make-cache cache-dir (lambda (path)
                                      (log-status "changed: ~a" path))))

;; Install handlers:
(boot)

;; Avoid use of ".zo" files:
(use-compiled-file-paths null)

;; Replace the load handler to stash compiled modules in the cache
;; and/or load them from the cache
(define orig-load (current-load))
(current-load (lambda (path expected-module)
                (cond
                 [expected-module
                  (let loop ()
                    (cond
                     [(and cache
                           (not cache-skip-first?)
                           (get-cached-compiled cache path
                                                (lambda ()
                                                  (when cache-dir
                                                    (unless quiet-load?
                                                      (log-status "cached: ~a" path))))))
                      => (lambda (m)
                           ;; Since we've set `use-compiled-file-paths` to null,
                           ;; the load/use-compiled handler thinks that we're
                           ;; always loading from source, so don't find the
                           ;; expected submodule with
                           ;;  `(extract-requested-submodule m expected-module)`
                           (eval m))]
                     [(and (pair? expected-module)
                           (not (car expected-module)))
                      ;; shouldn't load from source when `expected-module` start with #f
                      (void)]
                     [else
                      (unless quiet-load?
                        (log-status "compile: ~a" path))
                      (set! cache-skip-first? #f)
                      (with-handlers ([exn:fail? (lambda (exn)
                                                   (unless quiet-load?
                                                     (log-status "...during ~a..." path))
                                                   (raise exn))])
                        (define s
                          (call-with-input-file*
                           path
                           (lambda (i)
                             (port-count-lines! i)
                             (with-module-reading-parameterization
                                 (lambda ()
                                   (check-module-form
                                    (read-syntax (object-name i) i)
                                    path))))))
                        (define cache-layer (make-cache-layer))
                        (define c
                          (parameterize ([current-cache-layer cache-layer])
                            (compile s)))
                        (when time-expand?
                          ;; Re-expanding avoids timing load of required modules
                          (time (expand s)))
                        (cond
                         [(and cache
                               (not cache-read-only?)
                               (or (not cache-save-only)
                                   (hash-ref cache-save-only (path->string path) #f)))
                          (cache-compiled! cache path c cache-layer)
                          (loop)]
                         [else (eval c)]))]))]
                 [else (orig-load path #f)])))

(define orig-resolver (current-module-name-resolver))
(current-module-name-resolver
 (case-lambda
   [(r ns) (orig-resolver r ns)]
   [(r wrt src load?)
    (define p (orig-resolver r wrt src load?))
    (define n (resolved-module-path-name p))
    (when (path? n)
      (register-dependency! cache n))
    p]))

;; Set the reader guard to load modules on demand, and
;; synthesize a module for the host Racket to call
;; the hosted module system's instance
(current-reader-guard (lambda (mod-path)
                        (define synth-mod-path
                          ;; Pick a module path that won't conflict with anything
                          ;; in the host system
                          (if (and (pair? mod-path)
                                   (eq? 'submod (car mod-path)))
                              `(submod ,(cadr mod-path) synthesized-reader)
                              `(submod ,mod-path synthesized-reader)))
                        (when (module-declared? mod-path #t)
                          (define rs (dynamic-require mod-path 'read-syntax))
                          (synthesize-reader-bridge-module mod-path synth-mod-path rs))
                        synth-mod-path))

(define (apply-to-module proc mod-path)
  (define path (resolved-module-path-name
                (resolve-module-path mod-path #f)))
  (define-values (dir file dir?) (split-path path))
  (parameterize ([current-load-relative-directory dir])
    (proc (call-with-input-file*
           path
           (lambda (i)
             (port-count-lines! i)
             (with-module-reading-parameterization
                 (lambda ()
                   (check-module-form
                    (read-syntax (object-name i) i)
                    path))))))))

(cond
 [expand?
  (pretty-write (syntax->datum (apply-to-module expand startup-module)))]
 [linklets?
  (pretty-write (correlated->datum
                 (datum->correlated
                  (apply-to-module compile-to-linklets startup-module) #f)))]
 [else
  ;; Load and run the requested module
  (parameterize ([current-command-line-arguments (list->vector args)])
    (namespace-require (if submod-name
                           `(submod ,startup-module ,submod-name)
                           startup-module)))])

(when extract?
  ;; Extract a bootstrapping slice of the requested module
  (extract startup-module cache
           #:print-extracted-to print-extracted-to
           #:as-c? extract-to-c?))

(when load-file
  (load load-file))
