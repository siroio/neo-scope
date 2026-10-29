;;; neo-scope-embark-tests.el --- Embark handoff contracts -*- lexical-binding: t; -*-
(require 'ert)
(require 'neo-scope)
(require 'embark)
(require 'consult)
(require 'embark-consult)
(require 'neo-scope-embark nil t)

(ert-deftest neo-scope-embark-is-an-optional-integration ()
  (should (fboundp 'neo-scope-embark-setup)))

(ert-deftest neo-scope-embark-rejects-invalid-targets-before-opening ()
  (cl-letf (((symbol-function 'neo-scope-open) (lambda (_) (ert-fail "Unexpected finder"))))
    (let ((neo-scope-embark--type 'file))
      (should-error (neo-scope-embark nil) :type 'user-error)
      (should-error (neo-scope-embark '("/ssh:example:/missing")) :type 'user-error)
      (should-error (neo-scope-embark (list (expand-file-name "nonexistent" temporary-file-directory))) :type 'user-error))
    (let ((neo-scope-embark--type 'consult-grep))
      (should-error (neo-scope-embark '("file:2:plain text")) :type 'user-error))
    (let ((neo-scope-embark--type 'consult-location))
      (should-error (neo-scope-embark '("dead")) :type 'user-error))))

(ert-deftest neo-scope-embark-setup-is-idempotent-and-preserves-other-actions ()
  (let ((embark-general-map (make-sparse-keymap))
        (embark-multitarget-actions (copy-sequence embark-multitarget-actions))
        (embark-around-action-hooks (copy-tree embark-around-action-hooks))
        (embark-quit-after-action nil))
    (neo-scope-embark-setup)
    (neo-scope-embark-setup)
    (should (= 1 (cl-count 'neo-scope-embark embark-multitarget-actions)))
    (should (= 1 (length (alist-get 'neo-scope-embark embark-around-action-hooks))))
    (should (embark--quit-p 'neo-scope-embark))
    (should-not (embark--quit-p 'find-file))
    (define-key embark-general-map (kbd "N") #'ignore)
    (should-error (neo-scope-embark-setup) :type 'user-error)
    (should (eq (lookup-key embark-general-map (kbd "N")) #'ignore))))

(ert-deftest neo-scope-embark-act-all-opens-the-candidate-set-once ()
  (let ((root (make-temp-file "scope-embark-" t))
        (embark-general-map (copy-keymap embark-general-map))
        (embark-multitarget-actions (copy-sequence embark-multitarget-actions))
        (embark-around-action-hooks (copy-tree embark-around-action-hooks))
        (embark-confirm-act-all nil) (embark-quit-after-action t)
        (exporters (copy-tree embark-exporters-alist)) source collected (opens 0))
    (unwind-protect
        (let ((default-directory root))
          (with-temp-file (expand-file-name "one.txt" root) (insert "one"))
          (with-temp-file (expand-file-name "two.txt" root) (insert "two"))
          (neo-scope-embark-setup)
          (let ((embark-candidate-collectors (list (lambda () '(file "two.txt" "one.txt")))))
            (cl-letf (((symbol-function 'embark--prompt) (lambda (&rest _) #'neo-scope-embark))
                      ((symbol-function 'neo-scope-open) (lambda (s) (setq source s opens (1+ opens)))))
              (embark-act-all)
              (sleep-for 0.02)))
          (should (= opens 1))
          (let ((items (neo-scope--collect source "")))
            (should (equal (mapcar (lambda (c) (file-name-nondirectory (plist-get (plist-get c :value) :file))) items)
                           '("two.txt" "one.txt"))))
          (save-window-excursion
            (let ((embark-candidate-collectors (list (lambda () '(file "two.txt" "one.txt")))))
              (setq collected (embark--collect "scope-collect-test")))
            (setq opens 0 source nil)
            (with-current-buffer collected
              (let ((embark-candidate-collectors '(embark-embark-collect-candidates)))
                (cl-letf (((symbol-function 'embark--prompt) (lambda (&rest _) #'neo-scope-embark))
                          ((symbol-function 'neo-scope-open) (lambda (s) (setq source s opens (1+ opens)))))
                  (embark-act-all)
                  (sleep-for 0.02))))
            (should (= opens 1))
            (should (= 2 (length (neo-scope--collect source "")))))
          (should (equal exporters embark-exporters-alist)))
      (when (buffer-live-p collected) (kill-buffer collected))
      (delete-directory root t))))

(ert-deftest neo-scope-embark-preserves-duplicate-locations-and-unsaved-point ()
  (let ((buffer (generate-new-buffer "scope-unsaved")) source)
    (unwind-protect
        (progn
          (with-current-buffer buffer (insert "same\nsame\n") (goto-char 1))
          (let ((first (propertize "same" 'consult-location (cons (with-current-buffer buffer (copy-marker 2)) 1)))
                (second (propertize "same" 'consult-location (cons (with-current-buffer buffer (copy-marker 7)) 2))))
            (cl-letf (((symbol-function 'neo-scope-open) (lambda (s) (setq source s))))
              (neo-scope-embark--around :type 'consult-location :run
                                       (lambda (&rest _) (neo-scope-embark (list first second))))
              (sleep-for 0.02)))
          (let ((items (neo-scope--collect source "")))
            (should (= (length items) 2))
            (should-not (equal (plist-get (car items) :id) (plist-get (cadr items) :id)))
            (with-current-buffer buffer (goto-char 1) (insert "new\n"))
            (save-window-excursion
              (funcall (plist-get source :action) (cadr items))
              (should (eq (current-buffer) buffer))
              (should (= (point) 11)))
            (should (buffer-modified-p buffer))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer)))))

(ert-deftest neo-scope-embark-grep-retains-file-line-and-match-column ()
  (let* ((root (make-temp-file "scope-embark-" t))
         (file (expand-file-name "日本 file.txt" root)) source visited)
    (unwind-protect
        (let ((default-directory root) (coding-system-for-write 'utf-8-unix))
          (with-temp-file file (insert "first\nprefix target\n"))
          (let ((target (concat (propertize "日本 file.txt" 'face 'consult-file) ":"
                                (propertize "2" 'face 'consult-line-number) ":prefix "
                                (propertize "target" 'face 'consult-highlight-match))))
            (cl-letf (((symbol-function 'neo-scope-open) (lambda (s) (setq source s))))
              (neo-scope-embark--around :type 'consult-grep :run
                                       (lambda (&rest _) (neo-scope-embark (list target))))
              (sleep-for 0.02)))
          (let ((item (car (neo-scope--collect source ""))))
            (should (equal (plist-get (plist-get item :value) :file) file))
            (should (= (plist-get (plist-get item :value) :line) 2))
            (save-window-excursion
              (funcall (plist-get source :action) item)
              (setq visited (current-buffer))
              (should (equal (buffer-file-name) file))
              (should (looking-at "target")))))
      (when (buffer-live-p visited) (kill-buffer visited))
      (delete-directory root t))))

(ert-deftest neo-scope-embark-mixed-candidates-do-not-drop-unsupported-entries ()
  (let ((buffer (generate-new-buffer "scope-mixed")) source)
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'neo-scope-open) (lambda (s) (setq source s))))
            (neo-scope-embark--around
             :type 'multi-category :run
             (lambda (&rest _)
               (neo-scope-embark (list (propertize "shown" 'multi-category (cons 'buffer (buffer-name buffer)))))))
            (sleep-for 0.02))
          (should (eq (plist-get (plist-get (car (neo-scope--collect source "")) :value) :buffer) buffer))
          (should-error
           (neo-scope-embark--around
            :type 'multi-category :run
            (lambda (&rest _)
              (neo-scope-embark (list (propertize "shown" 'multi-category (cons 'buffer (buffer-name buffer)))
                                      (propertize "bookmark" 'multi-category '(bookmark . "unsupported"))))))
           :type 'user-error))
      (kill-buffer buffer))))

(ert-deftest neo-scope-embark-real-consult-mixed-buffer-objects ()
  (let ((buffer (generate-new-buffer "scope-consult-mixed"))
        (file (make-temp-file "scope-mixed-")) source)
    (unwind-protect
        (progn
          (with-current-buffer buffer (insert "unsaved content") (goto-char 5))
          (let* ((candidates
                  (append (consult--multi-format 0 '(:category buffer)
                                                 (list (consult--buffer-pair buffer)))
                          (consult--multi-format 1 '(:category file) (list file))))
                 (embark-candidate-collectors (list (lambda () (cons 'multi-category candidates))))
                 (transformed (embark--maybe-transform-candidates)))
            (should (eq (plist-get transformed :type) 'multi-category))
            (cl-letf (((symbol-function 'neo-scope-open) (lambda (s) (setq source s))))
              (neo-scope-embark--around
               :type (plist-get transformed :type) :run
               (lambda (&rest _) (neo-scope-embark (plist-get transformed :candidates))))
              (sleep-for 0.02)))
          (let ((items (neo-scope--collect source "")))
            (should (= 2 (length items)))
            (should (eq (plist-get (plist-get (car items) :value) :buffer) buffer))
            (should (equal (plist-get (plist-get (cadr items) :value) :file) file))
            (should-not (get-file-buffer file))
            (save-window-excursion
              (funcall (plist-get source :action) (car items))
              (should (eq (current-buffer) buffer))
              (should (= (point) 5)))))
      (with-current-buffer buffer (set-buffer-modified-p nil))
      (kill-buffer buffer)
      (delete-file file))))
