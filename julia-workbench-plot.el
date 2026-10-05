;;; julia-workbench-plot.el --- Native Julia plot pane -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Julia Workbench contributors
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "30.1"))

;;; Commentary:
;; SVG/PNG files belong to one local REPL session.  A dedicated pane keeps a
;; bounded history without taking focus from source; terminal clients can save
;; cached figures.  No plotting package is installed or required by this adapter.

;;; Code:

(require 'julia-workbench)
(require 'image-mode)
(require 'seq)

(declare-function julia-workbench--repl-settings "julia-workbench-repl" ())
(defvar julia-workbench--repl-context)
(defvar julia-workbench--repl-sessions)

(defcustom julia-workbench-plot-enabled t
  "Whether new Julia REPL sessions capture SVG/PNG plots in Emacs.
Changing this setting selects a different session."
  :type 'boolean :group 'julia-workbench)
(make-variable-buffer-local 'julia-workbench-plot-enabled)

(defcustom julia-workbench-plot-formats '(svg png)
  "Preferred plot formats, in order, for new REPL sessions.
Only formats supported by this Emacs build are requested."
  :type '(repeat (choice (const svg) (const png))) :group 'julia-workbench)
(make-variable-buffer-local 'julia-workbench-plot-formats)

(defcustom julia-workbench-plot-max-bytes (* 16 1024 1024)
  "Maximum bytes in one plot file for new REPL sessions."
  :type 'natnum :group 'julia-workbench)

(defcustom julia-workbench-plot-history-limit 20
  "Maximum retained figures per REPL session, at least one."
  :type 'natnum :group 'julia-workbench)

(defvar-local julia-workbench--plot-directory nil
  "Private plot directory owned by this REPL buffer.")
(defvar-local julia-workbench--plot-history nil
  "Oldest-first plot entries owned by this REPL buffer.")
(defvar-local julia-workbench--plot-index 0
  "Index of the selected plot in this REPL buffer's history.")
(defvar-local julia-workbench--plot-buffer nil
  "Display pane belonging to this REPL buffer.")
(defvar-local julia-workbench--plot-session nil
  "REPL buffer owning this plot pane.")

(defun julia-workbench--plot-formats ()
  "Return the enabled image formats supported by the current Emacs build."
  (when julia-workbench-plot-enabled
    (seq-filter #'image-type-available-p
                (delete-dups (copy-sequence julia-workbench-plot-formats)))))

(defun julia-workbench--plot-cleanup ()
  "Remove this REPL's plot pane, history and private files."
  (when (buffer-live-p julia-workbench--plot-buffer)
    (kill-buffer julia-workbench--plot-buffer))
  (when (and julia-workbench--plot-directory
             (file-directory-p julia-workbench--plot-directory))
    (delete-directory julia-workbench--plot-directory t))
  (setq julia-workbench--plot-directory nil julia-workbench--plot-history nil
        julia-workbench--plot-buffer nil julia-workbench--plot-index 0))

(defun julia-workbench--plot-owner ()
  "Return the owning REPL when invoked from a plot, REPL or source buffer."
  (cond
   ((derived-mode-p 'julia-workbench-plot-mode)
    (if (buffer-live-p julia-workbench--plot-session) julia-workbench--plot-session
      (user-error "The Julia plot session has ended")))
   ((derived-mode-p 'julia-workbench-repl-mode) (current-buffer))
   (t
    (let ((session (gethash (plist-get (julia-workbench--repl-settings) :key)
                            julia-workbench--repl-sessions)))
      (if (buffer-live-p session) session
        (user-error "No Julia REPL for this environment; start one to create plots"))))))

(defun julia-workbench--plot-current (session)
  "Return the selected plot entry in SESSION, or report an empty history."
  (with-current-buffer session
    (or (nth julia-workbench--plot-index julia-workbench--plot-history)
        (user-error "No Julia plots yet"))))

(defun julia-workbench--plot-render (session)
  "Render SESSION's selected plot, returning its pane without selecting it."
  (let* ((entry (julia-workbench--plot-current session))
         (pane (with-current-buffer session
                 (unless (buffer-live-p julia-workbench--plot-buffer)
                   (setq julia-workbench--plot-buffer
                         (generate-new-buffer
                          (format "*Julia Plots %s*"
                                  (string-remove-suffix
                                   "*" (string-remove-prefix "*Julia REPL " (buffer-name session)))))))
                 julia-workbench--plot-buffer)))
    (with-current-buffer pane
      (unless (derived-mode-p 'julia-workbench-plot-mode) (julia-workbench-plot-mode))
      (setq julia-workbench--plot-session session)
      (let ((inhibit-read-only t)
            (window (or (get-buffer-window pane) (selected-window))))
        (erase-buffer)
        (if (display-images-p)
            (insert-image (create-image (plist-get entry :file) (plist-get entry :type) nil
                                        :max-width (max 1 (window-body-width window t))
                                        :max-height (max 1 (window-body-height window t))))
          (insert "Open a graphical Emacs client to view this plot.\n"
                  "Press s to save the original image.\n\n" (plist-get entry :file)))
        (goto-char (point-min))
        (setq header-line-format
              (with-current-buffer session
                (format " Plot %d/%d | %s | n/p  +/-  f:fit  s:save"
                        (1+ julia-workbench--plot-index) (length julia-workbench--plot-history)
                        (upcase (symbol-name (plist-get entry :type))))))
        (set-buffer-modified-p nil)))
    pane))

(defun julia-workbench--plot-receive (text)
  "Validate TEXT's MIME, basename and byte count, then retain the session plot.
This runs in the REPL buffer and never completes an evaluation request."
  (let* ((fields (split-string text "\t"))
         (mime (nth 0 fields)) (name (nth 1 fields)) (size-text (nth 2 fields))
         (type (cdr (assoc mime '(("image/svg+xml" . svg) ("image/png" . png)))))
         (file (and julia-workbench--plot-directory name
                    (expand-file-name name julia-workbench--plot-directory))))
    (unless (and (= (length fields) 3) type file
                 (member type (plist-get julia-workbench--repl-context :plot-formats))
                 (string-match-p (format "\\`plot-[0-9]+\\.%s\\'" type) name)
                 (string-match-p "\\`[0-9]+\\'" size-text)
                 (file-regular-p file) (not (file-symlink-p file))
                 (equal (file-name-directory (file-truename file))
                        (file-name-as-directory (file-truename julia-workbench--plot-directory)))
                 (let ((size (string-to-number size-text)))
                   (and (> size 0) (<= size (plist-get julia-workbench--repl-context :plot-max-bytes))
                        (= size (file-attribute-size (file-attributes file)))))
                 (not (seq-find (lambda (entry) (equal file (plist-get entry :file)))
                                julia-workbench--plot-history)))
      (error "Invalid Julia plot record"))
    (setq julia-workbench--plot-history
          (nconc julia-workbench--plot-history (list (list :file file :type type))))
    (while (> (length julia-workbench--plot-history) (max 1 julia-workbench-plot-history-limit))
      (delete-file (plist-get (pop julia-workbench--plot-history) :file)))
    (setq julia-workbench--plot-index (1- (length julia-workbench--plot-history)))
    (when (display-images-p)
      (let ((session (current-buffer)))
        (save-selected-window
          (let ((pane (julia-workbench--plot-render session)))
            (display-buffer pane '((display-buffer-reuse-window display-buffer-in-side-window)
                                   (side . right) (window-width . 0.45)))
            ;; Fit to the actual pane after its first display.
            (julia-workbench--plot-render session)))))))

;;;###autoload
(defun julia-workbench-show-plots ()
  "Show this session's plot history without starting Julia."
  (interactive)
  (let* ((session (julia-workbench--plot-owner))
         (pane (julia-workbench--plot-render session)))
    (pop-to-buffer pane)
    (julia-workbench--plot-render session)))

(defun julia-workbench-plot-next (&optional count)
  "Display the next COUNT plots, or the previous plots when COUNT is negative."
  (interactive "p")
  (let ((session (julia-workbench--plot-owner)))
    (with-current-buffer session
      (julia-workbench--plot-current session)
      (setq julia-workbench--plot-index
            (max 0 (min (1- (length julia-workbench--plot-history))
                        (+ julia-workbench--plot-index (or count 1))))))
    (julia-workbench--plot-render session)))

(defun julia-workbench-plot-previous (&optional count)
  "Display the previous COUNT plots."
  (interactive "p")
  (julia-workbench-plot-next (- (or count 1))))

(defun julia-workbench-plot-fit ()
  "Fit the current plot to the pane, resetting image magnification."
  (interactive)
  (julia-workbench--plot-render (julia-workbench--plot-owner)))

(defun julia-workbench-plot-save (filename)
  "Save the selected plot's original image bytes to FILENAME.
The output format stays SVG or PNG regardless of FILENAME's extension."
  (interactive
   (let* ((entry (julia-workbench--plot-current (julia-workbench--plot-owner)))
          (file (plist-get entry :file)))
     (list (read-file-name "Save Julia plot: " nil nil nil (file-name-nondirectory file)))))
  (let ((entry (julia-workbench--plot-current (julia-workbench--plot-owner))))
    (copy-file (plist-get entry :file) filename (if (called-interactively-p 'interactive) 1 nil))
    (message "Saved Julia plot to %s" filename)))

(defvar julia-workbench-plot-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (keymap-set map "n" #'julia-workbench-plot-next)
    (keymap-set map "p" #'julia-workbench-plot-previous)
    (keymap-set map "+" #'image-increase-size)
    (keymap-set map "=" #'image-increase-size)
    (keymap-set map "-" #'image-decrease-size)
    (keymap-set map "f" #'julia-workbench-plot-fit)
    (keymap-set map "s" #'julia-workbench-plot-save)
    map)
  "Keymap for the dedicated Julia plot pane.")

(define-derived-mode julia-workbench-plot-mode special-mode "Julia Plots"
  "Native SVG/PNG plot history for one Julia REPL session."
  (setq-local truncate-lines t))

(provide 'julia-workbench-plot)
;;; julia-workbench-plot.el ends here
