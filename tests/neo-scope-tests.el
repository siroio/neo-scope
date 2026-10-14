;;; neo-scope-tests.el --- Tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'neo-scope)
(defvar neo-scope-test-evaluated nil)

(defun neo-scope-test-candidate (text)
  (list :id text :label text :match text :value text))

(ert-deftest neo-scope-match-subsequence ()
  (should (equal (cdr (neo-scope-fuzzy-match "abc" (neo-scope-test-candidate "A_b_C"))) '(0 2 4)))
  (should-not (neo-scope-fuzzy-match "ca" (neo-scope-test-candidate "abc"))))

(ert-deftest neo-scope-match-japanese-and-empty ()
  (should (equal (cdr (neo-scope-fuzzy-match "日本" (neo-scope-test-candidate "日本語.el"))) '(0 1)))
  (should (equal (neo-scope-fuzzy-match "" (neo-scope-test-candidate "abc")) '(0))))

(ert-deftest neo-scope-match-ranks-contiguous ()
  (should (> (car (neo-scope-fuzzy-match "abc" (neo-scope-test-candidate "abc.el")))
             (car (neo-scope-fuzzy-match "abc" (neo-scope-test-candidate "a_b_c.el"))))))

(defun neo-scope-test-collect (source query)
  (let (items done status cancel)
    (unwind-protect
        (progn
          (setq cancel (funcall (plist-get source :start) query
                                (lambda (event payload)
                                  (pcase event
                                    ('add (setq items (append items payload)))
                                    ('status (setq status payload))
                                    ('error (error "%s" payload))
                                    ('done (setq done t))))))
          (let ((deadline (+ (float-time) 5)))
            (while (and (not done) (< (float-time) deadline)) (sleep-for 0.01)))
          (should done)
          (list items status))
      (when cancel (funcall cancel)))))

(ert-deftest neo-scope-source-files-and-literal-grep ()
  (let ((root (make-temp-file "scope" t)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".git" root))
          (with-temp-file (expand-file-name ".git/hidden" root) (insert "needle"))
          (with-temp-file (expand-file-name "日本.el" root) (insert "a.b\naxb\na.b\n"))
          (let ((files (car (neo-scope-test-collect (neo-scope-file-source root) "")))
                (hits (car (neo-scope-test-collect (neo-scope-file-source root t) "a.b"))))
            (should (= 1 (length files)))
            (should (= 2 (length hits)))
            (should (equal (mapcar (lambda (c) (plist-get (plist-get c :value) :line)) hits) '(1 3)))))
      (delete-directory root t))))

(ert-deftest neo-scope-source-limit-and-size ()
  (let ((root (make-temp-file "scope" t)) (neo-scope-max-results 1))
    (unwind-protect
        (progn
          (dotimes (i 3) (with-temp-file (expand-file-name (format "%d" i) root) (insert "needle")))
          (should (= 1 (length (car (neo-scope-test-collect (neo-scope-file-source root) "")))))
          (let* ((neo-scope-max-file-size 2)
                 (result (neo-scope-test-collect (neo-scope-file-source root t) "needle")))
            (should-not (car result))
            (should (string-match-p "Skipped" (cadr result)))))
      (delete-directory root t))))

(ert-deftest neo-scope-source-cancel ()
  (let (called)
    (let ((cancel (funcall (plist-get (neo-scope-file-source default-directory) :start)
                           "" (lambda (&rest _) (setq called t)))))
      (funcall cancel)
      (sleep-for 0.05)
      (should-not called))))

(ert-deftest neo-scope-stale-events ()
  (let* ((s (neo-scope--make-state :generation 2 :ids (make-hash-table :test 'equal)))
         (neo-scope--session s))
    (neo-scope--emit s 1 'add (list (neo-scope-test-candidate "old")))
    (should-not (neo-scope--state-all s))
    (setf (neo-scope--state-closed s) t)
    (neo-scope--emit s 2 'add (list (neo-scope-test-candidate "closed")))
    (should-not (neo-scope--state-all s))))

(ert-deftest neo-scope-preview-isolates-buffer ()
  (let ((source (generate-new-buffer "source")) (dest (generate-new-buffer "preview")))
    (unwind-protect
        (progn
          (with-current-buffer source (insert "first\nsecond\n") (goto-char 4) (narrow-to-region 2 5))
          (neo-scope-preview (list :value (list :buffer source)) dest)
          (with-current-buffer dest (should (string-suffix-p "first\nsecond\n" (buffer-string))))
          (with-current-buffer source (should (= (point) 4)) (should (= (point-min) 2))))
      (kill-buffer source) (kill-buffer dest))))

(ert-deftest neo-scope-preview-no-local-eval ()
  (let ((file (make-temp-file "scope" nil ".el")) (dest (generate-new-buffer "preview"))
        (neo-scope-test-evaluated nil))
    (unwind-protect
        (progn
          (with-temp-file file (insert ";; Local " "Variables:\n;; eval: (setq neo-scope-test-evaluated t)\n;; End:\n"))
          (neo-scope-preview (list :value (list :file file)) dest)
          (should-not neo-scope-test-evaluated)
          (should-not (get-file-buffer file)))
      (delete-file file) (kill-buffer dest))))

(ert-deftest neo-scope-no-gui-does-not-mutate ()
  (let ((before (current-window-configuration)))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil)))
      (should-error (neo-scope-open (list :name "test" :start #'ignore)) :type 'user-error))
    (should (compare-window-configurations before (current-window-configuration)))))

(ert-deftest neo-scope-literal-match-highlights ()
  (should (equal (neo-scope-literal-match "日本" (neo-scope-test-candidate "日本-日本")) '(0 0 1 3 4)))
  (should-not (neo-scope-literal-match "a.b" (neo-scope-test-candidate "axb"))))

(ert-deftest neo-scope-panel-keys-survive-preview ()
  (let ((source (generate-new-buffer "source")) (dest (generate-new-buffer "preview")))
    (unwind-protect
        (progn
          (with-current-buffer source (emacs-lisp-mode) (insert "(+ 1 2)"))
          (neo-scope-preview (list :value (list :buffer source)) dest)
          (with-current-buffer dest
            (should (eq (key-binding (kbd "RET")) #'neo-scope-accept))
            (should (eq (key-binding (kbd "C-g")) #'neo-scope-cancel))))
      (kill-buffer source) (kill-buffer dest))))

(ert-deftest neo-scope-display-keeps-path-value ()
  (let* ((path (expand-file-name "a\nb.el" temporary-file-directory))
         (candidate (neo-scope--file-candidate path temporary-file-directory)))
    (should-not (string-match-p "\n" (plist-get candidate :label)))
    (should (equal path (plist-get (plist-get candidate :value) :file)))))

(ert-deftest neo-scope-missing-target-is-not-created ()
  (let ((file (expand-file-name "neo-scope-does-not-exist" temporary-file-directory)))
    (should-error (neo-scope-action (list :value (list :file file))) :type 'user-error)
    (should-not (get-file-buffer file))))

(ert-deftest neo-scope-stable-order-and-duplicate-id ()
  (let* ((s (neo-scope--make-state :source (list :name "test" :matcher (lambda (&rest _) '(0)))
                                   :generation 1 :ids (make-hash-table :test 'equal)))
         (neo-scope--session s))
    (unwind-protect
        (progn
          (neo-scope--emit s 1 'add (mapcar #'neo-scope-test-candidate '("b" "a" "b")))
          (neo-scope--match-batch s)
          (neo-scope--emit s 1 'add (list (neo-scope-test-candidate "c")))
          (neo-scope--match-batch s)
          (should (equal (mapcar (lambda (row) (plist-get (car row) :id))
                                (append (neo-scope--state-matches s) nil)) '("b" "a" "c"))))
      (neo-scope--close s t))))

(ert-deftest neo-scope-preview-size-and-binary ()
  (let ((file (make-temp-file "scope")) (dest (generate-new-buffer "preview")))
    (unwind-protect
        (progn
          (with-temp-file file (insert "text\0binary"))
          (neo-scope-preview (list :value (list :file file)) dest)
          (with-current-buffer dest (should (string-match-p "Binary file" (buffer-string))))
          (let ((neo-scope-max-file-size 2))
            (should-error (neo-scope--read-text file))))
      (delete-file file) (kill-buffer dest))))
