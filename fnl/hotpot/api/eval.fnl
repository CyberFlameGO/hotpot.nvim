(fn inject-macro-searcher []
  ;; The macro-searcher is not inserted until we compile something because it
  ;; needs to load fennel firsts which has a performance impact. This has the
  ;; side effect of making macros un-findable if you try to eval code before
  ;; ever compiling anything, so to fix that we'll compile some code before we
  ;; try to eval anything.
  ;; This isn't run in every function, only the delegates.
  (let [{: compile-string} (require :hotpot.api.compile)]
    (compile-string "(+ 1 1)")))

(fn eval-string [code ?options]
  "Evaluate given fennel `code`, returns `true result ...` or `false
  error`. Accepts an optional `options` table as described by Fennels
  API documentation."
  (inject-macro-searcher)
  (let [{: eval} (require :hotpot.fennel)
        {: traceback} (require :hotpot.runtime)
        options (or ?options {})
        _ (if (= nil options.filename)
            (tset options :filename :hotpot-live-eval))
        do-eval #(eval code options)]
    (xpcall do-eval traceback)))

(fn eval-range [buf start-pos stop-pos ?options]
  "Evaluate `buf` from `start-pos` to `end-pos`, returns `true result
  ...` or `false error`. Positions can be `line` or `line col`. Accepts
  an optional `options` table as described by Fennels API
  documentation."
  (let [{: get-range} (require :hotpot.api.get_text)]
    (-> (get-range buf start-pos stop-pos)
        (eval-string ?options))))

(fn eval-selection [?options]
  "Evaluate the current selection, returns `true result ...` or `false
  error`. Accepts an optional `options` table as described by Fennels
  API documentation."
  (let [{: get-selection} (require :hotpot.api.get_text)]
    (-> (get-selection)
        (eval-string ?options))))

(fn eval-buffer [buf ?options]
  "Evaluate the given `buf`, returns `true result ...` or `false error`.
  Accepts an optional `options` table as described by Fennels API
  documentation."
  (let [{: get-buf} (require :hotpot.api.get_text)]
    (-> (get-buf buf)
        (eval-string ?options))))

(fn eval-file [fnl-file ?options]
  "Read contents of `fnl-path` and evaluate the contents, returns `true
  result ...` or `false error`. Accepts an optional `options` table as
  described by Fennels API documentation."
  (inject-macro-searcher)
  (assert fnl-file "eval-file: must provide path to .fnl file")
  (let [{: dofile} (require :hotpot.fennel)
        {: traceback} (require :hotpot.runtime)
        options (or ?options {})]
    (if (= nil options.filename)
      (tset options :filename fnl-file))
    (xpcall #(dofile fnl-file options) traceback)))

(fn eval-module [modname ?options]
  "Use hotpots module searcher to find the file for `modname`, load and
  evaluate its contents, returns `true result ...` or `false error`..
  Accepts an optional `options` table as described by Fennels API
  documentation."
  (assert modname "eval-module: must provide modname")
  (let [{: searcher} (require :hotpot.searcher.source)
        {: is-fnl-path?} (require :hotpot.fs)
        path (searcher modname {:fennel-only? true})
        options (or ?options {})]
    (assert path (string.format "eval-modname: could not find file for module %s"
                                modname))
    (assert (is-fnl-path? path)
            (string.format "eval-modname: did not resolve to .fnl file: %s %s"
                           modname path))
    (if (= nil options.filename)
      (tset options :filename path))
    (if (= nil options.module-name)
      (tset options :module-name modname))
    (eval-file path options)))

{: eval-string
 : eval-range
 : eval-selection
 : eval-buffer
 : eval-file
 : eval-module}
