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

(ert-deftest neo-scope-grep-unsaved-replaces-disk-and-visits-live-line ()
  (neo-scope-grep-test-with-files
    (let* ((create-lockfiles nil) (auto-save-default nil)
           (file (expand-file-name "日本.txt" root))
           (edited (find-file-noselect file))
           (preview (generate-new-buffer " *scope-test-preview*")))
      (unwind-protect
          (progn
            (with-current-buffer edited
              (erase-buffer) (insert "new heading\nline two\nalpha live\n")
              (goto-char 2) (narrow-to-region 1 3))
            (let ((neo-scope-grep-unsaved-buffers nil))
              (should (= 3 (length (neo-scope--collect (neo-scope-file-source root t) "alpha")))))
            (let* ((neo-scope-grep-unsaved-buffers t)
                   (hits (neo-scope--collect (neo-scope-file-source root t) "alpha"))
                   (hit (car hits)))
              (should (= 1 (length hits)))
              (should (equal (plist-get hit :id) (cons file 3)))
              (should (eq edited (plist-get (plist-get hit :value) :buffer)))
              (neo-scope-preview hit preview)
              (with-current-buffer preview (should (looking-at "alpha live")))
              (with-current-buffer edited (should (= 2 (point))) (should (buffer-narrowed-p)))
              (save-window-excursion
                (neo-scope-action hit)
                (should (eq (current-buffer) edited)) (should (looking-at "alpha live"))
                (insert "changed "))
              (should-error (neo-scope-action hit) :type 'user-error)
              (should-error (neo-scope-preview hit preview) :type 'user-error)
              (should (string-match-p "Alpha before" (neo-scope--read-text file)))))
        (with-current-buffer edited (set-buffer-modified-p nil)) (kill-buffer edited)
        (kill-buffer preview)))))

(ert-deftest neo-scope-grep-unsaved-includes-new-files-and-honors-filters ()
  (neo-scope-grep-test-with-files
    (let ((create-lockfiles nil) (auto-save-default nil) buffers
          (neo-scope-grep-unsaved-buffers t) (neo-scope-max-file-size 12)
          (neo-scope-excluded-directories '("ignored")))
      (unwind-protect
          (progn
            (make-directory (expand-file-name "ignored" root))
            (make-directory (expand-file-name "sub" root))
            (dolist (item '(("sub/new.txt" . "hit") ("ignored/new.txt" . "hit")
                            ("binary.txt" . "hit\0") ("large.txt" . "hit日本日本日本")))
              (let ((buffer (find-file-noselect (expand-file-name (car item) root))))
                (push buffer buffers) (with-current-buffer buffer (insert (cdr item)))))
            (let ((hits (neo-scope--collect (neo-scope-file-source root t) "hit")))
              (should (equal (mapcar (lambda (c) (plist-get c :id)) hits)
                             (list (cons (expand-file-name "sub/new.txt" root) 1)))))
            (should-not (file-exists-p (expand-file-name "sub/new.txt" root))))
        (dolist (buffer buffers)
          (with-current-buffer buffer (set-buffer-modified-p nil)) (kill-buffer buffer))))))

(ert-deftest neo-scope-grep-unsaved-finds-file-buffers-through-case-aliases ()
  (neo-scope-grep-test-with-files
    (skip-unless (file-name-case-insensitive-p root))
    (let ((create-lockfiles nil) (auto-save-default nil) buffers
          (neo-scope-grep-unsaved-buffers t))
      (unwind-protect
          (progn
            (make-directory (expand-file-name "MixedCase" root))
            (with-temp-file (expand-file-name "MixedCase/Disk.txt" root) (insert "old disk line"))
            (dolist (name '("mixedcase/disk.TXT" "MIXEDCASE/New.txt"))
              (let ((buffer (find-file-noselect (expand-file-name name root))))
                (push buffer buffers)
                (with-current-buffer buffer (erase-buffer) (insert "edited live line"))))
            (let ((hits (neo-scope--collect (neo-scope-file-source (upcase root) t) "edited live")))
              (should (= 2 (length hits)))
              (should-not (cl-set-difference buffers (mapcar (lambda (c) (plist-get (plist-get c :value) :buffer))
                                                              hits))))
            (should-not (neo-scope--collect (neo-scope-file-source (upcase root) t) "old disk")))
        (dolist (buffer buffers)
          (with-current-buffer buffer (set-buffer-modified-p nil)) (kill-buffer buffer))))))
