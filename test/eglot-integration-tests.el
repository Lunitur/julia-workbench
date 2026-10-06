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
(require 'imenu)

(when-let* ((path (getenv "JULIA_WORKBENCH_GRAMMAR_PATH")))
  (add-to-list 'treesit-extra-load-path path))

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
    ;; Use the same position adapter as persistent documentation requests.
    (eglot--request (eglot-current-server) :textDocument/hover
                    (eglot--TextDocumentPositionParams) :timeout 90)))

(defun workbench-eglot-integration-complete (name &optional documentation)
  "Accept semantic NAME through standard completion, checking DOCUMENTATION.
The selection adapter uses the CAPF exactly as a completion UI does."
  (let* ((selected nil)
         (completion-in-region-function
          (lambda (begin end table predicate)
            (let* ((prefix (buffer-substring-no-properties begin end))
                   (metadata (completion-metadata prefix table predicate))
                   (candidate (car (member name (all-completions prefix table predicate))))
                   (item (and candidate (get-text-property 0 'eglot--lsp-item candidate))))
              (should (eq (completion-metadata-get metadata 'category) 'eglot-capf))
              (should (functionp (completion-metadata-get metadata 'display-sort-function)))
              (should candidate)
              (should item)
              (should (= (plist-get item :insertTextFormat) 1))
              (should (plist-get item :textEdit))
              (should (stringp (funcall (plist-get completion-extra-properties
                                                  :annotation-function) candidate)))
              (when documentation
                (let ((doc (funcall (plist-get completion-extra-properties :company-doc-buffer)
                                    candidate)))
                  (should (buffer-live-p doc))
                  (with-current-buffer doc
                    (should (string-match-p documentation (buffer-string))))))
              (delete-region begin end)
              (goto-char begin)
              (insert candidate)
              (funcall (plist-get completion-extra-properties :exit-function) candidate 'finished)
              (setq selected t)))))
    (should (completion-at-point))
    (should selected)))

(defun workbench-eglot-integration-completion ()
  "Exercise qualified, import and macro completions with real server edits."
  (should (equal (seq-take completion-at-point-functions 3)
                 '(julia-workbench-unicode-completion-at-point
                   julia-workbench-path-completion-at-point julia-workbench-semantic-completion-at-point)))
  (let ((original (buffer-string)))
    (unwind-protect
        (progn
          (goto-char (point-max))
          (insert "\nα = 1; emoji = \"🚀\"; Base.sin")
          (workbench-eglot-integration-complete "sinh" "hyperbolic")
          (should (string-suffix-p "α = 1; emoji = \"🚀\"; Base.sinh" (buffer-string)))
          (insert "\nusing Base: sin")
          (workbench-eglot-integration-complete "sinh" "hyperbolic")
          (should (string-suffix-p "using Base: sinh" (buffer-string)))
          (insert "\nBase.@tim")
          (workbench-eglot-integration-complete "@time")
          (should (string-suffix-p "Base.@time" (buffer-string)))
          ;; No identifier yet: the dot trigger must still offer semantic items.
          (insert "\nBase.")
          (workbench-eglot-integration-complete "sinh" "hyperbolic")
          (should (string-suffix-p "Base.sinh" (buffer-string)))
          (insert "\nfunction typed_value(\n value::Int,\n label::AbstractString\n)::String\n string(value, label)\nend\n")
          (eglot--signal-textDocument/didChange)
          (let* ((items (xref-backend-apropos 'eglot "typed_value"))
                 (item (car items)))
            (should item)
            (should (string-match-p "\\[Function\\]" (xref-item-summary item)))
            (should (equal (xref-file-location-file (xref-item-location item)) buffer-file-name))
            (when (treesit-ready-p 'julia t)
              (should (string-match-p "value::Int, label::AbstractString.*::String" (xref-item-summary item)))
              (let ((index (imenu--make-index-alist t)))
                (should (cl-some (lambda (name)
                                   (and (stringp name)
                                        (string-match-p "typed_value( value::Int, label::AbstractString )::String" name)))
                                 (flatten-tree index))))))
          ;; Both methods must appear from server metadata alone, without
          ;; relying on current-buffer tree-sitter declarations.
          (insert "\noverloaded_value(x::Int) = string(x)\noverloaded_value(x::AbstractString) = x\noverloaded_v")
          (eglot--signal-textDocument/didChange)
          (let ((julia-workbench--tree-sitter-active nil))
            (let* ((capf (julia-workbench-semantic-completion-at-point))
                   (candidates (all-completions "overloaded_v" (nth 2 capf)))
                   (candidate (car (member "overloaded_value" candidates)))
                   (properties (nthcdr 3 capf)))
              (should (= 1 (cl-count "overloaded_value" candidates :test #'equal)))
              (should (string-match-p "2 methods"
                                      (funcall (plist-get properties :annotation-function) candidate)))
              (let ((doc (funcall (plist-get properties :company-doc-buffer) candidate)))
                (with-current-buffer doc
                  (should (string-match-p "2 available methods" (buffer-string)))
                  (should (string-match-p "x::Int" (buffer-string)))
                  (should (string-match-p "x::AbstractString" (buffer-string)))))
              (workbench-eglot-integration-complete "overloaded_value" "2 available methods")))
          (insert "(")
          (eglot--signal-textDocument/didChange)
          (when (get-buffer "*Julia Methods*") (kill-buffer "*Julia Methods*"))
          (julia-workbench-signature-help)
          (workbench-eglot-integration-wait (lambda () (get-buffer "*Julia Methods*")))
          (with-current-buffer "*Julia Methods*"
            (should (= 2 (length julia-workbench--signature-positions)))
            (should (string-match-p "x::Int" (buffer-string)))
            (should (string-match-p "x::AbstractString" (buffer-string))))
          (kill-buffer "*Julia Methods*")
          (insert "1)\n")
          (let ((julia-workbench-cache-directory
                 (expand-file-name "unicode-cache" default-directory)))
            (let ((process (julia-workbench-setup-unicode)))
              (workbench-eglot-integration-wait (lambda () (not (process-live-p process))) 30))
            (should (> (hash-table-count (cdr (julia-workbench--unicode-data))) 3000))
            (insert "\nx = \\alpha")
            (should (completion-at-point))
            (should (string-suffix-p "x = α" (buffer-string)))))
      (erase-buffer)
      (insert original)
      ;; Batch Emacs has no idle command loop to flush the restored document.
      (eglot--signal-textDocument/didChange))))

(defun workbench-eglot-integration-save-logs (servers &optional subdirectory)
  "Preserve SERVERS' event and stderr logs, including on failure.
Use SUBDIRECTORY under results, default eglot."
  (let ((directory (expand-file-name (concat "results/" (or subdirectory "eglot"))
                                    workbench-eglot-integration-directory)))
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
         (julia-workbench-use-tree-sitter t)
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
            (should (memq #'julia-workbench-semantic-completion-at-point completion-at-point-functions))
            (flymake-start nil t)
            (workbench-eglot-integration-wait (lambda () (flymake-diagnostics)))
            (should (cl-some (lambda (diagnostic)
                               (string-match-p "unused" (flymake-diagnostic-text diagnostic)))
                             (flymake-diagnostics)))
            (workbench-eglot-integration-completion)
            (should (string-match-p "twice" (prin1-to-string
                                              (workbench-eglot-integration-hover
                                               first-buffer "twice(α)"))))
            ;; Persistent help also works for a buffer-local function unavailable
            ;; to a fresh helper, with no source window or local Julia needed.
            (let ((julia-workbench-julia-command "missing-local-julia"))
              (julia-workbench-documentation-at-point)
              (workbench-eglot-integration-wait
               (lambda ()
                 (with-current-buffer "*Julia Documentation*"
                   (string-match-p "Current language-server workspace" (buffer-string))))))
            (with-current-buffer "*Julia Documentation*"
              (should (string-match-p "Current language-server workspace" (buffer-string)))
              (should (string-match-p "twice" (buffer-string))))
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
            (should (eq :json-false
                        (plist-get (plist-get (plist-get (plist-get
                                   (eglot-client-capabilities first-server) :textDocument)
                                   :completion) :completionItem) :snippetSupport)))
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
      (when-let* ((buffer (get-buffer "*Julia Documentation*"))) (kill-buffer buffer))
      (dolist (server servers)
        (when (jsonrpc-running-p server) (ignore-errors (eglot-shutdown server))))
      (dolist (buffer buffers)
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer)))
      (delete-directory directory t))))

(provide 'eglot-integration-tests)
;;; eglot-integration-tests.el ends here
