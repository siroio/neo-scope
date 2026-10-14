;;; neo-scope-media-tests.el --- Rich preview tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'neo-scope)

(ert-deftest neo-scope-media-basic-info-and-code ()
  (let ((file (make-temp-file "scope" nil ".el")) (buffer (generate-new-buffer "preview")))
    (unwind-protect
        (progn
          (with-temp-file file (insert "(message \"hello\")\n"))
          (neo-scope-preview (list :value (list :file file)) buffer)
          (with-current-buffer buffer
            (should (string-match-p "General" (buffer-string)))
            (should (string-match-p "Modified" (buffer-string)))
            (should (string-match-p (regexp-quote file) (buffer-string)))
            (should (string-match-p "message" (buffer-string)))))
      (kill-buffer buffer) (delete-file file))))

(ert-deftest neo-scope-media-optional-probe ()
  (let ((file (make-temp-file "scope" nil ".mp4")) (buffer (generate-new-buffer "preview"))
        (neo-scope-ffprobe-program nil))
    (unwind-protect
        (progn
          (neo-scope-preview (list :value (list :file file)) buffer)
          (with-current-buffer buffer
            (should (string-match-p "General" (buffer-string)))
            (should (string-match-p "ffprobe" (buffer-string)))
            (should-not neo-scope--preview-cancel)))
      (kill-buffer buffer) (delete-file file))))

(ert-deftest neo-scope-media-format-streams ()
  (let ((text (neo-scope--media-description
               '((format . ((format_long_name . "MPEG-4") (duration . "226.349")))
                 (streams . [((codec_type . "video") (codec_name . "h264")
                              (width . 1920) (height . 1080) (avg_frame_rate . "30000/1001") (bit_rate . "1369000"))
                             ((codec_type . "audio") (codec_name . "aac") (sample_rate . "44100")
                              (channels . 2) (channel_layout . "stereo") (bit_rate . "128000"))])))))
    (dolist (value '("MPEG-4" "00:03:46.349" "1920 x 1080" "29.970" "h264" "aac" "44.1 kHz" "stereo"))
      (should (string-match-p (regexp-quote value) text)))))

(ert-deftest neo-scope-media-missing-data ()
  (let ((text (neo-scope--media-description '((streams . [((codec_type . "video") (avg_frame_rate . "0/0"))])))))
    (should (string-match-p "Unknown" text))
    (should-not (string-match-p "NaN" text))))

(defun neo-scope-test-await (predicate)
  (let ((deadline (+ (float-time) 8)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (should (funcall predicate))))

(defmacro neo-scope-test-probe-process (form &rest body)
  "Use an isolated Emacs process executing FORM as a probe fixture."
  (declare (indent 1))
  `(let ((original (symbol-function 'make-process)))
     (cl-letf (((symbol-function 'make-process)
                (lambda (&rest args)
                  (let ((command (plist-get args :command)))
                    (should (member "-protocol_whitelist" command))
                    (should (equal (car (last command)) file)))
                  (apply original
                         (plist-put args :command
                                    (list (expand-file-name invocation-name invocation-directory)
                                          "-Q" "--batch" "--eval" (prin1-to-string ,form)))))))
       ,@body)))

(ert-deftest neo-scope-media-async-cache-invalidates ()
  (let ((file (make-temp-file "scope" nil ".wav"))
        (neo-scope--media-cache (make-hash-table :test 'equal)) done data error-text cancel)
    (unwind-protect
        (neo-scope-test-probe-process '(princ "{\"format\":{\"duration\":\"1.5\"},\"streams\":[]}")
          (setq cancel (neo-scope--probe file "fixture" (lambda (d e) (setq data d error-text e done t))))
          (should-not done)
          (neo-scope-test-await (lambda () done))
          (should-not error-text)
          (should (equal "1.5" (alist-get 'duration (alist-get 'format data))))
          (should (= 1 (hash-table-count neo-scope--media-cache)))
          (cl-letf (((symbol-function 'make-process) (lambda (&rest _) (ert-fail "Cache missed"))))
            (setq done nil)
            (setq cancel (neo-scope--probe file "fixture" (lambda (_d _e) (setq done t))))
            (neo-scope-test-await (lambda () done)))
          (with-temp-file file (insert "changed"))
          (should-not (gethash (neo-scope--cache-key file "fixture") neo-scope--media-cache)))
      (when cancel (funcall cancel)) (delete-file file))))

(ert-deftest neo-scope-media-cancel-and-timeout ()
  (let ((file (make-temp-file "scope" nil ".wav")) (neo-scope-probe-timeout 0.1)
        (neo-scope--media-cache (make-hash-table :test 'equal)) done error-text cancel)
    (unwind-protect
        (neo-scope-test-probe-process '(sleep-for 20)
          (setq cancel (neo-scope--probe file "fixture" (lambda (_d _e) (setq done t))))
          (funcall cancel) (funcall cancel)
          (sleep-for 0.2)
          (should-not done)
          (setq cancel (neo-scope--probe file "fixture" (lambda (_d e) (setq done t error-text e))))
          (neo-scope-test-await (lambda () done))
          (should (equal "ffprobe timed out" error-text))
          (should-not (cl-find-if (lambda (p) (string-prefix-p "neo-scope-ffprobe" (process-name p))) (process-list))))
      (when cancel (funcall cancel)) (delete-file file))))

(ert-deftest neo-scope-media-invalid-json ()
  (let ((file (make-temp-file "scope" nil ".wav")) done error-text cancel)
    (unwind-protect
        (neo-scope-test-probe-process '(princ "invalid json")
          (setq cancel (neo-scope--probe file "fixture" (lambda (_d e) (setq done t error-text e))))
          (neo-scope-test-await (lambda () done))
          (should (string-match-p "Invalid metadata" error-text)))
      (when cancel (funcall cancel)) (delete-file file))))

(ert-deftest neo-scope-media-replaced-preview-ignores-late-result ()
  (let ((file (make-temp-file "scope" nil ".mp4")) (buffer (generate-new-buffer "preview")) callback cancelled)
    (unwind-protect
        (cl-letf (((symbol-function 'executable-find) (lambda (_) "fake-probe"))
                  ((symbol-function 'neo-scope--probe)
                   (lambda (_f _p cb) (setq callback cb) (lambda () (setq cancelled t)))))
          (neo-scope-preview (list :value (list :file file)) buffer)
          (neo-scope--stop-preview buffer)
          (with-current-buffer buffer (let ((inhibit-read-only t)) (erase-buffer) (insert "new candidate")))
          (funcall callback '((format . ((duration . "10")))) nil)
          (should cancelled)
          (with-current-buffer buffer (should (equal "new candidate" (buffer-string)))))
      (kill-buffer buffer) (delete-file file))))

(ert-deftest neo-scope-media-buffer-kill-cancels ()
  (let ((file (make-temp-file "scope" nil ".mp4")) (buffer (generate-new-buffer "preview")) cancelled)
    (unwind-protect
        (cl-letf (((symbol-function 'executable-find) (lambda (_) "fake-probe"))
                  ((symbol-function 'neo-scope--probe)
                   (lambda (&rest _) (lambda () (setq cancelled t)))))
          (neo-scope-preview (list :value (list :file file)) buffer)
          (kill-buffer buffer)
          (should cancelled))
      (when (buffer-live-p buffer) (kill-buffer buffer)) (delete-file file))))

(ert-deftest neo-scope-media-image-fallback ()
  (let ((file (make-temp-file "scope" nil ".png")) (buffer (generate-new-buffer "preview")))
    (unwind-protect
        (cl-letf (((symbol-function 'image-supported-file-p) (lambda (_) nil)))
          (neo-scope-preview (list :value (list :file file)) buffer)
          (with-current-buffer buffer
            (should (string-match-p "General" (buffer-string)))
            (should (string-match-p "cannot display" (buffer-string)))))
      (kill-buffer buffer) (delete-file file))))

(ert-deftest neo-scope-media-output-limit ()
  (let ((file (make-temp-file "scope" nil ".wav")) done error-text cancel)
    (unwind-protect
        (neo-scope-test-probe-process '(princ (make-string 1100000 ?x))
          (setq cancel (neo-scope--probe file "fixture" (lambda (_d e) (setq done t error-text e))))
          (neo-scope-test-await (lambda () done))
          (should (equal "Metadata exceeds output limit" error-text)))
      (when cancel (funcall cancel)) (delete-file file))))

(ert-deftest neo-scope-media-cache-bound ()
  (let ((file (make-temp-file "scope" nil ".wav"))
        (neo-scope--media-cache (make-hash-table :test 'equal))
        (neo-scope-media-cache-size 1) cancel done)
    (unwind-protect
        (neo-scope-test-probe-process '(princ "{\"format\":{\"duration\":\"1\"}}")
          (dotimes (i 2)
            (setq done nil)
            (setq cancel (neo-scope--probe file (format "fixture%d" i) (lambda (&rest _) (setq done t))))
            (neo-scope-test-await (lambda () done)))
          (should (= 1 (hash-table-count neo-scope--media-cache))))
      (when cancel (funcall cancel)) (delete-file file))))

(ert-deftest neo-scope-media-grep-preview-line-preserved ()
  (let ((file (make-temp-file "scope" nil ".el")) (buffer (generate-new-buffer "preview")))
    (unwind-protect
        (progn
          (with-temp-file file (insert ";; first\n(message \"second\")\n"))
          (neo-scope-preview (list :value (list :file file :line 2)) buffer)
          (with-current-buffer buffer (should (looking-at-p "(message"))))
      (kill-buffer buffer) (delete-file file))))

(ert-deftest neo-scope-media-header-does-not-change-code-syntax ()
  (let ((source (generate-new-buffer "test\"name")) (buffer (generate-new-buffer "preview")))
    (unwind-protect
        (progn
          (with-current-buffer source (emacs-lisp-mode) (insert "(message \"hello\")"))
          (neo-scope-preview (list :value (list :buffer source)) buffer)
          (with-current-buffer buffer
            (font-lock-ensure)
            (goto-char (point-max)) (search-backward "message")
            (should-not (eq (get-text-property (point) 'face) 'font-lock-string-face))
            (search-forward "hello")
            (should (eq (get-text-property (1- (point)) 'face) 'font-lock-string-face))))
      (kill-buffer source) (kill-buffer buffer))))

(ert-deftest neo-scope-media-selection-cancels-immediately ()
  (let* ((buffer (generate-new-buffer "preview"))
         (s (neo-scope--make-state :preview buffer :matches
                                   (vector (cons (list :id 1) '(0)) (cons (list :id 2) '(0)))))
         (neo-scope--session s) cancelled)
    (unwind-protect
        (progn
          (with-current-buffer buffer (setq neo-scope--preview-cancel (lambda () (setq cancelled t))))
          (neo-scope-next)
          (should cancelled)
          (setf (neo-scope--state-query-timer s) (run-at-time 10 nil #'ignore))
          (neo-scope--cancel-timer (neo-scope--state-preview-timer s))
          (setf (neo-scope--state-preview-timer s) nil (neo-scope--state-preview-key s) nil)
          (neo-scope--schedule-preview s)
          (should-not (neo-scope--state-preview-timer s)))
      (neo-scope--close s t))))
