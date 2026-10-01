;;; eglot-integration-tests.el --- Live Eglot Julia tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Exercise actual Eglot buffers with the installed pinned Julia server.
;; This is an explicit integration target: never install missing tooling.

;;; Code:

(require 'ert)
(require 'julia-workbench-eglot)
(require 'flymake)
(require 'xref)

(defvar trusted-content)

(defconst workbench-eglot-integration-directory
  (file-name-directory (or load-file-name buffer-file-name)))

(defun workbench-eglot-integration-wait (predicate &optional seconds)
  "Wait for PREDICATE for at most SECONDS, default 90."
  (let ((deadline (+ (float-time) (or seconds 90))))
    (while (not (funcall predicate))
      (when (and (derived-mode-p 'julia-workbench-mode) (not (eglot-managed-p)))
        (ert-fail "Eglot stopped managing the buffer while waiting"))
      (when (> (float-time) deadline) (ert-fail "Timed out waiting for Eglot"))
      (accept-process-output nil 0.05))))

(defun workbench-eglot-integration-open (file)
  "Visit Julia FILE with isolated, offline Eglot settings."
  (let ((buffer (find-file-noselect file)))
    (with-current-buffer buffer
      (setq-local julia-workbench-julia-command (or (getenv "JULIA") "julia")
                  eglot-workspace-configuration '(:julia.symbolCacheDownload :json-false))
      (should (eq major-mode 'julia-workbench-mode)))
    buffer))

(defun workbench-eglot-integration-hover (buffer needle)
  "Request hover in BUFFER at NEEDLE using Eglot's position conversion."
  (with-current-buffer buffer
    (goto-char (point-min))
    (search-forward needle)
    (backward-char (length needle))
    ;; Keep protocol-specific glue isolated here; production uses public Eglot.
    (eglot--request (eglot-current-server) :textDocument/hover
                    (eglot--TextDocumentPositionParams) :timeout 90)))

(defun workbench-eglot-integration-save-logs (servers)
  "Preserve SERVERS' event and stderr logs, including on failure."
  (let ((directory (expand-file-name "results/eglot" workbench-eglot-integration-directory)))
    (make-directory directory t)
    (cl-loop for server in servers for index from 1 do
             (dolist (entry `(("events" . ,(jsonrpc-events-buffer server))
                              ("stderr" . ,(jsonrpc-stderr-buffer server))))
               (when (buffer-live-p (cdr entry))
                 (with-current-buffer (cdr entry)
                   (let ((coding-system-for-write 'utf-8-emacs))
                     (write-region (point-min) (point-max)
                                   (expand-file-name
                                    (format "%s-%d.log" (car entry) index) directory)
                                   nil 'silent))))))))

(ert-deftest workbench-eglot-live-projects-and-recovery ()
  "Prove environment isolation, sharing, editing paths and crash recovery."
  (let* ((directory (make-temp-file "workbench-eglot-live-" t))
         (first (expand-file-name "first" directory))
         (second (expand-file-name "second" directory))
         (buffers nil) (servers nil)
         (eglot-sync-connect t)
         (eglot-connect-timeout 90)
         (eglot-autoreconnect nil)
         (eglot-confirm-server-edits nil)
         (shell-file-name (executable-find "sh"))
         ;; Emacs 31 gates Flymake and local configuration on content trust.
         ;; Trust only this generated fixture for the duration of the test.
         (trusted-content (list (file-name-as-directory directory)))
         (julia-workbench-use-tree-sitter nil)
         (first-buffer nil) (second-buffer nil) (sibling nil)
         (first-server nil) (second-server nil))
    (unwind-protect
        (progn
          (copy-directory (expand-file-name "fixtures/Example" workbench-eglot-integration-directory)
                          first nil t t)
          (copy-directory (expand-file-name "fixtures/Other" workbench-eglot-integration-directory)
                          second nil t t)
          (dolist (root (list first second))
            (with-temp-file (expand-file-name ".dir-locals.el" root)
              (insert "((julia-workbench-mode . ((eglot-workspace-configuration . (:julia.symbolCacheDownload :json-false)))))\n")))
          (setq first-buffer (workbench-eglot-integration-open (expand-file-name "probe.jl" first)))
          (push first-buffer buffers)
          (with-current-buffer first-buffer
            (julia-workbench-connect)
            (setq first-server (eglot-current-server))
            (push first-server servers)
            (should (eglot-managed-p))
            (should (memq #'eglot-completion-at-point completion-at-point-functions))
            (flymake-start nil t)
            (workbench-eglot-integration-wait (lambda () (flymake-diagnostics)))
            (should (cl-some (lambda (diagnostic)
                               (string-match-p "unused" (flymake-diagnostic-text diagnostic)))
                             (flymake-diagnostics)))
            (should (string-match-p "twice" (prin1-to-string
                                              (workbench-eglot-integration-hover
                                               first-buffer "twice(α)"))))
            (let* ((backend (xref-find-backend))
                   (definitions (xref-backend-definitions backend "twice")))
              (should definitions)
              (should (equal (xref-file-location-file (xref-item-location (car definitions)))
                             buffer-file-name)))
            (goto-char (point-min))
            (search-forward "twice(α)")
            (backward-char (length "twice(α)"))
            (eglot-rename "double_value")
            (should (= (how-many "double_value" (point-min) (point-max)) 3))
            (should (string-match-p "unicode_result = double_value(α)" (buffer-string)))
            (eglot-format-buffer)
            (should (string-match-p (regexp-quote "compact(x) = x+1") (buffer-string)))
            (should (string-match-p "double_value" (prin1-to-string
                                                    (workbench-eglot-integration-hover
                                                     first-buffer "double_value(α)"))))
            (should (eglot-server-capable :completionProvider))
            (should (eglot-server-capable :inlayHintProvider))
            (should (fboundp 'eglot-inlay-hints-mode))
            (should-not (eglot-server-capable :typeDefinitionProvider)))
          (setq sibling (workbench-eglot-integration-open
                         (expand-file-name "src/WorkbenchExample.jl" first)))
          (push sibling buffers)
          (with-current-buffer sibling
            (julia-workbench-connect)
            (should (eq first-server (eglot-current-server))))
          (setq second-buffer (workbench-eglot-integration-open
                               (expand-file-name "probe.jl" second)))
          (push second-buffer buffers)
          (with-current-buffer second-buffer
            (julia-workbench-connect)
            (setq second-server (eglot-current-server))
            (push second-server servers)
            (should-not (eq first-server second-server))
            (flymake-start nil t)
            (workbench-eglot-integration-wait (lambda () (flymake-diagnostics)))
            (should (string-match-p "betabadger"
                                    (prin1-to-string (workbench-eglot-integration-hover
                                                     second-buffer "distinct")))))
          (should (string-match-p "quasarotter"
                                  (prin1-to-string (workbench-eglot-integration-hover
                                                   sibling "greet(name) ="))))
          ;; A killed server must release the buffer; explicit reconnect repairs it.
          (delete-process (jsonrpc--process first-server))
          (with-current-buffer first-buffer
            (workbench-eglot-integration-wait (lambda () (not (eglot-managed-p))) 10)
            (julia-workbench-reconnect)
            (let ((restarted (eglot-current-server)))
              (push restarted servers)
              (should (jsonrpc-running-p restarted))
              (should-not (eq restarted first-server)))
            (should (jsonrpc-running-p second-server))
            (flymake-start nil t)
            (workbench-eglot-integration-wait (lambda () (flymake-diagnostics)))
            (should (workbench-eglot-integration-hover first-buffer "double_value(α)"))
            ;; Changing settings chooses a new contact and joins the other project
            ;; only when root and environment both agree (roots here differ).
            (setq-local julia-workbench-environment second)
            (julia-workbench-reconnect)
            (push (eglot-current-server) servers)
            (should-not (eq (eglot-current-server) second-server))
            (should (equal (nth 4 (process-command
                                  (jsonrpc--process (eglot-current-server))))
                           (file-name-as-directory second)))
            (flymake-start nil t)
            (workbench-eglot-integration-wait (lambda () (flymake-diagnostics)))
            (julia-workbench-shutdown)
            (should-not (eglot-managed-p)))
          (with-current-buffer second-buffer
            (should (jsonrpc-running-p (eglot-current-server)))
            (julia-workbench-shutdown)
            (should-not (eglot-managed-p))))
      (workbench-eglot-integration-save-logs servers)
      (dolist (server servers)
        (when (jsonrpc-running-p server) (ignore-errors (eglot-shutdown server))))
      (dolist (buffer buffers)
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer)))
      (delete-directory directory t))))

(provide 'eglot-integration-tests)
;;; eglot-integration-tests.el ends here
