;;; neo-scope-grep-benchmark.el --- Search responsiveness measurement -*- lexical-binding: t; -*-
(require 'neo-scope)
(require 'cl-lib)

(defun neo-scope-grep-benchmark (root query)
  "Measure one search of ROOT for QUERY without visiting files."
  (let* ((started (float-time)) (last started) (gap 0.0)
         first done failure items cancel)
    (unwind-protect
        (progn
          (setq cancel
                (funcall (plist-get (neo-scope-file-source root t) :start) query
                         (lambda (event payload)
                           (pcase event
                             ('add (unless first (setq first (- (float-time) started)))
                                   (setq items (nconc items payload)))
                             ('done (setq done t))
                             ('error (setq failure payload done t))))))
          (while (and (not done) (< (- (float-time) started) 30))
            (accept-process-output nil 0.001)
            (let ((now (float-time)))
              (setq gap (max gap (- now last)) last now)))
          (unless done (error "Search timed out"))
          (when failure (error "%s" failure))
          (princ (format "query=%S count=%d first_ms=%.2f total_ms=%.2f max_wait_ms=%.2f sha256=%s\n"
                         query (length items) (* 1000 (or first 0))
                         (* 1000 (- (float-time) started)) (* 1000 gap)
                         (secure-hash 'sha256 (prin1-to-string items)))))
      (when cancel (funcall cancel)))))

;; Load this file, then call `neo-scope-grep-benchmark' with an explicit root/query.
;; Exclude build when measuring this checkout so logs do not alter the corpus.
