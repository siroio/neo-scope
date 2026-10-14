;;; neo-scope-media-integration.el --- Real ffprobe checks -*- lexical-binding: t; -*-
(require 'ert)
(require 'neo-scope)
(defun neo-scope-integration-wait (buffer)
  (let ((deadline (+ (float-time) 8)))
    (while (and (buffer-local-value 'neo-scope--preview-cancel buffer) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (should-not (buffer-local-value 'neo-scope--preview-cancel buffer))))
(ert-deftest neo-scope-real-video-and-audio ()
  (dolist (fixture '(("動画 sample.mp4" "320 x 180" "25.000 fps" "aac" "mpeg4")
                     ("audio.wav" "22.05 kHz" "pcm_s16le" "2")))
    (let* ((file (expand-file-name (car fixture) "build/media-fixtures"))
           (buffer (generate-new-buffer "preview")))
      (unwind-protect
          (progn
            (should (file-exists-p file))
            (should (executable-find "ffprobe"))
            (neo-scope-preview (list :value (list :file file)) buffer)
            (neo-scope-integration-wait buffer)
            (with-current-buffer buffer
              (dolist (expected (cdr fixture))
                (should (string-match-p (regexp-quote expected) (buffer-string))))))
        (kill-buffer buffer)))))
(ert-deftest neo-scope-real-corrupt-media ()
  (let ((file (make-temp-file "corrupt" nil ".mp4")) (buffer (generate-new-buffer "preview")))
    (unwind-protect
        (progn
          (with-temp-file file (insert "not a movie"))
          (neo-scope-preview (list :value (list :file file)) buffer)
          (neo-scope-integration-wait buffer)
          (with-current-buffer buffer
            (should (string-match-p "General" (buffer-string)))
            (should (string-match-p "could not read" (buffer-string)))))
      (kill-buffer buffer) (delete-file file))))
