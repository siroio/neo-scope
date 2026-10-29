;;; neo-scope-grep-tests.el --- Cooperative grep contracts -*- lexical-binding: t; -*-
(require 'ert)
(require 'neo-scope)

(defmacro neo-scope-grep-test-with-files (&rest body)
  (declare (indent 0))
  `(let ((root (make-temp-file "scope-grep-" t)))
     (unwind-protect
         (progn
           (let ((coding-system-for-write 'utf-8-unix))
             (with-temp-file (expand-file-name "日本.txt" root)
               (insert "Alpha before BETA\nbeta then alpha\nalpha only\n")))
           ,@body)
       (delete-directory root t))))

(ert-deftest neo-scope-grep-yields-within-a-file-and-cancels ()
  (neo-scope-grep-test-with-files
    (with-temp-file (expand-file-name "日本.txt" root)
      (dotimes (_ 1000) (insert "alpha beta\n")))
    (let ((neo-scope-batch-size 10) callbacks events cancel
          (before (buffer-list)))
      (unwind-protect
          (cl-letf (((symbol-function 'run-at-time)
                     (lambda (_time _repeat fn &rest args)
                       (push (lambda () (apply fn args)) callbacks) nil))
                    ((symbol-function 'make-process)
                     (lambda (&rest _) (ert-fail "Unexpected search process"))))
            (setq cancel (funcall (plist-get (neo-scope-file-source root t) :start) "alpha"
                                  (lambda (event payload) (push (cons event payload) events))))
            (while (not (assq 'add events)) (funcall (pop callbacks)))
            (should (< (length (cdr (assq 'add events))) 1000))
            (should-not (assq 'done events))
            (funcall cancel)
            (let ((count (length events)))
              (mapc #'funcall callbacks)
              (should (= count (length events))))
            (should-not (cl-set-difference (buffer-list) before)))
        (when cancel (funcall cancel))))))

(ert-deftest neo-scope-grep-matches-original-results-and-settings ()
  (neo-scope-grep-test-with-files
    (let ((coding-system-for-write 'utf-16le-with-signature))
      (with-temp-file (expand-file-name ".utf16.txt" root) (insert "ALPHA 日本 BETA\n")))
    (let ((coding-system-for-write 'japanese-shift-jis))
      (with-temp-file (expand-file-name "legacy.txt" root) (insert "alpha 日本 beta\n")))
    (make-directory (expand-file-name "excluded" root))
    (with-temp-file (expand-file-name "excluded/skip.txt" root) (insert "alpha beta\n"))
    (with-temp-file (expand-file-name "binary" root) (insert "alpha beta\0\n"))
    (let ((neo-scope-excluded-directories '("excluded"))
          (file-coding-system-alist (cons '("legacy\\.txt\\'" . japanese-shift-jis)
                                         file-coding-system-alist)))
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest _) (ert-fail "Unexpected search process")))
                ((symbol-function 'neo-scope-literal-match)
                 (lambda (&rest _) (ert-fail "Search must not build highlight positions"))))
        (let ((items (neo-scope--collect (neo-scope-file-source root t) "alpha　beta")))
          (should (equal (sort (mapcar (lambda (c)
                                        (cons (file-name-nondirectory (plist-get (plist-get c :value) :file))
                                              (plist-get (plist-get c :value) :line))) items)
                              (lambda (a b) (string< (car a) (car b))))
                         '((".utf16.txt" . 1) ("legacy.txt" . 1) ("日本.txt" . 1) ("日本.txt" . 2)))))
        (should (= 2 (length (neo-scope--collect (neo-scope-file-source root t) "日本"))))
        (should-not (neo-scope--collect (neo-scope-file-source root t) "no-match")))
      (let ((neo-scope-max-results 1))
        (should (= 1 (length (neo-scope--collect (neo-scope-file-source root t) "alpha"))))))))

(ert-deftest neo-scope-grep-cancel-before-start-suppresses-callbacks ()
  (neo-scope-grep-test-with-files
    (let (events)
      (let ((cancel (funcall (plist-get (neo-scope-file-source root t) :start) "alpha"
                             (lambda (&rest event) (push event events)))))
        (funcall cancel)
        (accept-process-output nil 0.05)
        (should-not events)))))

(ert-deftest neo-scope-grep-empty-query-does-not-start-a-process ()
  (neo-scope-grep-test-with-files
    (cl-letf (((symbol-function 'make-process) (lambda (&rest _) (ert-fail "Unexpected process"))))
      (should-not (neo-scope--collect (neo-scope-file-source root t) "　 \t")))))
