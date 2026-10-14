;;; neo-scope.el --- Standalone fuzzy finder -*- lexical-binding: t; -*-

;; Copyright (C) 2026 neo-scope contributors
;; Author: neo-scope contributors
;; Version: 0.2.0
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
(require 'json)
(require 'image)

(defgroup neo-scope nil "Fuzzy finder." :group 'convenience)
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
(defcustom neo-scope-ffprobe-program "ffprobe"
  "Optional ffprobe executable for media metadata; nil disables probing."
  :type '(choice (const nil) string))
(defcustom neo-scope-probe-timeout 5 "Seconds allowed for one media probe."
  :type 'number)
(defcustom neo-scope-media-cache-size 64 "Maximum successful media results cached."
  :type 'integer)
(defcustom neo-scope-max-image-size (* 20 1024 1024)
  "Maximum image file bytes decoded for preview." :type 'integer)
(defvar neo-scope--media-cache (make-hash-table :test 'equal))
(defvar-local neo-scope--preview-cancel nil)
(defvar-local neo-scope--preview-token nil)
(put 'neo-scope--preview-cancel 'permanent-local t)
(put 'neo-scope--preview-token 'permanent-local t)
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
(defvar neo-scope-panel-map)
(defvar-local neo-scope--owner nil)
(put 'neo-scope--owner 'permanent-local t)
(put 'neo-scope--buffer-killed 'permanent-local-hook t)
(cl-defstruct (neo-scope--state (:constructor neo-scope--make-state))
  source parent origin frame window-config input candidates preview list-window preview-window
  input-window (generation 0) (query "") cancel query-timer match-timer
  preview-timer preview-key all tail ids pending ranked matches (selection 0)
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

(defun neo-scope--text-preview (candidate buffer)
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
        ;; Freeze the read-only snapshot's faces before adding metadata outside
        ;; this function.  Names containing quotes must not alter code syntax.
        (let ((colored-text (buffer-string)))
          (fundamental-mode)
          (erase-buffer)
          (insert colored-text))
        (setq-local buffer-read-only t truncate-lines t mode-line-format nil
                    header-line-format (propertize " Preview" 'face 'neo-scope-title))
        (use-local-map neo-scope-panel-map)
        (goto-char (point-min)) (forward-line (1- line))
        (set-buffer-modified-p nil)))))

(defun neo-scope--stop-preview (buffer)
  "Cancel only the probe owned by preview BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq neo-scope--preview-token nil)
      (when neo-scope--preview-cancel
        (funcall neo-scope--preview-cancel)
        (setq neo-scope--preview-cancel nil)))))

(defun neo-scope--preview-killed () (neo-scope--stop-preview (current-buffer)))

(defun neo-scope--field (name value)
  (format "  %-16s %s\n" (concat name ":")
          (if (or (null value) (equal value "") (equal value "N/A")) "Unknown" value)))

(defun neo-scope--heading (title)
  (concat (propertize title 'face 'neo-scope-title) "\n\n"))

(defun neo-scope--general-info (file source)
  (let ((attrs (and file (file-attributes file))))
    (concat (neo-scope--heading "General")
            (neo-scope--field "Name" (neo-scope--label
                                      (if file (file-name-nondirectory file) (buffer-name source))))
            (neo-scope--field "Path" (and file (neo-scope--label (expand-file-name file))))
            (neo-scope--field "Size" (if attrs (file-size-human-readable (file-attribute-size attrs) 'iec)
                                       (and source (with-current-buffer source
                                                     (file-size-human-readable (buffer-size) 'iec)))))
            (neo-scope--field "Modified" (and attrs (format-time-string "%Y-%m-%d %H:%M:%S"
                                                                                      (file-attribute-modification-time attrs))))
            (when (and source (buffer-modified-p source)) (neo-scope--field "Buffer" "Unsaved changes"))
            "\n")))

(defun neo-scope--number (value)
  (cond ((numberp value) value)
        ((and (stringp value) (string-match-p "\\`[0-9]+\\(?:\\.[0-9]+\\)?\\'" value))
         (string-to-number value))))

(defun neo-scope--duration (value)
  (when-let* ((seconds (neo-scope--number value)))
    (let* ((ms (round (* seconds 1000))) (s (/ ms 1000)))
      (format "%02d:%02d:%02d.%03d" (/ s 3600) (% (/ s 60) 60) (% s 60) (% ms 1000)))))

(defun neo-scope--rate (value)
  (if (and (stringp value) (string-match "\\`\\([0-9]+\\)/\\([0-9]+\\)\\'" value))
      (let ((n (string-to-number (match-string 1 value))) (d (string-to-number (match-string 2 value))))
        (when (and (> n 0) (> d 0)) (/ (float n) d)))
    (let ((n (neo-scope--number value))) (and n (> n 0) n))))

(defun neo-scope--scaled (value divisor suffix)
  (when-let* ((n (neo-scope--number value))) (format "%g %s" (/ (float n) divisor) suffix)))

(defun neo-scope--media-description (data)
  "Format ffprobe DATA, preserving multiple video and audio streams."
  (let ((format-info (alist-get 'format data)) (index 0))
    (concat
     (neo-scope--field "Format" (or (alist-get 'format_long_name format-info) (alist-get 'format_name format-info)))
     (neo-scope--field "Duration" (neo-scope--duration (alist-get 'duration format-info))) "\n"
     (mapconcat
      (lambda (stream)
        (cl-incf index)
        (let ((type (alist-get 'codec_type stream)))
          (cond
           ((equal type "video")
            (concat (neo-scope--heading (format "Video · stream %s" (or (alist-get 'index stream) index)))
                    (neo-scope--field "Resolution" (and (alist-get 'width stream) (alist-get 'height stream)
                                                        (format "%s x %s" (alist-get 'width stream) (alist-get 'height stream))))
                    (neo-scope--field "Codec" (alist-get 'codec_name stream))
                    (neo-scope--field "Framerate" (when-let* ((fps (or (neo-scope--rate (alist-get 'avg_frame_rate stream))
                                                                                      (neo-scope--rate (alist-get 'r_frame_rate stream)))))
                                                      (format "%.3f fps" fps)))
                    (neo-scope--field "Bitrate" (neo-scope--scaled (alist-get 'bit_rate stream) 1000 "kb/s")) "\n"))
           ((equal type "audio")
            (concat (neo-scope--heading (format "Audio · stream %s" (or (alist-get 'index stream) index)))
                    (neo-scope--field "Codec" (alist-get 'codec_name stream))
                    (neo-scope--field "Bitrate" (neo-scope--scaled (alist-get 'bit_rate stream) 1000 "kb/s"))
                    (neo-scope--field "Sampling rate" (neo-scope--scaled (alist-get 'sample_rate stream) 1000 "kHz"))
                    (neo-scope--field "Channels" (let ((channels (alist-get 'channels stream)) (layout (alist-get 'channel_layout stream)))
                                                   (cond ((and channels layout) (format "%s (%s)" channels layout))
                                                         (channels (format "%s" channels)) (layout layout)))) "\n"))
           (t "")))) (alist-get 'streams data) ""))))

(defun neo-scope--cache-key (file program)
  (let ((attrs (file-attributes file)))
    (list (expand-file-name file) (file-attribute-size attrs)
          (file-attribute-modification-time attrs) (file-attribute-status-change-time attrs) program)))

(defun neo-scope-clear-preview-cache ()
  "Clear cached media metadata."
  (interactive) (clrhash neo-scope--media-cache))

(defun neo-scope--probe (file program callback)
  "Probe local FILE using PROGRAM; CALLBACK receives (DATA ERROR).
Return an idempotent cancel function.  Callback is never called after cancel."
  (let ((key (neo-scope--cache-key file program)) process timeout
        (output "") finished stderr)
    (cl-labels
        ((cleanup ()
           (when (timerp timeout) (cancel-timer timeout))
           (when process
             (set-process-sentinel process #'ignore)
             (when (process-live-p process) (delete-process process)))
           (when (buffer-live-p stderr)
             (when-let* ((err-process (get-buffer-process stderr)))
               (delete-process err-process))
             (kill-buffer stderr)))
         (finish (data error-text)
           (unless finished
             (setq finished t)
             (cleanup)
             (when (and data (> neo-scope-media-cache-size 0)
                        (equal key (neo-scope--cache-key file program)))
               (when (>= (hash-table-count neo-scope--media-cache) neo-scope-media-cache-size)
                 (remhash (car (hash-table-keys neo-scope--media-cache)) neo-scope--media-cache))
               (puthash key data neo-scope--media-cache))
             (funcall callback data error-text))))
      (if-let* ((cached (gethash key neo-scope--media-cache)))
          (setq timeout (run-at-time 0 nil (lambda () (finish cached nil))))
        (condition-case err
            (progn
              (setq stderr (generate-new-buffer " *neo-scope-ffprobe-error*"))
              (setq process
                    (make-process
                     :name "neo-scope-ffprobe" :buffer nil :stderr stderr :noquery t
                     :connection-type 'pipe
                     :coding (cons 'utf-8-unix (if (eq system-type 'windows-nt)
                                                   locale-coding-system 'utf-8-unix))
                     :command (list program "-v" "error" "-protocol_whitelist" "file"
                                    "-show_entries"
                                    "format=format_name,format_long_name,duration:stream=index,codec_type,codec_name,width,height,avg_frame_rate,r_frame_rate,bit_rate,sample_rate,channels,channel_layout"
                                    "-of" "json" "-i" (expand-file-name file))
                     :filter (lambda (_proc chunk)
                               (unless finished
                                 (if (> (+ (length output) (length chunk)) (* 1024 1024))
                                     (finish nil "Metadata exceeds output limit")
                                   (setq output (concat output chunk)))))
                     :sentinel
                     (lambda (proc _event)
                       (when (and (not finished) (memq (process-status proc) '(exit signal)))
                         (if (/= (process-exit-status proc) 0)
                             (finish nil "ffprobe could not read this media file")
                           (condition-case parse-error
                               (let ((data (json-parse-string output :object-type 'alist :array-type 'array
                                                              :null-object nil :false-object nil)))
                                 (unless (and (listp data) (or (assq 'format data) (assq 'streams data)))
                                   (error "No media metadata"))
                                 (finish data nil))
                             (error (finish nil (format "Invalid metadata: %s" (error-message-string parse-error))))))))))
              ;; Diagnostics are deliberately not accumulated; stdout is bounded.
              (when-let* ((err-process (get-buffer-process stderr)))
                (set-process-filter err-process #'ignore)
                (set-process-query-on-exit-flag err-process nil))
              (setq timeout (run-at-time neo-scope-probe-timeout nil
                                         (lambda () (finish nil "ffprobe timed out")))))
          (error (setq timeout (run-at-time 0 nil (lambda () (finish nil (error-message-string err))))))))
      (lambda () (setq finished t) (cleanup)))))

(defun neo-scope--image-preview (file buffer)
  (with-current-buffer buffer
    (let ((inhibit-read-only t) (type (image-supported-file-p file)))
      (insert (neo-scope--heading "Image")
              (neo-scope--field "Format" (upcase (or (and type (symbol-name type)) (file-name-extension file) "Unknown"))))
      (cond
       ((> (file-attribute-size (file-attributes file)) neo-scope-max-image-size)
        (insert "Image exceeds preview size limit.\n"))
       ((not (and type (image-type-available-p type)))
        (insert "This Emacs build cannot display this image format.\n"))
       (t
        (let* ((image (create-image file type nil))
               (size (image-size image t))
               (window (get-buffer-window buffer t))
               (width (if window (window-body-width window t) 600))
               (height (if window (window-body-height window t) 450)))
          (insert (neo-scope--field "Resolution" (format "%d x %d" (car size) (cdr size))) "\n")
          (insert-image (create-image file type nil :max-width (max 1 (- width 20))
                                      :max-height (max 1 (- height 220))))))))))

(defun neo-scope-preview (candidate buffer)
  "Render file information and type-specific content in owned BUFFER.
Media metadata is asynchronous and optional.  Kill or replace the preview
to cancel its process.  Existing text buffers remain unchanged."
  (neo-scope--stop-preview buffer)
  (let* ((value (plist-get candidate :value))
         (source (plist-get value :buffer))
         (file (or (plist-get value :file) (and (buffer-live-p source) (buffer-file-name source))))
         (ext (and file (downcase (or (file-name-extension file) ""))))
         (media (member ext '("mp4" "mkv" "webm" "mov" "avi" "m4v" "mpeg" "mpg" "wmv"
                              "mp3" "wav" "flac" "ogg" "opus" "m4a" "aac" "wma" "aiff")))
         (picture (member ext '("png" "jpg" "jpeg" "gif" "webp" "bmp" "tif" "tiff" "svg" "avif" "ico")))
         (token (list candidate)) general)
    (when (and file (file-remote-p file)) (user-error "Remote preview is not supported"))
    (setq source (or source (and file (get-file-buffer file))))
    (setq general (neo-scope--general-info file source))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (fundamental-mode) (erase-buffer)
        (cond
         ((or media picture) (insert general))
         (t
          (condition-case err
              (progn
                (neo-scope--text-preview candidate buffer)
                (let ((position (copy-marker (point) t)))
                  (goto-char (point-min))
                  (insert general (neo-scope--heading "Content"))
                  (goto-char position) (set-marker position nil)))
            (error (erase-buffer) (insert general (error-message-string err))))))
        (when picture
          (condition-case err (neo-scope--image-preview file buffer)
            (error (insert (format "Image unavailable: %s\n" (error-message-string err))))))
        (when media
          (if-let* ((program (and neo-scope-ffprobe-program (executable-find neo-scope-ffprobe-program))))
              (let ((start (point-max)))
                (setq neo-scope--preview-token token)
                (goto-char start) (insert "Reading media information…\n")
                (setq neo-scope--preview-cancel
                      (neo-scope--probe
                       file program
                       (lambda (data error-text)
                         (when (and (buffer-live-p buffer)
                                    (eq token (buffer-local-value 'neo-scope--preview-token buffer)))
                           (with-current-buffer buffer
                             (let ((inhibit-read-only t))
                               (save-excursion
                                 (delete-region start (point-max)) (goto-char start)
                                 (insert (if data (neo-scope--media-description data) error-text)))
                               (setq neo-scope--preview-cancel nil)
                               (set-buffer-modified-p nil))))))))
            (insert "Install ffprobe for video/audio details (optional).\n")))
        (when (or media picture) (goto-char (point-min)))
        (setq-local buffer-read-only t truncate-lines t mode-line-format nil
                    header-line-format (propertize " Preview" 'face 'neo-scope-title))
        (use-local-map neo-scope-panel-map)
        (add-hook 'kill-buffer-hook #'neo-scope--preview-killed nil t)
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
      (neo-scope--stop-preview (neo-scope--state-preview s))
      (setf (neo-scope--state-preview-key s) nil)
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
  (let ((key (list (neo-scope--selected s) (neo-scope--state-revision s))))
    (unless (or (neo-scope--state-query-timer s)
                (equal key (neo-scope--state-preview-key s)))
      (setf (neo-scope--state-preview-key s) key)
      (neo-scope--cancel-timer (neo-scope--state-preview-timer s))
      (neo-scope--stop-preview (neo-scope--state-preview s))
      (let ((revision (neo-scope--state-revision s)))
        (setf (neo-scope--state-preview-timer s)
              (run-at-time neo-scope-preview-delay nil
                           (lambda ()
                             (when (and (neo-scope--live-p s)
                                        (= revision (neo-scope--state-revision s)))
                               (neo-scope--show-preview s)))))))))

(defun neo-scope--show-preview (s)
  (let ((buffer (neo-scope--state-preview s)) (candidate (neo-scope--selected s)))
    (when (buffer-live-p buffer)
      (neo-scope--stop-preview buffer)
      (condition-case err
          (if candidate
              (funcall (or (plist-get (neo-scope--state-source s) :preview) #'neo-scope-preview)
                       candidate buffer)
            (with-current-buffer buffer (let ((inhibit-read-only t)) (erase-buffer))))
        (error (with-current-buffer buffer
                 (let ((inhibit-read-only t)) (erase-buffer) (insert (error-message-string err))))))
      (when (window-live-p (neo-scope--state-preview-window s))
        (with-current-buffer buffer
          (use-local-map neo-scope-panel-map)
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

(defun neo-scope--buffer-killed ()
  "Close the entire finder when any of its buffers is killed."
  (when neo-scope--owner
    (neo-scope--close neo-scope--owner nil (current-buffer))))

(defun neo-scope--close (s &optional no-focus killing-buffer)
  (unless (neo-scope--state-closed s)
    (setf (neo-scope--state-closed s) t)
    (when (eq s neo-scope--session) (setq neo-scope--session nil))
    (ignore-errors (neo-scope--stop-preview (neo-scope--state-preview s)))
    (dolist (timer (list (neo-scope--state-query-timer s) (neo-scope--state-match-timer s)
                        (neo-scope--state-preview-timer s))) (neo-scope--cancel-timer timer))
    (when (neo-scope--state-cancel s) (ignore-errors (funcall (neo-scope--state-cancel s))))
    (remove-hook 'delete-frame-functions #'neo-scope--frame-deleted)
    (remove-hook 'window-size-change-functions #'neo-scope--parent-resized)
    (when (buffer-live-p (neo-scope--state-input s))
      (let ((query (with-current-buffer (neo-scope--state-input s) (buffer-string))))
        (unless (string-empty-p query) (add-to-history 'neo-scope-history query))))
    (when (and (not no-focus) (frame-live-p (neo-scope--state-parent s))
               (window-configuration-p (neo-scope--state-window-config s)))
      (set-window-configuration (neo-scope--state-window-config s)))
    (dolist (buffer (list (neo-scope--state-input s) (neo-scope--state-candidates s)
                          (neo-scope--state-preview s)))
      (when (and (buffer-live-p buffer) (not (eq buffer killing-buffer)))
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
    (define-key map [remap quit-window] #'neo-scope-cancel)
    (define-key map [remap keyboard-quit] #'neo-scope-cancel)
    (define-key map (kbd "M-p") #'neo-scope-history-previous)
    (define-key map (kbd "M-n") #'neo-scope-history-next)
    map)
  "Keymap for the query buffer; unbound keys retain normal Emacs editing.")

(defvar neo-scope-panel-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map neo-scope-input-map)
    (define-key map (kbd "q") #'neo-scope-cancel)
    map)
  "Keymap for read-only panels.")

(defun neo-scope--frame-deleted (frame)
  (when-let* ((s neo-scope--session))
    (when (memq frame (list (neo-scope--state-frame s) (neo-scope--state-parent s)))
      ;; Avoid recursively deleting a frame already being destroyed.
      (when (eq frame (neo-scope--state-frame s)) (setf (neo-scope--state-frame s) nil))
      (neo-scope--close s t))))

(defun neo-scope--dimensions (parent)
  (cons (frame-width parent) (frame-height parent)))

(defun neo-scope--parent-resized (parent)
  (when-let* ((s neo-scope--session))
    (when (and (eq parent (neo-scope--state-parent s))
               (frame-live-p (neo-scope--state-frame s)))
      (let ((size (neo-scope--dimensions parent)))
        (if (or (< (car size) 30) (< (cdr size) 8)) (neo-scope--close s)
          (neo-scope--render s))))))

;;;###autoload
(defun neo-scope-open (source)
  "Open SOURCE in the current frame, a plist with :name and :start.
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
         (s (neo-scope--make-state :source source :parent parent :frame parent
                                   :window-config (current-window-configuration)
                                   :origin (selected-window))))
    (when (or (< (car size) 30) (< (cdr size) 8)) (user-error "Frame is too small for neo-scope"))
    (setq neo-scope--session s)
    (condition-case err
        (progn
          (setf (neo-scope--state-input s) (generate-new-buffer "*neo-scope*")
                (neo-scope--state-candidates s) (generate-new-buffer " *neo-scope-candidates*")
                (neo-scope--state-preview s) (generate-new-buffer " *neo-scope-preview*"))
          (dolist (buffer (list (neo-scope--state-input s) (neo-scope--state-candidates s)
                                (neo-scope--state-preview s)))
            (with-current-buffer buffer
              (setq-local neo-scope--owner s)
              (add-hook 'kill-buffer-hook #'neo-scope--buffer-killed nil t)
              (setq-local mode-line-format nil truncate-lines t cursor-type nil
                          header-line-format " " buffer-read-only t)
              (use-local-map neo-scope-panel-map)))
          (with-current-buffer (neo-scope--state-input s)
            (setq-local buffer-read-only nil cursor-type 'bar neo-scope--owner s)
            (use-local-map neo-scope-input-map)
            (add-hook 'after-change-functions #'neo-scope--input-changed nil t))
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
