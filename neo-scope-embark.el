;;; neo-scope-embark.el --- Carry Embark candidates into neo-scope -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Call `neo-scope-embark-setup', then use Embark's act-all followed by N.
;; The filtered snapshot opens in neo-scope with an empty query for refinement.

;;; Code:
(require 'neo-scope)

(defvar embark-general-map)
(defvar embark-multitarget-actions)
(defvar embark-around-action-hooks)
(defvar embark-quit-after-action)
(defvar neo-scope-embark--type nil)
(declare-function consult--get-location "consult" (cand))
(declare-function embark-consult-goto-location "embark-consult" (target))
(declare-function embark-consult-goto-grep "embark-consult" (location))

(defun neo-scope-embark--around (&rest args)
  "Carry Embark's candidate type through its action hooks in ARGS."
  (let ((neo-scope-embark--type (plist-get args :type)))
    (apply (plist-get args :run) args)))

(defun neo-scope-embark--candidate (type target id)
  "Convert TARGET of TYPE to a candidate with unique ID."
  (when (and (eq type 'buffer) (bufferp target))
    (setq target (or (buffer-name target) (user-error "Buffer no longer exists"))))
  (unless (and (stringp target) (> (length target) 0))
    (user-error "Empty or invalid Embark candidate"))
  (if (eq type 'multi-category)
      (let ((item (get-text-property 0 'multi-category target)))
        (neo-scope-embark--candidate (car item) (cdr item) id))
    (when (memq type '(consult-location consult-grep))
      (unless (require 'embark-consult nil t)
        (user-error "Consult candidates require embark-consult")))
    (let (file buffer marker (line 1))
      (pcase type
        ('file (setq file (expand-file-name target)))
        ('buffer (setq buffer (get-buffer target))
                 (unless (buffer-live-p buffer) (user-error "Buffer no longer exists: %s" target))
                 (setq line (with-current-buffer buffer (line-number-at-pos (point) t))))
        ('consult-location
         (setq marker (car (consult--get-location target)))
         (unless (and (markerp marker) (marker-buffer marker))
           (user-error "Consult location no longer exists"))
         (setq marker (copy-marker marker) buffer (marker-buffer marker)
               line (with-current-buffer buffer (line-number-at-pos marker t))
               target (propertize (copy-sequence target) 'consult-location (cons marker line))))
        ('consult-grep
         ;; Consult encodes file and line boundaries as faces, including paths with colons.
         (let* ((file-end (next-single-property-change 0 'face target))
                (line-start (and file-end (1+ file-end)))
                (line-end (and line-start (< line-start (length target))
                               (next-single-property-change line-start 'face target))))
           (unless (and (eq (get-text-property 0 'face target) 'consult-file)
                        line-end
                        (eq (get-text-property line-start 'face target) 'consult-line-number)
                        (string-match-p "\\`[0-9]+\\'" (substring target line-start line-end)))
             (user-error "Consult grep candidate has no file/line metadata"))
           (setq file (expand-file-name (substring-no-properties target 0 file-end))
                 line (string-to-number (substring target line-start line-end)))
           (unless (> line 0) (user-error "Invalid Consult line number"))))
        (_ (user-error "Unsupported Embark candidate type: %s" type)))
      (when (or (and file (file-remote-p file))
                (and buffer (buffer-file-name buffer) (file-remote-p (buffer-file-name buffer))))
        (user-error "neo-scope supports local candidates only"))
      (when (and file (not (file-exists-p file)))
        (user-error "File no longer exists: %s" file))
      (list :id id :label (neo-scope--label (substring-no-properties target))
            :value (list :file file :buffer buffer :line line :marker marker
                         :type type :target target :directory default-directory)))))

(defun neo-scope-embark--preview (candidate buffer)
  "Preview CANDIDATE in BUFFER, following edits to Consult markers."
  (let* ((value (plist-get candidate :value)) (marker (plist-get value :marker)))
    (when marker
      (unless (marker-buffer marker) (user-error "Consult location no longer exists"))
      (setf (plist-get value :line)
            (with-current-buffer (marker-buffer marker) (line-number-at-pos marker t))))
    (neo-scope-preview candidate buffer)))

(defun neo-scope-embark--action (candidate)
  "Visit CANDIDATE using its original position semantics."
  (let* ((value (plist-get candidate :value))
         (default-directory (plist-get value :directory))
         (file (plist-get value :file)) (buffer (plist-get value :buffer))
         (target (plist-get value :target)))
    (when (and file (not (file-exists-p file))) (user-error "File no longer exists: %s" file))
    (when (and buffer (not (buffer-live-p buffer))) (user-error "Buffer no longer exists"))
    (pcase (plist-get value :type)
      ('file (find-file file))
      ('buffer (switch-to-buffer buffer))
      ('consult-location (embark-consult-goto-location target))
      ('consult-grep (embark-consult-goto-grep target)))))

;;;###autoload
(defun neo-scope-embark (candidates)
  "Open Embark's filtered CANDIDATES as a snapshot in neo-scope.
Use this through Embark act-all to transfer the complete candidate set."
  (interactive (user-error "Use Embark act-all, then N"))
  (unless candidates (user-error "No Embark candidates to transfer"))
  (let ((items (cl-loop for target in candidates for id from 0
                        collect (neo-scope-embark--candidate neo-scope-embark--type target id))))
    ;; Embark restores its action window on return; open after that cleanup.
    (run-at-time 0 nil #'neo-scope-open
     (list :name "Embark candidates"
           :start (lambda (_query emit)
                    (funcall emit 'add items) (funcall emit 'done nil) #'ignore)
           :preview #'neo-scope-embark--preview :action #'neo-scope-embark--action))))

;;;###autoload
(defun neo-scope-embark-setup ()
  "Register N as Embark's action to open candidates in neo-scope."
  (interactive)
  (require 'embark)
  (let ((binding (lookup-key embark-general-map (kbd "N"))))
    (when (and binding (not (eq binding #'neo-scope-embark)))
      (user-error "Embark N is already bound to %s" binding)))
  (define-key embark-general-map (kbd "N") #'neo-scope-embark)
  (add-to-list 'embark-multitarget-actions #'neo-scope-embark)
  (cl-pushnew #'neo-scope-embark--around (alist-get 'neo-scope-embark embark-around-action-hooks))
  (unless (consp embark-quit-after-action)
    (setq embark-quit-after-action (list (cons t embark-quit-after-action))))
  (setf (alist-get 'neo-scope-embark embark-quit-after-action) t))

(provide 'neo-scope-embark)
;;; neo-scope-embark.el ends here
