(local {: modname-to-path } (require :hotpot.path_resolver))
(local {: compile-file} (require :hotpot.compiler))
(local config (require :hotpot.config))
(local {: file-missing?
        : file-stale?
        : file-exists?
        : is-lua-path?
        : is-fnl-path?
        : write-file!
        : read-file!} (require :hotpot.fs))
(import-macros {: dinfo : require-fennel} :hotpot.macros)
(local debug-modname "hotpot.searcher.module")

;;
;; Hotpot is a bit awkard because it's self hosted, so this dependency
;; tracking code must be kept in-file do avoid extra requires that can lead
;; to circular dependencies
;;

(fn dependency-filename [lua-path]
  (.. lua-path ".deps"))

(fn read-dependencies [lua-path]
  (local lines (read-file! (dependency-filename lua-path)))
  (icollect [line (string.gmatch lines "([^\n]*)\n?")]
            (if (~= line "") line)))

(fn write-dependencies [fnl-path lua-path]
  ; require inside this function to avoid circular issues
  (let [dep_map (require :hotpot.dependency_map)
        deps (dep_map.deps-for-fnl-path fnl-path)
        path (dependency-filename lua-path)]
    ; if there are no dependencies, we should remove the old dependecy file,
    ; otherwise we refresh them.
    (match deps
      nil (if (file-exists? path)
            (assert (os.remove path)))
      _ (write-file! path (table.concat deps "\n")))))

(fn has-dependencies [lua-path]
  (vim.loop.fs_access (dependency-filename lua-path) "R"))

(fn has-stale-dependency [fnl-path lua-path]
  (local deps (read-dependencies lua-path))
  (var has_stale false)
  (each [_ dep-path (ipairs deps) :until has_stale]
    ;; TODO: how to handle missing dep file? right now we just crash
    ;; NOTE: this check is reversed to the normal stale check
    ;;       we want to know when the fnl file is stale compared
    ;;       to the dependecy
    (set has_stale (file-stale? dep-path lua-path)))
  has_stale)

;;
;; Compilation
;;

(fn needs-compilation? [fnl-path lua-path]
  (or
    ;; lua file doesn't exist or it is older than the fennel file
    ;; this should run first so any dependency changes are discovered
    ;; (particularly the removal of)
    (or (file-missing? lua-path)
        (file-stale? fnl-path lua-path))
    ;; or one of the dependencies are newer
    (and (has-dependencies lua-path)
         (has-stale-dependency fnl-path lua-path))))

(fn compile-fnl [fnl-path lua-path modname]
  ;; (string, string) :: true | false, errors
  (local plug-macro-dep-tracking
    {:versions [:1.0.0]
     :name :hotpot-macro-dep-tracking
     :require-macros
     (fn plug-require-macros [ast scope]
       (let [fennel (require-fennel)
             {2 second} ast
             ; could be (.. :my :mod) so we have to eval it. See
             ; SPECIALS.require-macro in fennel code. May need to be extended
             ; to support arbitrary function call, (eval with scope?)
             macro-modname (fennel.eval (fennel.view second))
             dep_map (require :hotpot.dependency_map)]
         (dep_map.fnl-path-depends-on-macro-module fnl-path macro-modname))
       ; dont halt other plugins
       (values nil))})
  (match (needs-compilation? fnl-path lua-path)
    true (do
           ; inject our plugin, must only exist for this compile-file call
           ; because it depends on the specific fnl-path closure value, so we
           ; will table.remove it after calling compile.
           (local options (config.get-option :compiler.modules))
           (tset options :plugins (or options.plugins []))
           (table.insert options.plugins 1 plug-macro-dep-tracking)
           (local (ok errors) (compile-file fnl-path lua-path options))
           (table.remove options.plugins 1)

           ; avoid circular compile loop while writing out the dependencies
           ;; TODO: can just match tail of fnl-path
           (when (and ok (not (= modname :hotpot.dependency_map)))
             (write-dependencies fnl-path lua-path))

           (values ok errors))
    ;; no compilation needed, so just pretend that compile-file worked
    false (values true)))

;;
;; Loaders
;;

(fn create-loader! [modname mod-path]
  (fn create-lua-loader [lua-path]
    (loadfile lua-path))
  ;; already a lua path so just make the loader directly
  ;; not a lua file so we have to transpile.
  (match [(is-lua-path? mod-path) (is-fnl-path? mod-path)]
    [true false] (create-lua-loader mod-path)
    [false true] (let [{: fnl-path-to-lua-path} (require :hotpot.path_resolver)
                       lua-path (fnl-path-to-lua-path mod-path)]
                   (match (compile-fnl mod-path lua-path modname)
                     true (create-lua-loader lua-path)
                     (false errors) (values nil errors)))
    _ (error (.. "hotpot could not create loader for " mod-path))))

;;
;; The Searcher
;;

(fn searcher [modname]
  ;; (table string) :: fn
  ;; Lua package searcher with hot-compile step, this is core to hotpot.
  ;;
  ;; Given abc.xyz, find a matching abc/xyz.fnl, if it exists, check if we have
  ;; an existing abc/xyz.lua in cache. If we do, check if it's stale.
  ;; If stale or missing, complile and return a loader for the cached file
  ;; If the original modname was for a lua file, just return a loader for that.
  (or (. package :preload modname)
      (create-loader! modname (modname-to-path modname))))

;       (match (modname-to-path modname)
;              path (match (pcall create-loader! modname path)
;                          (true loader) loader
;                          (false errors) (false errors)))))
;;(create-error-loader modname path errors)))))

{: searcher
 :create-loader create-loader!}
