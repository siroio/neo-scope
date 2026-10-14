;;; neo-scope.el --- Standalone floating fuzzy finder -*- lexical-binding: t; -*-

;; Copyright (C) 2026 neo-scope contributors
;; Author: neo-scope contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: convenience, files, matching
;; URL: https://github.com/siroio/neo-scope
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A dependency-free graphical finder.  See `neo-scope-open' for the source
;; protocol and `neo-scope-fuzzy-match' for the replaceable matching contract.

;;; Code:
(require 'cl-lib)
(require 'project)
(require 'subr-x)

(defgroup neo-scope nil "Floating fuzzy finder." :group 'convenience)
(defcustom neo-scope-frame-ratio 0.9 "Size relative to the parent frame."
  :type 'float)
(defcustom neo-scope-list-ratio 0.4 "Fraction of width used for candidates."
  :type 'float)
(defcustom neo-scope-excluded-directories '(".git" ".hg" ".svn" "node_modules")
  "Directory basenames omitted by built-in sources." :type '(repeat string))
(defcustom neo-scope-max-file-size (* 1024 1024)
  "Maximum bytes to read for grep and preview." :type 'integer)
(defcustom neo-scope-max-results 10000 "Maximum candidates per session."
  :type 'integer)
(defcustom neo-scope-batch-size 200 "Maximum entries processed per timer tick."
  :type 'integer)
(defcustom neo-scope-input-delay 0.08 "Seconds before processing changed input."
  :type 'number)
(defcustom neo-scope-preview-delay 0.08 "Seconds before previewing selection."
  :type 'number)
(defcustom neo-scope-matcher #'neo-scope-fuzzy-match
  "Function accepting QUERY and candidate, returning (SCORE . POSITIONS) or nil.
POSITIONS are zero-based character offsets in the candidate's :match string."
  :type 'function)
(defcustom neo-scope-file-source-function #'neo-scope-file-source
  "Factory accepting ROOT and optional GREP and returning a source plist."
  :type 'function)
(defface neo-scope-selection '((t :inherit highlight)) "Selected candidate.")
(defface neo-scope-match '((t :inherit match)) "Matched characters.")
(defface neo-scope-title '((t :inherit font-lock-keyword-face :weight bold))
  "Panel titles.")

(defvar neo-scope-history nil "Queries entered in neo-scope.")
(defvar neo-scope--session nil)
(defvar neo-scope-input-map)
(defvar-local neo-scope--owner nil)
(cl-defstruct (neo-scope--state (:constructor neo-scope--make-state))
  source parent origin frame input candidates preview list-window preview-window
  input-window (generation 0) (query "") cancel query-timer match-timer
  preview-timer all tail ids pending ranked matches (selection 0)
  (revision 0) (history-index -1) (draft "") status done closed)

(defun neo-scope-fuzzy-match (query candidate)
  "Match QUERY against CANDIDATE, returning (SCORE . POSITIONS), or nil.
CANDIDATE is a plist with :id, :label, :match and :value.  Matching is a
case-insensitive subsequence; contiguous and boundary matches score higher."
  (let* ((text (downcase (or (plist-get candidate :match)
                             (plist-get candidate :label))))
         (query (downcase query)) (at 0) (last -2) (score 0) positions
         (base (or (cl-position ?/ text :from-end t) -1)))
    (catch 'miss
      (dotimes (i (length query))
        (let ((pos (cl-position (aref query i) text :start at)))
          (unless pos (throw 'miss nil))
          (setq score (+ score 10
                         (if (= pos (1+ last)) 14 0)
                         (if (or (= pos 0)
                                 (memq (aref text (1- pos)) '(?/ ?\\ ?- ?_ ?\s ?.))) 10 0)
                         (if (> pos base) 4 0)
                         (- (- pos at))))
          (push pos positions)
          (setq last pos at (1+ pos))))
      (cons score (nreverse positions)))))

(defun neo-scope--local-root (root)
  "Validate ROOT and return its absolute directory name."
  (when (file-remote-p root) (user-error "neo-scope supports local directories only"))
  (unless (file-directory-p root) (user-error "Not a directory: %s" root))
  (file-name-as-directory (expand-file-name root)))

(defun neo-scope-literal-match (query candidate)
  "Return all literal QUERY match positions in CANDIDATE, without ranking."
  (if (string-empty-p query) '(0)
    (let ((text (or (plist-get candidate :match) (plist-get candidate :label)))
          (case-fold-search t) (start 0) positions)
      (while (string-match (regexp-quote query) text start)
        (let ((begin (match-beginning 0)) (end (match-end 0)))
          (cl-loop for i from begin below end do (push i positions))
          (setq start end)))
      (when positions (cons 0 (nreverse positions))))))

(defun neo-scope--root (choose)
  (neo-scope--local-root
   (if choose (read-directory-name "Search root: ")
     (if-let* ((project (project-current nil))) (project-root project)
       default-directory))))

(defun neo-scope--label (text)
  "Keep TEXT on one display line without changing its underlying value."
  (replace-regexp-in-string "[\n\r\t]"
                            (lambda (s) (pcase s ("\n" "\\n") ("\r" "\\r") (_ "\\t")))
                            text t t))

(defun neo-scope--file-candidate (file root &optional line text)
  (let ((label (concat (neo-scope--label (file-relative-name file root))
                       (when line (format ":%d: %s" line (neo-scope--label text))))))
    (list :id (if line (cons file line) file) :label label :match label
          :value (list :file file :line (or line 1)))))

(defun neo-scope--read-text (file)
  "Read bounded local FILE, rejecting binary, remote and oversized files."
  (when (file-remote-p file) (error "Remote preview is not supported"))
  (let ((attrs (file-attributes file)))
    (unless (and attrs (not (eq t (file-attribute-type attrs))))
      (error "File is unavailable"))
    (when (> (file-attribute-size attrs) neo-scope-max-file-size)
      (error "File exceeds %d bytes" neo-scope-max-file-size)))
  (with-temp-buffer
    ;; The extra byte also catches a file that grows after the stat call.
    (insert-file-contents file nil 0 (1+ neo-scope-max-file-size))
    (when (> (buffer-size) neo-scope-max-file-size) (error "File is too large"))
    (goto-char (point-min))
    (when (search-forward "\0" nil t) (error "Binary file"))
    (buffer-string)))

(defun neo-scope-file-source (root &optional grep)
  "Return a batched local file source for ROOT.
If GREP is non-nil, search literal QUERY case-insensitively in text files.
Symlinks and `neo-scope-excluded-directories' are skipped.  Git ignore
files are not interpreted.  No external executable is required."
  (setq root (neo-scope--local-root root))
  (list
   :name (if grep "Search text" "Find files") :query-dependent grep
   :matcher (when grep #'neo-scope-literal-match)
   :start
   (lambda (query emit)
     (let ((queue (list root)) timer stopped (count 0) (skipped 0) limited)
       (cl-labels
           ((finish ()
              (setq stopped t)
              (funcall emit 'status (concat (when limited "Result limit reached. ")
                                           (when (> skipped 0) (format "Skipped %d entries. " skipped))))
              (funcall emit 'done nil))
            (tick ()
              (unless stopped
                (condition-case err
                    (let ((budget (max 1 neo-scope-batch-size))
                          (deadline (+ (float-time) 0.008)) batch)
                      (while (and queue (> budget 0) (< (float-time) deadline)
                                  (< count neo-scope-max-results))
                        (let ((file (pop queue)))
                          (cl-decf budget)
                          (condition-case nil
                              (cond
                               ((file-symlink-p file) (cl-incf skipped))
                               ((file-directory-p file)
                                (unless (member (file-name-nondirectory (directory-file-name file))
                                                neo-scope-excluded-directories)
                                  (setq queue (nconc (directory-files file t directory-files-no-dot-files-regexp t) queue))))
                               ((not grep)
                                (push (neo-scope--file-candidate file root) batch)
                                (cl-incf count))
                               (t
                                (with-temp-buffer
                                  (insert (neo-scope--read-text file))
                                  (goto-char (point-min))
                                  (let ((case-fold-search t) (line 1) (previous (point-min)))
                                    (while (and (< count neo-scope-max-results)
                                                (search-forward query nil t))
                                      (let ((start (line-beginning-position)))
                                        (setq line (+ line (count-lines previous start)) previous start)
                                        (push (neo-scope--file-candidate
                                               file root line
                                               (buffer-substring-no-properties start (line-end-position))) batch)
                                        (cl-incf count)
                                        (forward-line 1)))))))
                            (error (cl-incf skipped)))))
                      (when batch (funcall emit 'add (nreverse batch)))
                      (setq limited (>= count neo-scope-max-results))
                      (if (or (null queue) limited) (finish)
                        (setq timer (run-at-time 0.01 nil #'tick))))
                  (error (setq stopped t) (funcall emit 'error (error-message-string err)))))))
         (if (and grep (string-empty-p query))
             (setq timer (run-at-time 0 nil (lambda () (unless stopped (finish)))))
           (setq timer (run-at-time 0 nil #'tick))))
       (lambda () (setq stopped t) (when (timerp timer) (cancel-timer timer)))))))

(defun neo-scope-buffer-source ()
  "Return a source for normal live buffers, preserving buffer-list order."
  (let ((buffers (cl-remove-if (lambda (b) (string-prefix-p " " (buffer-name b))) (buffer-list))))
    (list :name "Buffers"
          :start (lambda (_query emit)
                   (funcall emit 'add
                            (cl-loop for b in buffers when (buffer-live-p b)
                                     collect (list :id b :label (neo-scope--label (buffer-name b))
                                                   :match (neo-scope--label (buffer-name b))
                                                   :value (list :buffer b))))
                   (funcall emit 'done nil)
                   #'ignore))))

(defun neo-scope-preview (candidate buffer)
  "Render CANDIDATE in owned preview BUFFER without visiting a new file.
The source buffer's text, point and narrowing are never modified."
  (let* ((value (plist-get candidate :value)) (file (plist-get value :file))
         (source (or (plist-get value :buffer) (and file (get-file-buffer file))))
         (line (or (plist-get value :line) 1)) text mode)
    (if source
        (progn
          (unless (buffer-live-p source) (error "Buffer no longer exists"))
          (with-current-buffer source
            (save-restriction
              (widen)
              (when (> (buffer-size) neo-scope-max-file-size) (error "Buffer is too large"))
              (setq text (buffer-substring-no-properties (point-min) (point-max))
                    mode major-mode))))
      (setq text (neo-scope--read-text file)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (fundamental-mode)
        (erase-buffer)
        (insert text)
        ;; Standard syntax coloring without file visits, mode hooks, local variables,
        ;; or arbitrary auto-mode entries supplied by another package.
        (let* ((ext (and file (downcase (or (file-name-extension file) ""))))
               (safe-mode (or (and (memq mode '(emacs-lisp-mode lisp-mode c-mode c++-mode
                                                               python-mode js-mode sh-mode)) mode)
                              (cdr (assoc ext '(("el" . emacs-lisp-mode) ("c" . c-mode)
                                               ("h" . c-mode) ("cpp" . c++-mode)
                                               ("py" . python-mode) ("js" . js-mode)
                                               ("json" . js-mode) ("sh" . sh-mode)))))))
          (when safe-mode (delay-mode-hooks (funcall safe-mode)) (font-lock-ensure)))
        (setq-local buffer-read-only t truncate-lines t mode-line-format nil
                    header-line-format (propertize " Preview" 'face 'neo-scope-title))
        (use-local-map neo-scope-input-map)
        (goto-char (point-min)) (forward-line (1- line))
        (set-buffer-modified-p nil)))))

(defun neo-scope-action (candidate)
  "Visit CANDIDATE in the originating window after the finder has closed."
  (let* ((value (plist-get candidate :value)) (buffer (plist-get value :buffer))
         (file (plist-get value :file)))
    (cond
     (buffer (unless (buffer-live-p buffer) (user-error "Buffer no longer exists"))
             (switch-to-buffer buffer))
     (file (unless (file-exists-p file) (user-error "File no longer exists: %s" file))
           (find-file file)
           (goto-char (point-min)) (forward-line (1- (or (plist-get value :line) 1))))
     (t (user-error "Source must supply an :action for this candidate")))))

(defun neo-scope--live-p (s)
  (and (eq s neo-scope--session) (not (neo-scope--state-closed s))))

(defun neo-scope--cancel-timer (timer)
  (when (timerp timer) (cancel-timer timer)))

(defun neo-scope--emit (s generation event payload)
  (when (and (neo-scope--live-p s) (= generation (neo-scope--state-generation s)))
    (pcase event
      ('add
       (let (added)
         (dolist (candidate payload)
           (let ((id (plist-get candidate :id)))
             (when (and (< (hash-table-count (neo-scope--state-ids s)) neo-scope-max-results)
                        (not (gethash id (neo-scope--state-ids s))))
               (puthash id t (neo-scope--state-ids s))
               (push candidate added))))
         (setq added (nreverse added))
         (when added
           (if (neo-scope--state-tail s)
               (setcdr (neo-scope--state-tail s) added)
             (setf (neo-scope--state-all s) added))
           (setf (neo-scope--state-tail s) (last added))
           (setf (neo-scope--state-pending s)
                 (nconc (neo-scope--state-pending s) (copy-sequence added)))
           (neo-scope--schedule-match s))))
      ('status (setf (neo-scope--state-status s) payload))
      ('done (setf (neo-scope--state-done s) t))
      ('error (setf (neo-scope--state-done s) t
                    (neo-scope--state-status s) (concat "Error: " payload))))
    (neo-scope--render s)))

(defun neo-scope--start-source (s)
  (cl-incf (neo-scope--state-generation s))
  (when (neo-scope--state-cancel s) (funcall (neo-scope--state-cancel s)))
  (neo-scope--cancel-timer (neo-scope--state-match-timer s))
  (setf (neo-scope--state-cancel s) nil (neo-scope--state-all s) nil
        (neo-scope--state-tail s) nil (neo-scope--state-pending s) nil
        (neo-scope--state-ranked s) nil (neo-scope--state-matches s) []
        (neo-scope--state-selection s) 0 (neo-scope--state-done s) nil
        (neo-scope--state-match-timer s) nil (neo-scope--state-status s) ""
        (neo-scope--state-ids s) (make-hash-table :test 'equal))
  (let ((generation (neo-scope--state-generation s)))
    (condition-case err
        (setf (neo-scope--state-cancel s)
              (funcall (plist-get (neo-scope--state-source s) :start)
                       (neo-scope--state-query s)
                       (lambda (event payload) (neo-scope--emit s generation event payload))))
      (error (neo-scope--emit s generation 'error (error-message-string err))))))

(defun neo-scope--schedule-match (s)
  (unless (neo-scope--state-match-timer s)
    (setf (neo-scope--state-match-timer s) (run-at-time 0.01 nil #'neo-scope--match-batch s))))

(defun neo-scope--match-batch (s)
  (when (neo-scope--live-p s)
    (setf (neo-scope--state-match-timer s) nil)
    (condition-case err
        (let ((n (max 1 neo-scope-batch-size))
              (matcher (or (plist-get (neo-scope--state-source s) :matcher) neo-scope-matcher)) batch)
          (while (and (> n 0) (neo-scope--state-pending s))
            (let* ((candidate (pop (neo-scope--state-pending s)))
                   (match (funcall matcher (neo-scope--state-query s) candidate)))
              (when match (push (cons candidate match) batch)))
            (cl-decf n))
          (when batch
            (setf (neo-scope--state-ranked s)
                  (cl-merge 'list (neo-scope--state-ranked s)
                            (cl-stable-sort (nreverse batch) #'> :key #'cadr)
                            #'> :key #'cadr)
                  (neo-scope--state-matches s) (vconcat (neo-scope--state-ranked s))))
          (neo-scope--render s)
          (neo-scope--schedule-preview s)
          (when (neo-scope--state-pending s) (neo-scope--schedule-match s)))
      (error (setf (neo-scope--state-status s) (error-message-string err))
             (neo-scope--render s)))))

(defun neo-scope--input-changed (&rest _)
  (let ((s neo-scope--owner))
    (when (and s (neo-scope--live-p s))
      ;; Invalidate old selection immediately; RET must never open stale results.
      (cl-incf (neo-scope--state-revision s))
      (neo-scope--cancel-timer (neo-scope--state-query-timer s))
      (setf (neo-scope--state-query-timer s)
            (run-at-time neo-scope-input-delay nil #'neo-scope--query s)))))

(defun neo-scope--query (s)
  (when (and (neo-scope--live-p s) (buffer-live-p (neo-scope--state-input s)))
    (setf (neo-scope--state-query-timer s) nil)
    (let ((query (with-current-buffer (neo-scope--state-input s)
                   (buffer-substring-no-properties (point-min) (point-max)))))
      (unless (equal query (neo-scope--state-query s))
        (setf (neo-scope--state-query s) query (neo-scope--state-selection s) 0)
        (neo-scope--cancel-timer (neo-scope--state-preview-timer s))
        (if (plist-get (neo-scope--state-source s) :query-dependent)
            (neo-scope--start-source s)
          (neo-scope--cancel-timer (neo-scope--state-match-timer s))
          (setf (neo-scope--state-match-timer s) nil
                (neo-scope--state-ranked s) nil (neo-scope--state-matches s) []
                (neo-scope--state-pending s) (copy-sequence (neo-scope--state-all s)))
          (neo-scope--schedule-match s))
        (neo-scope--render s)
        (neo-scope--schedule-preview s)))))

(defun neo-scope--selected (s)
  (let ((matches (neo-scope--state-matches s)))
    (when (and matches (> (length matches) 0))
      (car (aref matches (min (neo-scope--state-selection s) (1- (length matches))))))))

(defun neo-scope--render (s)
  (when (buffer-live-p (neo-scope--state-candidates s))
    (let* ((matches (neo-scope--state-matches s)) (total (length matches))
           (window (neo-scope--state-list-window s))
           (rows (max 1 (if (window-live-p window) (window-body-height window) 20)))
           (selected (min (neo-scope--state-selection s) (max 0 (1- total))))
           (start (max 0 (min (- total rows) (- selected (/ rows 2))))))
      (setf (neo-scope--state-selection s) selected)
      (with-current-buffer (neo-scope--state-candidates s)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (cl-loop for i from start below (min total (+ start rows))
                   for row = (aref matches i) for candidate = (car row)
                   do (let* ((begin (point))
                             (label (copy-sequence (plist-get candidate :label))))
                        (when (equal label (or (plist-get candidate :match) label))
                          (dolist (pos (cddr row))
                            (when (< pos (length label))
                              (add-face-text-property pos (1+ pos) 'neo-scope-match nil label))))
                        (insert (if (= i selected) "› " "  ") label "\n")
                        (when (= i selected)
                          (add-face-text-property begin (point) 'neo-scope-selection t))))
          (when (= total 0) (insert (if (neo-scope--state-done s) "  No results" "  Searching…")))
          (goto-char (point-min))
          (setq header-line-format
                (propertize (concat " " (plist-get (neo-scope--state-source s) :name)) 'face 'neo-scope-title))
          (set-buffer-modified-p nil)))
      (when (window-live-p window) (set-window-start window 1))
      (with-current-buffer (neo-scope--state-input s)
        (setq header-line-format
              (format " Search  %d/%d%s  %s" (if (> total 0) (1+ selected) 0) total
                      (if (or (not (neo-scope--state-done s)) (neo-scope--state-pending s)) " …" "")
                      (or (neo-scope--state-status s) "")))))))

(defun neo-scope--schedule-preview (s)
  (neo-scope--cancel-timer (neo-scope--state-preview-timer s))
  (let ((revision (neo-scope--state-revision s)))
    (setf (neo-scope--state-preview-timer s)
          (run-at-time neo-scope-preview-delay nil
                       (lambda ()
                         (when (and (neo-scope--live-p s)
                                    (= revision (neo-scope--state-revision s)))
                           (neo-scope--show-preview s)))))))

(defun neo-scope--show-preview (s)
  (let ((buffer (neo-scope--state-preview s)) (candidate (neo-scope--selected s)))
    (when (buffer-live-p buffer)
      (condition-case err
          (if candidate
              (funcall (or (plist-get (neo-scope--state-source s) :preview) #'neo-scope-preview)
                       candidate buffer)
            (with-current-buffer buffer (let ((inhibit-read-only t)) (erase-buffer))))
        (error (with-current-buffer buffer
                 (let ((inhibit-read-only t)) (erase-buffer) (insert (error-message-string err))))))
      (when (window-live-p (neo-scope--state-preview-window s))
        (with-current-buffer buffer
          (use-local-map neo-scope-input-map)
          (setq-local buffer-read-only t))
        (set-window-point (neo-scope--state-preview-window s) (with-current-buffer buffer (point)))
        (with-selected-window (neo-scope--state-preview-window s) (recenter))))))

(defun neo-scope-next (&optional delta)
  "Move DELTA candidates (one by default)."
  (interactive)
  (let ((s neo-scope--session))
    (when s
      (setf (neo-scope--state-selection s)
            (max 0 (min (max 0 (1- (length (neo-scope--state-matches s))))
                        (+ (neo-scope--state-selection s) (or delta 1)))))
      (neo-scope--render s) (neo-scope--schedule-preview s))))

(defun neo-scope-previous () "Move to the previous candidate." (interactive) (neo-scope-next -1))

(defun neo-scope-history-previous (&optional forward)
  "Insert the previous query, or the next query when FORWARD is non-nil."
  (interactive)
  (let* ((s neo-scope--session) (index (neo-scope--state-history-index s)))
    (select-window (neo-scope--state-input-window s))
    (with-current-buffer (neo-scope--state-input s)
      (when (= index -1) (setf (neo-scope--state-draft s) (buffer-string)))
      (setq index (max -1 (min (1- (length neo-scope-history)) (+ index (if forward -1 1)))))
      (setf (neo-scope--state-history-index s) index)
      (erase-buffer)
      (insert (if (< index 0) (neo-scope--state-draft s) (nth index neo-scope-history))))))

(defun neo-scope-history-next () "Insert the next query." (interactive) (neo-scope-history-previous t))

(defun neo-scope--close (s &optional no-focus)
  (unless (neo-scope--state-closed s)
    (setf (neo-scope--state-closed s) t)
    (when (eq s neo-scope--session) (setq neo-scope--session nil))
    (dolist (timer (list (neo-scope--state-query-timer s) (neo-scope--state-match-timer s)
                        (neo-scope--state-preview-timer s))) (neo-scope--cancel-timer timer))
    (when (neo-scope--state-cancel s) (ignore-errors (funcall (neo-scope--state-cancel s))))
    (remove-hook 'delete-frame-functions #'neo-scope--frame-deleted)
    (remove-hook 'window-size-change-functions #'neo-scope--parent-resized)
    (when (buffer-live-p (neo-scope--state-input s))
      (let ((query (with-current-buffer (neo-scope--state-input s) (buffer-string))))
        (unless (string-empty-p query) (add-to-history 'neo-scope-history query))))
    (when (frame-live-p (neo-scope--state-frame s)) (delete-frame (neo-scope--state-frame s) t))
    (dolist (buffer (list (neo-scope--state-input s) (neo-scope--state-candidates s)
                          (neo-scope--state-preview s)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (set-buffer-modified-p nil)) (kill-buffer buffer)))
    (unless no-focus
      (when (frame-live-p (neo-scope--state-parent s))
        (select-frame-set-input-focus (neo-scope--state-parent s)))
      (when (window-live-p (neo-scope--state-origin s)) (select-window (neo-scope--state-origin s))))))

(defun neo-scope-cancel ()
  "Close neo-scope without visiting a candidate."
  (interactive) (when neo-scope--session (neo-scope--close neo-scope--session)))

(defun neo-scope-accept ()
  "Visit the selected candidate."
  (interactive)
  (let ((s neo-scope--session))
    (when s
      (if (or (neo-scope--state-query-timer s) (neo-scope--state-pending s))
          (message "neo-scope: wait for the current query")
        (when-let* ((candidate (neo-scope--selected s)))
          (let ((action (or (plist-get (neo-scope--state-source s) :action) #'neo-scope-action)))
            (neo-scope--close s)
            (funcall action candidate)))))))

(defvar neo-scope-input-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-n") #'neo-scope-next)
    (define-key map (kbd "C-p") #'neo-scope-previous)
    (define-key map (kbd "<down>") #'neo-scope-next)
    (define-key map (kbd "<up>") #'neo-scope-previous)
    (define-key map (kbd "RET") #'neo-scope-accept)
    (define-key map (kbd "C-g") #'neo-scope-cancel)
    (define-key map (kbd "<escape>") #'neo-scope-cancel)
    (define-key map (kbd "M-p") #'neo-scope-history-previous)
    (define-key map (kbd "M-n") #'neo-scope-history-next)
    map)
  "Keymap for the query buffer; unbound keys retain normal Emacs editing.")

(defun neo-scope--frame-deleted (frame)
  (when-let* ((s neo-scope--session))
    (when (memq frame (list (neo-scope--state-frame s) (neo-scope--state-parent s)))
      ;; Avoid recursively deleting a frame already being destroyed.
      (when (eq frame (neo-scope--state-frame s)) (setf (neo-scope--state-frame s) nil))
      (neo-scope--close s t))))

(defun neo-scope--dimensions (parent)
  (let ((ratio (max 0.2 (min 1.0 neo-scope-frame-ratio))))
    (cons (max 1 (floor (* ratio (frame-width parent))))
          (max 1 (floor (* ratio (frame-height parent)))))))

(defun neo-scope--parent-resized (parent)
  (when-let* ((s neo-scope--session))
    (when (and (eq parent (neo-scope--state-parent s))
               (frame-live-p (neo-scope--state-frame s)))
      (let ((size (neo-scope--dimensions parent)))
        (if (or (< (car size) 30) (< (cdr size) 8)) (neo-scope--close s)
          (set-frame-size (neo-scope--state-frame s) (car size) (cdr size))
          (modify-frame-parameters (neo-scope--state-frame s) '((left . 0.5) (top . 0.5)))
          (neo-scope--render s))))))

;;;###autoload
(defun neo-scope-open (source)
  "Open floating SOURCE, a plist with :name and :start.
:start is called with (QUERY EMIT) and returns a cancellation function.
EMIT accepts (EVENT PAYLOAD): add supplies a list of candidate plists;
done finishes enumeration; status and error supply a string.  Candidates
have :id (stable unique value), :label, :match and :value.  Optional keys:
:query-dependent restarts enumeration on input; :matcher overrides
`neo-scope-matcher'; :preview takes (CANDIDATE BUFFER); :action takes
CANDIDATE after closing.  Late callbacks after cancellation are ignored."
  (unless (display-graphic-p) (user-error "neo-scope requires graphical Emacs"))
  (unless (and (stringp (plist-get source :name)) (functionp (plist-get source :start)))
    (user-error "Source needs :name and :start"))
  (when neo-scope--session (neo-scope--close neo-scope--session))
  (let* ((parent (selected-frame)) (size (neo-scope--dimensions parent))
         (s (neo-scope--make-state :source source :parent parent :origin (selected-window))))
    (when (or (< (car size) 30) (< (cdr size) 8)) (user-error "Frame is too small for neo-scope"))
    (setq neo-scope--session s)
    (condition-case err
        (progn
          (setf (neo-scope--state-input s) (generate-new-buffer " *neo-scope-input*")
                (neo-scope--state-candidates s) (generate-new-buffer " *neo-scope-candidates*")
                (neo-scope--state-preview s) (generate-new-buffer " *neo-scope-preview*"))
          (dolist (buffer (list (neo-scope--state-input s) (neo-scope--state-candidates s)
                                (neo-scope--state-preview s)))
            (with-current-buffer buffer
              (setq-local mode-line-format nil truncate-lines t cursor-type nil
                          header-line-format " " buffer-read-only t)
              (use-local-map neo-scope-input-map)))
          (with-current-buffer (neo-scope--state-input s)
            (setq-local buffer-read-only nil cursor-type 'bar neo-scope--owner s)
            (use-local-map neo-scope-input-map)
            (add-hook 'after-change-functions #'neo-scope--input-changed nil t))
          (setf (neo-scope--state-frame s)
                (make-frame `((parent-frame . ,parent) (minibuffer . nil)
                              (name . "neo-scope") (undecorated . t) (visibility . nil)
                              (width . ,(car size)) (height . ,(cdr size))
                              (left . 0.5) (top . 0.5) (internal-border-width . 1)
                              (menu-bar-lines . 0) (tool-bar-lines . 0) (tab-bar-lines . 0)
                              (vertical-scroll-bars . nil) (horizontal-scroll-bars . nil)
                              (no-other-frame . t) (desktop-dont-save . t))))
          (with-selected-frame (neo-scope--state-frame s)
            (delete-other-windows)
            (let* ((left (selected-window))
                   (right (split-window left (max 12 (floor (* (car size)
                                                              (max 0.2 (min 0.8 neo-scope-list-ratio))))) 'right))
                   (input (split-window left (- (window-total-height left) 3) 'below)))
              (setf (neo-scope--state-list-window s) left
                    (neo-scope--state-preview-window s) right
                    (neo-scope--state-input-window s) input)
              (set-window-buffer left (neo-scope--state-candidates s))
              (set-window-buffer right (neo-scope--state-preview s))
              (set-window-buffer input (neo-scope--state-input s))
              (set-window-parameter input 'window-size-fixed 'height)
              (select-window input)))
          (add-hook 'delete-frame-functions #'neo-scope--frame-deleted)
          (add-hook 'window-size-change-functions #'neo-scope--parent-resized)
          (make-frame-visible (neo-scope--state-frame s))
          (select-frame-set-input-focus (neo-scope--state-frame s))
          (neo-scope--start-source s)
          (neo-scope--render s)
          s)
      ((error quit) (neo-scope--close s) (signal (car err) (cdr err))))))

;;;###autoload
(defun neo-scope-find-file (&optional choose)
  "Find a project file.  With prefix CHOOSE, prompt for a root directory."
  (interactive "P")
  (neo-scope-open (funcall neo-scope-file-source-function (neo-scope--root choose))))

;;;###autoload
(defun neo-scope-buffer () "Select a live buffer." (interactive)
  (neo-scope-open (neo-scope-buffer-source)))

;;;###autoload
(defun neo-scope-grep (&optional choose)
  "Search literal text in the project.  With prefix CHOOSE, choose a root."
  (interactive "P")
  (neo-scope-open (funcall neo-scope-file-source-function (neo-scope--root choose) t)))

(provide 'neo-scope)
;;; neo-scope.el ends here
