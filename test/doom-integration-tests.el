;;; doom-integration-tests.el --- Optional migrated Doom checks -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Run in a fresh graphical Doom after sync, without the checkout on load-path.
;; This verifies the installed recipe, actual Doom dispatch and diagnostics.
;; All runtime work uses generated projects; the user's daemon is untouched.

;;; Code:

(require 'ert)
(require 'cl-lib)

;; Keep initial mode loading lazy while dynamically binding Eglot settings.
(defvar eglot-sync-connect)
(defvar eglot-connect-timeout)
(defvar eglot-autoreconnect)
(defvar eglot-events-buffer-config)
(defvar trusted-content)

(defconst workbench-doom-test-directory
  (file-name-directory (or load-file-name buffer-file-name)))

(defun workbench-doom-wait (predicate)
  "Wait at most ninety seconds for PREDICATE, allowing process/UI callbacks."
  (let ((deadline (+ (float-time) 90)))
    (while (not (funcall predicate))
      (when (> (float-time) deadline) (ert-fail "Doom integration timed out"))
      (accept-process-output nil 0.05))))

(defun workbench-doom-log ()
  "Retain messages while running tests, including during asynchronous waits."
  (let ((directory (expand-file-name "results/doom-migration" workbench-doom-test-directory))
        (coding-system-for-write 'utf-8-emacs))
    (make-directory directory t)
    (with-current-buffer "*Messages*"
      (write-region (point-min) (point-max) (expand-file-name "ui.log" directory) nil 'silent))
    (when-let* ((help (get-buffer "*Julia Documentation*")))
      (with-current-buffer help
        (write-region (point-min) (point-max) (expand-file-name "help.log" directory) nil 'silent)))))

(defun workbench-doom-server-logs (server)
  "Save SERVER's protocol/stderr logs without prompting about raw bytes."
  (let ((directory (expand-file-name "results/doom-migration" workbench-doom-test-directory))
        (coding-system-for-write 'utf-8-emacs))
    (make-directory directory t)
    (dolist (entry `(("events.log" . ,(jsonrpc-events-buffer server))
                     ("stderr.log" . ,(jsonrpc-stderr-buffer server))))
      (when (buffer-live-p (cdr entry))
        (with-current-buffer (cdr entry)
          (write-region (point-min) (point-max) (expand-file-name (car entry) directory) nil 'silent))))))

(defmacro workbench-doom-fixture (&rest body)
  "Run BODY in a disposable Julia project with installed Doom integration."
  (declare (indent 0) (debug t))
  `(let* ((directory (make-temp-file "workbench-doom-" t))
          (root (expand-file-name "Example" directory))
          (shell-file-name (executable-find "sh"))
          (trusted-content (list (file-name-as-directory directory)))
          (eglot-sync-connect t)
          (eglot-connect-timeout 90)
          (eglot-autoreconnect nil)
          (server nil) (source nil))
     (unwind-protect
         (progn
           (copy-directory (expand-file-name "fixtures/Example" workbench-doom-test-directory)
                           root nil t t)
           ;; Eglot resolves workspace settings in a temporary project buffer.
           ;; A source-buffer-only binding does not disable symbol downloads.
           (with-temp-file (expand-file-name ".dir-locals.el" root)
             (insert "((julia-workbench-mode . ((eglot-workspace-configuration . (:julia.symbolCacheDownload :json-false)))))\n"))
           (setq source (find-file-noselect (expand-file-name "probe.jl" root)))
           (switch-to-buffer source)
           (should (eq major-mode 'julia-workbench-mode))
           (setq-local julia-workbench-julia-command (or (getenv "JULIA") "julia")
                       eglot-workspace-configuration '(:julia.symbolCacheDownload :json-false))
           ,@body)
       (when server
         (workbench-doom-server-logs server)
         (when (jsonrpc-running-p server) (ignore-errors (eglot-shutdown server))))
       (when (featurep 'julia-workbench-repl) (julia-workbench--repl-shutdown-all))
       (when (featurep 'julia-workbench-doc) (julia-workbench--doc-cleanup))
       (dolist (buffer (buffer-list))
         (when (or (string-prefix-p "*Julia " (buffer-name buffer))
                   (and (buffer-file-name buffer)
                        (file-in-directory-p (buffer-file-name buffer) directory)))
           (with-current-buffer buffer (set-buffer-modified-p nil))
           (kill-buffer buffer)))
       (delete-directory directory t))))

(ert-deftest workbench-doom-00-installation-and-editing ()
  "Check mode selection, packaged assets and inactive previous integrations."
  (should (featurep 'doom))
  (should (display-graphic-p))
  (should-not (modulep! :lang julia))
  (require 'doom-packages)
  (let ((packages (doom-package-list)))
    (should (assq 'julia-workbench packages))
    (dolist (package '(julia-mode julia-ts-mode julia-repl eglot-jl julia-snail lsp-julia))
      (should-not (assq package packages))
      (should-not (featurep package))))
  (workbench-doom-fixture
    (should (treesit-parser-list))
    (should-not (eglot-current-server))
    (should-error (julia-workbench--repl-buffer) :type 'user-error)
    (should (string-match-p "/straight/build-" (locate-library "julia-workbench")))
    (dolist (asset '("paths.jl" "launch-server.jl" "setup-server.jl" "documentation.jl"
                     "unicode.jl" "repl.jl" "server-environment/Project.toml"
                     "server-environment/Manifest.toml"))
      (should (file-readable-p (julia-workbench--asset asset))))
    (with-temp-buffer
      (setq buffer-file-name "script")
      (insert "#!/usr/bin/env julia\nα = 1\n")
      (set-auto-mode)
      (should (eq major-mode 'julia-workbench-mode))
      ;; Doom can confirm killing modified temporary buffers as well as files.
      (set-buffer-modified-p nil))))

(ert-deftest workbench-doom-10-repl-and-eval-dispatch ()
  "Use Doom's REPL/evaluation handlers and the preserved localleader keys."
  (workbench-doom-fixture
    (erase-buffer) (insert "α = 40\nα + 2\n")
    (evil-normal-state)
    (dolist (entry '(("'" . julia-workbench-repl)
                     ("p" . julia-workbench-repl-activate-project)
                     ("d" . julia-workbench-documentation-at-point)
                     ("y" . julia-workbench-copy-last-eval-result)
                     ("l" . julia-workbench-send-line)
                     ("r" . julia-workbench-send-region)
                     ("e" . julia-workbench-send-dwim)
                     ("b" . julia-workbench-send-top-level-form)
                     ("x" . julia-workbench-send-top-level-form)
                     ("f" . julia-workbench-send-buffer-file)))
      (should (eq (key-binding (kbd (concat "SPC m " (car entry)))) (cdr entry))))
    (call-interactively #'+eval/open-repl-other-window)
    (let ((repl (current-buffer)))
      (should (derived-mode-p 'julia-workbench-repl-mode))
      (should (buffer-local-value '+eval-repl-plist repl))
      (switch-to-buffer source)
      (+eval/buffer)
      (workbench-doom-wait
       (lambda () (equal (buffer-local-value 'julia-workbench--repl-last-result repl) "42")))
      (with-current-buffer source
        (julia-workbench-copy-last-eval-result)
        (should (equal (current-kill 0) "42"))
        (should (eq (car (alist-get major-mode +eval-repl-handler-alist))
                    '+julia-workbench-open-repl))
        (erase-buffer) (insert "α + 3\n")
        (+eval/region (point-min) (point-max)))
      (workbench-doom-wait
       (lambda () (equal (buffer-local-value 'julia-workbench--repl-last-result repl) "43")))
      (should-not (eglot-current-server)))))

(ert-deftest workbench-doom-20-eglot-diagnostics-lookup-and-format ()
  "Exercise Doom's actual Flycheck bridge, persistent lookup and LSP formatter."
  (workbench-doom-fixture
    (let ((eglot-events-buffer-config '(:size 2000000 :format full)))
      (julia-workbench-connect))
    (setq server (eglot-current-server))
    (should (eglot-managed-p))
    (should (bound-and-true-p flycheck-eglot-mode))
    (should-not (bound-and-true-p flymake-mode))
    (should (memq 'flymake eglot-stay-out-of))
    (message "Doom diagnostics: Flycheck %S; bridge %S (%s); checker %S"
             flycheck-mode flycheck-eglot-mode (symbol-file 'flycheck-eglot-mode 'defun) flycheck-checker)
    (run-at-time 5 nil #'workbench-doom-server-logs server)
    (flycheck-buffer)
    (workbench-doom-wait
     (lambda () (with-current-buffer source
                  (cl-some (lambda (err)
                             (or (equal (flycheck-error-id err) "unused_function_argument")
                                 (string-match-p "not used" (flycheck-error-message err))))
                           flycheck-current-errors))))
    (switch-to-buffer source)
    (should (eq (car +lookup-documentation-functions) 'julia-workbench-documentation-at-point))
    (goto-char (point-min)) (search-forward "twice(α)") (backward-char 8)
    (let ((original (symbol-function '+lookup--run-handler)))
      (cl-letf (((symbol-function '+lookup--run-handler)
                 (lambda (handler identifier)
                   (condition-case err (funcall original handler identifier)
                     (error (message "Doom lookup handler %S failed: %S" handler err)
                            (signal (car err) (cdr err)))))))
        (call-interactively #'+lookup/documentation)))
    (workbench-doom-wait
     (lambda () (when-let* ((help (get-buffer "*Julia Documentation*")))
                  (with-current-buffer help
                    (and (string-match-p "Current language-server workspace" (buffer-string))
                         (string-match-p "twice" (buffer-string)))))))
    (should (get-buffer-window "*Julia Documentation*"))
    (with-current-buffer "*Julia Documentation*"
      (should (bound-and-true-p +popup-buffer-mode)))
    (switch-to-buffer source)
    (should (bound-and-true-p +format-with-lsp-mode))
    (should (memq 'lsp (ensure-list +format-with)))
    (call-interactively #'+format/buffer)
    (workbench-doom-wait
     (lambda () (with-current-buffer source
                  (string-match-p (regexp-quote "compact(x) = x+1") (buffer-string)))))
    (switch-to-buffer source)
    (let ((completion-in-region-function
           (lambda (begin end table predicate)
             (let ((candidate (car (member "sinh" (all-completions
                                                    (buffer-substring begin end) table predicate)))))
               (should candidate)
               (delete-region begin end) (goto-char begin) (insert candidate)
               (funcall (plist-get completion-extra-properties :exit-function) candidate 'finished)
               t))))
      (goto-char (point-max)) (insert "\nα = 1; emoji = \"🐈\"; Base.sin")
      (should (completion-at-point))
      (should (string-suffix-p "Base.sinh" (buffer-string))))))

(ert-deftest workbench-doom-30-documentation-search-and-buttons ()
  "Display named/help search popups and follow a project-package result."
  (workbench-doom-fixture
    (julia-workbench-documentation "Base.sin")
    (workbench-doom-wait
     (lambda () (with-current-buffer "*Julia Documentation*"
                  (string-match-p "sine" (buffer-string)))))
    (should (get-buffer-window "*Julia Documentation*"))
    (switch-to-buffer source)
    (julia-workbench-documentation-select-packages '("WorkbenchExample"))
    (julia-workbench-documentation-search "quasarotter")
    (workbench-doom-wait
     (lambda () (with-current-buffer "*Julia Documentation*"
                  (string-match-p "WorkbenchExample.greet" (buffer-string)))))
    (with-current-buffer "*Julia Documentation*"
      (should (bound-and-true-p +popup-buffer-mode))
      (goto-char (point-min)) (search-forward "WorkbenchExample.greet")
      (button-activate (button-at (1- (point)))))
    (workbench-doom-wait
     (lambda () (with-current-buffer "*Julia Documentation*"
                  (string-match-p "greet(name)" (buffer-string)))))
    (should-not (eglot-current-server))))

(defun workbench-doom-run ()
  "Run migrated Doom checks, retain a log and exit this test Emacs."
  (let ((status 1)
        (logger (run-at-time 0 1 #'workbench-doom-log)))
    (unwind-protect
        (progn
          (run-hooks 'doom-first-input-hook)
          (message "Migrated Doom: Emacs %s; package %s; config %s; local data %s"
                   emacs-version (locate-library "julia-workbench") doom-user-dir doom-local-dir)
          (let ((stats (ert-run-tests-batch
                        (or (getenv "JULIA_WORKBENCH_DOOM_SELECTOR") "\\`workbench-doom-"))))
            (setq status (if (zerop (ert-stats-completed-unexpected stats)) 0 1))))
      (cancel-timer logger)
      (workbench-doom-log)
      (kill-emacs status))))

;;; doom-integration-tests.el ends here
