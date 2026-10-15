;;; neo-scope-responsive-tests.el --- Responsiveness regressions -*- lexical-binding: t; -*-
(require 'ert)
(require 'neo-scope)

(ert-deftest neo-scope-fuzzy-whitespace-separates-unordered-words ()
  (let ((c '(:id 1 :label "neo-scope.el")))
    (dolist (query '("neo scope" "scope neo" "  neo   scope " "scope　neo" "neo\tscope"))
      (should (equal (neo-scope-fuzzy-match query c) (neo-scope-fuzzy-match "neo scope" c)))
      (should (equal (neo-scope--match-candidates query (list c) #'neo-scope-fuzzy-match)
                     (neo-scope--match-candidates "neo scope" (list c) #'neo-scope-fuzzy-match))))
    (should (equal (neo-scope--match-candidates " 　\t" (list c) #'neo-scope-fuzzy-match)
                   (list (cons c '(0)))))))

(ert-deftest neo-scope-fuzzy-completion-ignores-spaces ()
  (let* ((completion-styles '(neo-scope-fuzzy))
         (completion-styles-alist
          (cons '(neo-scope-fuzzy
                  (lambda (string _table _pred point) (cons string point))
                  neo-scope--fuzzy-completions "Fuzzy") completion-styles-alist))
         (result (completion-all-completions "scope neo" '("neo-scope.el" "other.el") nil 9)))
    (should (equal (substring-no-properties (car result)) "neo-scope.el"))
    (should (equal (cdr result) 0))))

(ert-deftest neo-scope-fuzzy-original-scores-preserved ()
  (dolist (example '(("ab" "dir/alpha-beta.el" (39 4 10))
                     ("日本" "設定/日本語.el" (49 3 4))
                     ("aa" "a/a_a" (43 0 2))
                     ("z" "abc" nil)
                     ("a.b" "root/a.b.el" (85 5 6 7))))
    (should (equal (neo-scope-fuzzy-match (car example) (list :label (cadr example)))
                   (nth 2 example)))))

(ert-deftest neo-scope-query-extension-keeps-full-ranking ()
  (let* ((items '((:id 1 :label "ab") (:id 2 :label "a-b") (:id 3 :label "xb")
                 (:id 4 :label "日本") (:id 5 :label "alpha-beta") (:id 6 :label "ab")))
         (neo-scope-matcher #'neo-scope-fuzzy-match)
         (s (neo-scope--make-state :source '(:name "Test") :done t :all items :matches []
                                  :input (generate-new-buffer "input")
                                  :candidates (generate-new-buffer "output"))))
    (setq neo-scope--session s)
    (unwind-protect
        (dolist (query '("a" "ab" "a b" "b a" "b ab" "a　b" "a " "ab" "a" "z" "" "日" "本 日" "日本"))
          (with-current-buffer (neo-scope--state-input s) (erase-buffer) (insert query))
          (neo-scope--query s)
          (while (neo-scope--state-pending s)
            (neo-scope--cancel-timer (neo-scope--state-match-timer s))
            (neo-scope--match-batch s))
          (let ((expected (cl-stable-sort
                           (neo-scope--match-candidates query items #'neo-scope-fuzzy-match)
                           #'> :key #'cadr)))
            (should (equal (neo-scope--state-matches s) (vconcat expected)))))
      (neo-scope--close s))))

(ert-deftest neo-scope-name-first-retains-path-and-match-faces ()
  (let* ((c (neo-scope--file-candidate (expand-file-name "src/neo-scope.el") default-directory 12 "code/path"))
         (display (neo-scope--candidate-label c '(0 1 2))))
    (should (equal (substring-no-properties display) "neo-scope.el:12: code/path  src/"))
    (should (memq 'neo-scope-filename (ensure-list (get-text-property 0 'face display))))
    (should (memq 'neo-scope-match (get-text-property (- (length display) 4) 'face display)))
    (should (equal (plist-get c :label) "src/neo-scope.el:12: code/path"))))

(ert-deftest neo-scope-compact-preview-details-toggle ()
  (let* ((source (generate-new-buffer "code")) (preview (generate-new-buffer "preview"))
         (c (list :id 1 :label "code" :value (list :buffer source :line 2)))
         (s (neo-scope--make-state :preview preview :matches (vector (cons c '(0))))))
    (setq neo-scope--session s)
    (unwind-protect
        (progn
          (with-current-buffer source (insert "first\nsecond\n"))
          (with-current-buffer preview (setq neo-scope--owner s neo-scope--details nil))
          (neo-scope--show-preview s)
          (with-current-buffer preview (should-not (string-match-p "General" (buffer-string))))
          (neo-scope-toggle-details)
          (with-current-buffer preview
            (should (string-match-p "General" (buffer-string)))
            (should (looking-at "second")))
          (neo-scope-toggle-details)
          (with-current-buffer preview
            (should-not (string-match-p "General" (buffer-string)))
            (should (looking-at "second"))))
      (neo-scope--close s) (kill-buffer source))))

(ert-deftest neo-scope-grep-unordered-words ()
  (let ((root (make-temp-file "scope-words" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "words.txt" root)
            (insert "scope first neo\nneo then scope\nneo only\n"))
          (let ((candidates (neo-scope--collect (neo-scope-file-source root t) "neo　scope")))
            (should (= 2 (length candidates)))
            (dolist (c candidates) (should (neo-scope-literal-match "scope neo" c)))))
      (delete-directory root t))))

(ert-deftest neo-scope-status-change-does-not-rewrite-candidates ()
  (let ((s (neo-scope--make-state :source '(:name "Test") :done t :matches []
                                 :input (generate-new-buffer "input")
                                 :candidates (generate-new-buffer "output"))))
    (unwind-protect
        (progn
          (neo-scope--render s)
          (let ((tick (buffer-chars-modified-tick (neo-scope--state-candidates s))))
            (setf (neo-scope--state-status s) "running")
            (neo-scope--render s)
            (should (= tick (buffer-chars-modified-tick (neo-scope--state-candidates s))))
            (with-current-buffer (neo-scope--state-input s)
              (should (string-match-p "running" header-line-format)))))
      (neo-scope--close s))))

(ert-deftest neo-scope-orderless-empty-custom-separator-preserved ()
  (require 'orderless)
  (let ((orderless-component-separator (lambda (_query) '("alpha")))
        (candidates '((:id 1 :label "alpha") (:id 2 :label "beta"))))
    (should (= 1 (length (neo-scope--match-candidates "" candidates #'neo-scope-orderless-match))))))

(ert-deftest neo-scope-colored-cache-reuses-and-invalidates ()
  (let ((source (generate-new-buffer "source")) (preview (generate-new-buffer "preview"))
        (calls 0) (original (symbol-function 'neo-scope--text-preview-uncached)))
    (unwind-protect
        (cl-letf (((symbol-function 'neo-scope--text-preview-uncached)
                   (lambda (&rest args) (cl-incf calls) (apply original args))))
          (with-current-buffer source (insert "first\nsecond\n"))
          (neo-scope-preview (list :value (list :buffer source :line 1)) preview)
          (neo-scope-preview (list :value (list :buffer source :line 2)) preview)
          (should (= calls 1))
          (with-current-buffer source (goto-char (point-max)) (insert "changed\n"))
          (neo-scope-preview (list :value (list :buffer source)) preview)
          (should (= calls 2))
          (with-current-buffer preview (should (string-match-p "changed" (buffer-string)))))
      (kill-buffer source) (kill-buffer preview))))

(ert-deftest neo-scope-orderless-batch-preserves-matches ()
  (require 'orderless)
  (let* ((candidates '((:id 1 :label "alpha beta") (:id 2 :label "alpha")
                       (:id 3 :label "alpha beta")))
         (individual (cl-loop for c in candidates for m = (neo-scope-orderless-match "beta alpha" c)
                              when m collect (cons c m))))
    (should (equal individual (neo-scope--match-candidates "beta alpha" candidates #'neo-scope-orderless-match)))))

(ert-deftest neo-scope-rg-matches-elisp-file-set ()
  (should (executable-find "rg"))
  (let ((root (make-temp-file "scope-files" t)))
    (unwind-protect
        (progn
          (dolist (dir '(".git" "node_modules" "sub")) (make-directory (expand-file-name dir root)))
          (dolist (file '(".hidden" "日本 name.el" ".git/ignore" "node_modules/ignore" "sub/file.txt"))
            (with-temp-file (expand-file-name file root) (insert "content")))
          (let ((fast (let ((neo-scope-use-ripgrep t)) (neo-scope--collect (neo-scope-file-source root) "")))
                (slow (let ((neo-scope-use-ripgrep nil)) (neo-scope--collect (neo-scope-file-source root) ""))))
            (should (equal (sort (mapcar (lambda (c) (plist-get c :id)) fast) #'string<)
                           (sort (mapcar (lambda (c) (plist-get c :id)) slow) #'string<)))))
      (delete-directory root t))))

(ert-deftest neo-scope-input-ret-queues-current-query ()
  (let* ((input (generate-new-buffer "input")) (output (generate-new-buffer "output")) chosen
         (s (neo-scope--make-state :source (list :name "Test" :action (lambda (c) (setq chosen (plist-get c :id))))
                                  :input input :candidates output :done t :query ""
                                  :all '((:id 1 :label "alpha") (:id 2 :label "beta")) :matches [])))
    (setq neo-scope--session s)
    (unwind-protect
        (progn
          (with-current-buffer input (setq neo-scope--owner s) (insert "beta"))
          (setf (neo-scope--state-query-timer s) (run-at-time 10 nil #'ignore))
          (neo-scope-accept)
          (should (neo-scope--state-accept-pending s))
          (neo-scope--match-batch s)
          (should (= chosen 2))
          (should-not neo-scope--session))
      (neo-scope--close s))))
