;;; neo-scope-performance.el --- Representative phase timings -*- lexical-binding: t; -*-
(require 'neo-scope)
(require 'benchmark)
(add-to-list 'load-path (expand-file-name "../emacs.d/elpa/orderless-20260927.2344"))
(require 'orderless)
(let* ((root (expand-file-name "../emacs.d"))
       (started (float-time))
       (items (neo-scope--collect (neo-scope-file-source root) "")))
  (princ (format "ENUMERATION root=%s count=%d seconds=%.3f\n" root (length items) (- (float-time) started)))
  (dolist (matcher '(neo-scope-fuzzy-match neo-scope-orderless-match))
    (dolist (query '("" "init" "neo" "config ui"))
      (let* ((neo-scope-matcher matcher)
             (s (neo-scope--make-state
                 :source '(:name "Performance") :query query :done t
                 :all items :pending (copy-sequence items) :matches []
                 :input (generate-new-buffer " *scope-perf-input*")
                 :candidates (generate-new-buffer " *scope-perf-results*")))
             (started (float-time)) (max-tick 0.0))
        (setq neo-scope--session s)
        (unwind-protect
            (progn
              (while (or (neo-scope--state-pending s) (neo-scope--state-match-timer s))
                (neo-scope--cancel-timer (neo-scope--state-match-timer s))
                (let ((tick (float-time)))
                  (neo-scope--match-batch s)
                  (setq max-tick (max max-tick (- (float-time) tick)))))
              (princ (format "MATCH matcher=%s query=%S seconds=%.3f max-tick-ms=%.2f matches=%d\n"
                             matcher query (- (float-time) started) (* 1000 max-tick)
                             (length (neo-scope--state-matches s))))
              (let ((start (float-time)))
                (dotimes (_ 100) (neo-scope-next))
                (princ (format "MOVE100 seconds=%.3f\n" (- (float-time) start)))))
          (neo-scope--close s)))))
  (let* ((s (neo-scope--make-state :source '(:name "Typing") :done t :all items :matches []
                                  :input (generate-new-buffer "input")
                                  :candidates (generate-new-buffer "output")))
         (neo-scope-matcher #'neo-scope-fuzzy-match)
         (started (float-time)))
    (setq neo-scope--session s)
    (unwind-protect
        (progn
          (dolist (query '("n" "ne" "neo" "neo-" "neo-s" "neo-sc" "neo-sco" "neo-scop" "neo-scope"))
            (with-current-buffer (neo-scope--state-input s) (erase-buffer) (insert query))
            (neo-scope--query s)
            (while (or (neo-scope--state-pending s) (neo-scope--state-match-timer s))
              (neo-scope--cancel-timer (neo-scope--state-match-timer s))
              (neo-scope--match-batch s)))
          (princ (format "TYPE-SEQUENCE seconds=%.3f matches=%d\n" (- (float-time) started)
                         (length (neo-scope--state-matches s)))))
      (neo-scope--close s)))
  (let* ((candidate (neo-scope--file-candidate (expand-file-name "neo-scope.el") default-directory))
         (buffer (generate-new-buffer " *scope-perf-preview*")))
    (unwind-protect
        (princ (format "PREVIEW10=%S\n" (benchmark-run 10 (neo-scope-preview candidate buffer))))
      (kill-buffer buffer))))
