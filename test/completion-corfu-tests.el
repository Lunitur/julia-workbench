;;; completion-corfu-tests.el --- Optional Corfu GUI tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Explicit optional tests, run in a separate graphical Emacs -Q process.
;; Load the user's installed Corfu and Compat via CORFU_LOAD_PATH.  The core
;; package and normal tests have no dependency on these packages or a display.

;;; Code:

(require 'completion-tests)
(require 'eglot-integration-tests)
(require 'corfu)
(require 'corfu-popupinfo)
(declare-function evil-insert-state "evil-states" (&optional arg))

(when-let* ((path (getenv "JULIA_WORKBENCH_GRAMMAR_PATH")))
  (add-to-list 'treesit-extra-load-path path))

(defvar workbench-corfu-result-name
  (or (getenv "JULIA_WORKBENCH_CORFU_RESULTS") "corfu")
  "Result subdirectory for this optional GUI run.")

(ert-deftest workbench-corfu-automatic-settings-local ()
  "Enable automatic completion in Julia without changing other buffers."
  (let ((automatic (default-value 'corfu-auto))
        (popup (default-value 'corfu-popupinfo-mode))
        (julia-workbench-use-tree-sitter nil))
    (with-temp-buffer
      (julia-workbench-mode)
      (should corfu-mode)
      (should corfu-auto)
      (should corfu-popupinfo-mode)
      (should (= corfu-auto-prefix 2)))
    (should (eq automatic (default-value 'corfu-auto)))
    (should (eq popup (default-value 'corfu-popupinfo-mode)))
    (with-temp-buffer
      (let ((julia-workbench-automatic-completion nil))
        (julia-workbench-mode)
        (should-not (local-variable-p 'corfu-auto))))))

(defun workbench-corfu-select (name documentation)
  "Show actual completion and documentation popups, then accept NAME.
Check popup text for DOCUMENTATION before insertion."
  (should (display-graphic-p))
  (setq-local corfu-on-exact-match 'show
              corfu-preview-current nil
              corfu-popupinfo-delay nil)
  (corfu-mode 1)
  (corfu-popupinfo-mode 1)
  (redisplay t)
  (should (completion-at-point))
  (should completion-in-region-mode)
  (corfu--update)
  (setq corfu--index (seq-position corfu--candidates name #'string=))
  (should (integerp corfu--index))
  (corfu--exhibit)
  (should (frame-live-p corfu--frame))
  (should (frame-visible-p corfu--frame))
  (when documentation
    (let ((candidate (nth corfu--index corfu--candidates)))
      (should (string-match-p documentation (corfu-popupinfo--get-documentation candidate)))
      (setq corfu-popupinfo--function #'corfu-popupinfo--get-documentation)
      (corfu-popupinfo--show candidate)
      (should (frame-live-p corfu-popupinfo--frame))
      (should (frame-visible-p corfu-popupinfo--frame))
      (with-current-buffer corfu-popupinfo--buffer
        (should (string-match-p documentation (buffer-string))))))
  (corfu-insert)
  (should-not completion-in-region-mode))

(ert-deftest workbench-corfu-unicode-popup-and-insertion ()
  "Use Corfu child frames and exit callbacks for Unicode and emoji inputs."
  (workbench-completion-with-cache
    (switch-to-buffer (current-buffer))
    (dolist (pair '(("\\alpha" . "α") ("\\:smile:" . "😄")))
      (erase-buffer) (insert "α = \"🚀\"; x = " (car pair))
      (workbench-corfu-select (car pair) "Julia 1.13.1")
      (should (equal (buffer-string) (concat "α = \"🚀\"; x = " (cdr pair)))))))

(ert-deftest workbench-corfu-path-popup-and-insertion ()
  "Use Corfu's file category for a path containing a space."
  (let* ((directory (make-temp-file "workbench-corfu-path-" t))
         (default-directory (file-name-as-directory directory))
         (julia-workbench-use-tree-sitter nil))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "data file.txt" directory))
          (with-temp-buffer
            (julia-workbench-mode)
            (switch-to-buffer (current-buffer))
            (insert "α = \"🚀\"; include(\"data f")
            (workbench-corfu-select "data file.txt" nil)
            (should (equal (buffer-string) "α = \"🚀\"; include(\"data file.txt"))))
      (delete-directory directory t))))

(ert-deftest workbench-corfu-live-semantic-popup-and-insertion ()
  "Use Corfu with Eglot's actual Unicode-positioned server edits and docs."
  (let* ((directory (make-temp-file "workbench-corfu-live-" t))
         (root (expand-file-name "Example" directory))
         (eglot-sync-connect t)
         (eglot-connect-timeout 90)
         (eglot-autoreconnect nil)
         (shell-file-name (executable-find "sh"))
         (trusted-content (list (file-name-as-directory directory)))
         (julia-workbench-use-tree-sitter t)
         (buffer nil) (server nil))
    (unwind-protect
        (progn
          (copy-directory (expand-file-name "fixtures/Example" workbench-eglot-integration-directory)
                          root nil t t)
          (setq buffer (workbench-eglot-integration-open (expand-file-name "probe.jl" root)))
          (switch-to-buffer buffer)
          (julia-workbench-connect)
          (setq server (eglot-current-server))
          (goto-char (point-max))
          (insert "\nα = 1; emoji = \"🚀\"; Base.sin")
          (workbench-corfu-select "sinh" "hyperbolic")
          (should (string-suffix-p "α = 1; emoji = \"🚀\"; Base.sinh" (buffer-string)))
          (should (string-match-p "hyperbolic" (prin1-to-string
                                              (workbench-eglot-integration-hover buffer "sinh"))))
          (goto-char (point-max))
          (insert "(")
          ;; Exercise Eglot's public ElDoc provider in a displayed buffer.
          (eglot--signal-textDocument/didChange)
          (let ((signature nil))
            (should (eglot-signature-eldoc-function
                     (lambda (text &rest _) (setq signature text))))
            (workbench-eglot-integration-wait (lambda () signature))
            (should (string-match-p "sinh" signature)))
          ;; Type an actual character and wait for Corfu's automatic timer.
          (goto-char (point-max))
          (insert ")\nfunction typed_value(x::Int, label::AbstractString)::String\n string(x, label)\nend\ntyped_va")
          (setq-local corfu-popupinfo-delay '(0.2 . 0.1))
          (should corfu-auto)
          (when (bound-and-true-p evil-local-mode) (evil-insert-state))
          (execute-kbd-macro "l")
          (should (string-suffix-p "typed_val" (buffer-string)))
          (workbench-eglot-integration-wait (lambda () completion-in-region-mode) 15)
          (corfu--update)
          (should (member "typed_value" corfu--candidates))
          (corfu--exhibit)
          (should (frame-visible-p corfu--frame))
          (workbench-corfu-select "typed_value" "x::Int, label::AbstractString.*::String")
          (insert "(")
          (eglot--signal-textDocument/didChange)
          (let (signature)
            (should (eglot-signature-eldoc-function
                     (lambda (text &rest _) (setq signature text))))
            (workbench-eglot-integration-wait (lambda () signature))
            (should (string-match-p "x::Int" signature))
            (should (string-match-p "label::AbstractString" signature))))
      (when server
        (workbench-eglot-integration-save-logs (list server) workbench-corfu-result-name)
        (when (jsonrpc-running-p server) (ignore-errors (eglot-shutdown server))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-directory directory t))))

(defun workbench-corfu-run ()
  "Run optional GUI fixtures, retain their log, and exit this test Emacs."
  (let ((status 1)
        (directory (expand-file-name (concat "results/" workbench-corfu-result-name)
                                     workbench-eglot-integration-directory))
        (coding-system-for-write 'utf-8-emacs))
    (unwind-protect
        (progn
          ;; Timers do not count as first input.  Activate Doom's normal lazy
          ;; completion configuration, as the first keyboard command would.
          (when (boundp 'doom-first-input-hook)
            (run-hooks 'doom-first-input-hook))
          (message "UI environment: Emacs %s; Doom %s; Corfu %s; completion styles %S"
                   emacs-version (if (featurep 'doom) "loaded" "absent")
                   (locate-library "corfu") completion-styles)
          (let ((stats (ert-run-tests-batch "\\`workbench-corfu-")))
            (setq status (if (zerop (ert-stats-completed-unexpected stats)) 0 1))))
      (make-directory directory t)
      (with-current-buffer "*Messages*"
        (write-region (point-min) (point-max)
                      (expand-file-name "ui.log" directory) nil 'silent))
      (kill-emacs status))))

(provide 'completion-corfu-tests)
;;; completion-corfu-tests.el ends here
