;;; neo-scope-media-gui.el --- Image/media GUI integration -*- lexical-binding: t; -*-
(setq default-directory (file-name-directory (directory-file-name (file-name-directory load-file-name))))
(add-to-list 'load-path default-directory)
(require 'neo-scope)
(defvar neo-scope-media-gui-log (expand-file-name "build/media-gui-result.txt"))
(write-region "" nil neo-scope-media-gui-log nil 'silent)
(defun neo-scope-media-gui-check (test label)
  (unless test (error "Media GUI: %s" label))
  (write-region (concat "PASS " label "\n") nil neo-scope-media-gui-log t 'silent))
(defun neo-scope-media-gui-fail (err)
  (write-region (format "FAIL %S\n" err) nil neo-scope-media-gui-log t 'silent)
  (kill-emacs 1))
(defun neo-scope-media-gui-image ()
  (condition-case err
      (let* ((s neo-scope--session) (b (neo-scope--state-preview s)))
        (with-current-buffer b
          (neo-scope-media-gui-check (string-match-p "320 x 180" (buffer-string)) "native image dimensions")
          (let ((at (text-property-not-all (point-min) (point-max) 'display nil)))
            (neo-scope-media-gui-check (and at (eq 'image (car (get-text-property at 'display)))) "native image display property"))
          (neo-scope-media-gui-check (eq (key-binding (kbd "C-g")) #'neo-scope-cancel) "image panel cancel key"))
        (neo-scope-next)
        (run-at-time 1 nil #'neo-scope-media-gui-video))
    (error (neo-scope-media-gui-fail err))))
(defun neo-scope-media-gui-video ()
  (condition-case err
      (progn
        (with-current-buffer (neo-scope--state-preview neo-scope--session)
          (neo-scope-media-gui-check (string-match-p "25.000 fps" (buffer-string)) "video framerate")
          (neo-scope-media-gui-check (string-match-p "44.1 kHz" (buffer-string)) "video audio stream")
          (neo-scope-media-gui-check (string-match-p "General" (buffer-string)) "common metadata"))
        (neo-scope-next)
        (run-at-time 1 nil #'neo-scope-media-gui-audio))
    (error (neo-scope-media-gui-fail err))))
(defun neo-scope-media-gui-audio ()
  (condition-case err
      (progn
        (with-current-buffer (neo-scope--state-preview neo-scope--session)
          (neo-scope-media-gui-check (string-match-p "22.05 kHz" (buffer-string)) "audio sampling rate")
          (neo-scope-media-gui-check (string-match-p "pcm_s16le" (buffer-string)) "audio codec"))
        (kill-buffer (neo-scope--state-preview neo-scope--session))
        (neo-scope-media-gui-check (null neo-scope--session) "finder cleanup")
        (neo-scope-media-gui-check
         (not (cl-find-if (lambda (p) (string-prefix-p "neo-scope-ffprobe" (process-name p))) (process-list)))
         "no probe process remains")
        (write-region "MEDIA GUI COMPLETE\n" nil neo-scope-media-gui-log t 'silent)
        (kill-emacs 0))
    (error (neo-scope-media-gui-fail err))))
(run-at-time
 0.5 nil
 (lambda ()
   (condition-case err
       (progn
         (set-frame-size (selected-frame) 130 40)
         (neo-scope-open
          (list :name "Media preview"
                :start (lambda (_query emit)
                         (funcall emit 'add
                                  (mapcar (lambda (name)
                                            (neo-scope--file-candidate
                                             (expand-file-name name "build/media-fixtures") default-directory))
                                          '("image.png" "動画 sample.mp4" "audio.wav")))
                         (funcall emit 'done nil) #'ignore)))
         (run-at-time 1 nil #'neo-scope-media-gui-image))
     (error (neo-scope-media-gui-fail err)))))
