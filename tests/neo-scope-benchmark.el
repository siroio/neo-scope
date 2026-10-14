;;; neo-scope-benchmark.el --- Local baseline -*- lexical-binding: t; -*-
(require 'neo-scope)
(require 'benchmark)
(let ((root (expand-file-name "../emacs.d")) (start (float-time)) items done)
  (let ((cancel (funcall (plist-get (neo-scope-file-source root) :start) ""
                         (lambda (event payload)
                           (pcase event ('add (setq items (nconc items payload)))
                             ('done (setq done t)) ('error (error "%s" payload)))))))
    (unwind-protect
        (progn
          (while (not done) (sleep-for 0.01))
          (princ (format "ROOT=%s CANDIDATES=%d ENUMERATION=%.3fs\n" root (length items) (- (float-time) start)))
          (dolist (query '("init" "neo" "日本"))
            (princ (format "QUERY=%s MATCH-10-RUNS=%S\n" query
                           (benchmark-run 10 (dolist (candidate items) (neo-scope-fuzzy-match query candidate)))))))
      (funcall cancel))))
