;;; neo-scope-package.el --- Isolated packaging check -*- lexical-binding: t; -*-
(require 'package)
(require 'use-package)
(let* ((root (expand-file-name default-directory))
       (package-user-dir (expand-file-name "build/package-test" root))
       (package-check-signature nil)
       (package-archives nil))
  (package-initialize)
  (package-install-file (expand-file-name "neo-scope.el" root))
  (unless (package-installed-p 'neo-scope) (error "Package was not installed"))
  (unless (autoloadp (symbol-function 'neo-scope-find-file)) (error "Missing command autoload"))
  ;; Expansion validates :vc availability/shape without fetching or publishing.
  (macroexpand '(use-package neo-scope
                 :vc (:url "https://github.com/siroio/neo-scope" :rev :newest)
                 :commands (neo-scope-find-file neo-scope-buffer neo-scope-grep)))
  (require 'neo-scope)
  (dolist (feature '(vertico consult orderless posframe))
    (when (featurep feature) (error "Unexpected dependency: %s" feature)))
  (princ "PACKAGE INSTALL + AUTOLOAD + USE-PACKAGE EXPANSION: PASS\n"))
