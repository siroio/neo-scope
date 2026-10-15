;;; neo-scope-integration-tests.el --- Optional integrations -*- lexical-binding: t; -*-
(require 'ert)
(require 'neo-scope)

(ert-deftest neo-scope-orderless-real ()
  (require 'orderless)
  (let* ((orderless-matching-styles '(orderless-literal))
         (c '(:id 1 :label "alpha beta 日本" :match "alpha beta 日本")))
    (should (neo-scope-orderless-match "beta alpha" c))
    (should (neo-scope-orderless-match "beta　alpha" c))
    (should (neo-scope-orderless-match "日本 alpha" c))
    (should-not (neo-scope-orderless-match "alpha missing" c))
    (should (equal (cdr (neo-scope-orderless-match "beta" c)) '(6 7 8 9)))))

(ert-deftest neo-scope-orderless-fallback ()
  (cl-letf (((symbol-function 'require) (lambda (&rest _) nil)))
    (let ((candidate '(:label "abc.el")))
      (should (equal (neo-scope-orderless-match "ac" candidate)
                     (neo-scope-fuzzy-match "ac" candidate))))))

(ert-deftest neo-scope-consult-real ()
  (require 'consult)
  (should (executable-find "rg"))
  (let ((root (make-temp-file "scope-consult" t)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".git" root))
          (with-temp-file (expand-file-name "日本 file.txt" root)
            (insert "hello\nalpha beta\nalpha gamma\n"))
          (with-temp-file (expand-file-name ".gitignore" root) (insert "ignored.txt\n"))
          (with-temp-file (expand-file-name "ignored.txt" root) (insert "alpha beta\n"))
          (let* ((source (neo-scope-consult-file-source root t))
                 (candidates (neo-scope--collect source "alpha.*beta")))
            (should (equal (plist-get source :name) "Consult ripgrep"))
            (should (= 1 (length candidates)))
            (should (= 2 (plist-get (plist-get (car candidates) :value) :line)))
            (should (equal (plist-get (plist-get (car candidates) :value) :file)
                           (expand-file-name "日本 file.txt" root)))
            (should (= 1 (length (neo-scope--collect source "beta　alpha"))))
            (should-not (neo-scope--collect source "no-such-text"))))
      (delete-directory root t))))

(ert-deftest neo-scope-consult-fallback ()
  (cl-letf (((symbol-function 'require) (lambda (&rest _) nil)))
    (should (equal (plist-get (neo-scope-consult-file-source default-directory t) :name)
                   "Search text"))))

(ert-deftest neo-scope-consult-cancel ()
  (require 'consult)
  (let* ((source (neo-scope-consult-file-source default-directory t))
         (cancel (funcall (plist-get source :start) "neo-scope" #'ignore)))
    (funcall cancel)
    (should-not (cl-find-if (lambda (b) (string-prefix-p " *consult-async-stderr*" (buffer-name b)))
                           (buffer-list)))))

(ert-deftest neo-scope-consult-result-limit ()
  (let ((neo-scope-max-results 1))
    (should (= 1 (length (neo-scope--collect
                         (neo-scope-consult-file-source default-directory t) "defun"))))))

(ert-deftest neo-scope-collection-timeout-cancels ()
  (let ((neo-scope-collection-timeout 0) stopped)
    (should-error
     (neo-scope--collect (list :start (lambda (_query _emit) (lambda () (setq stopped t)))) "")
     :type 'user-error)
    (should stopped)))

(ert-deftest neo-scope-collection-error-cancels ()
  (let (stopped)
    (should-error
     (neo-scope--collect
      (list :start (lambda (_query emit)
                     (funcall emit 'error "failed") (lambda () (setq stopped t)))) "")
     :type 'user-error)
    (should stopped)))

(ert-deftest neo-scope-vertico-real-mode-and-duplicate-labels ()
  (require 'vertico)
  (let ((vertico-mode nil) chosen)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt table &rest _)
                 (should vertico-mode)
                 (run-hooks 'minibuffer-setup-hook)
                 (should (equal (all-completions "" table) '("same [1]" "same [2]")))
                 "same [2]")))
      (neo-scope-vertico-open
       (list :name "Test" :start (lambda (_q emit)
                                  (funcall emit 'add '((:id 1 :label "same") (:id 2 :label "same")))
                                  (funcall emit 'done nil) #'ignore)
             :action (lambda (c) (setq chosen (plist-get c :id)))))
      (should (= chosen 2))
      (should-not vertico-mode))))

(ert-deftest neo-scope-vertico-cancel-restores-mode ()
  (require 'vertico)
  (let ((vertico-mode nil))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (signal 'quit nil))))
      (should (eq 'quit
                  (condition-case nil
                      (neo-scope-vertico-open
                       (list :name "Test" :start (lambda (_q emit)
                                                  (funcall emit 'add '((:id 1 :label "one")))
                                                  (funcall emit 'done nil) #'ignore)))
                    (quit 'quit))))
      (should-not vertico-mode))))

(ert-deftest neo-scope-vertico-fallback ()
  (let ((source '(:name "Test")) captured)
    (cl-letf (((symbol-function 'require) (lambda (&rest _) nil))
              ((symbol-function 'neo-scope-open) (lambda (s) (setq captured s))))
      (neo-scope-vertico-open source)
      (should (eq captured source)))))
