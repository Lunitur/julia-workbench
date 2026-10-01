;;; documentation-ui-tests.el --- Documentation contracts -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Offline ERT fixtures for asynchronous documentation lifecycle and UI.

;;; Code:

(require 'ert)
(require 'julia-workbench-doc)

(defun workbench-doc-export (command query &optional body)
  "Return a valid protocol export for COMMAND, QUERY and optional BODY."
  (let ((field (lambda (name value)
                 (concat name "\t" (base64-encode-string (encode-coding-string value 'utf-8-unix) t) "\n"))))
    (concat "julia-workbench-doc-v1\t1.13.1\t" command "\n"
            (funcall field "Scope" "Base/Core; explicit packages: Example")
            (if (equal command "lookup")
                (concat (funcall field "Symbol" query) "Documented\ttrue\n"
                        (funcall field "Markdown" (or body "    greet(name)\n\nHello α and 🐈.\n")))
              (concat "Truncated\tfalse\n"
                      (mapconcat (lambda (name) (funcall field "Name" name)) body ""))))))

(defmacro workbench-doc-with-fixture (&rest body)
  "Run BODY with a temporary local project, runtime, source buffer and cache."
  (declare (indent 0) (debug t))
  `(let* ((directory (make-temp-file "workbench-doc-" t))
          (default-directory (file-name-as-directory directory))
          (julia-workbench-cache-directory (expand-file-name "cache" directory))
          (julia-workbench-julia-command (expand-file-name "runtime" directory))
          (julia-workbench-documentation-packages nil)
          (julia-workbench-use-tree-sitter nil)
          (julia-workbench--doc-jobs (make-hash-table :test #'eq))
          (julia-workbench--doc-cache (make-hash-table :test #'equal))
          (response-file (expand-file-name "response" directory))
          (source (generate-new-buffer " *doc source*")))
     (unwind-protect
         (progn
           (with-temp-file (expand-file-name "Project.toml" directory) (insert "[deps]\n"))
           (with-temp-file response-file (insert (workbench-doc-export "lookup" "Base.sin")))
           (with-temp-file julia-workbench-julia-command
             (insert "#!/bin/sh\ncat " (shell-quote-argument response-file) "\n"))
           (set-file-modes julia-workbench-julia-command #o700)
           (with-current-buffer source
             (setq default-directory (file-name-as-directory directory))
             (julia-workbench-mode)
             ,@body))
       (julia-workbench--doc-cleanup)
       (when-let* ((buffer (get-buffer "*Julia Documentation*"))) (kill-buffer buffer))
       (dolist (buffer (buffer-list))
         (when (string-prefix-p "*Julia documentation log" (buffer-name buffer)) (kill-buffer buffer)))
       (when (buffer-live-p source) (kill-buffer source))
       (delete-directory directory t))))

(defun workbench-doc-wait ()
  "Wait at most ten seconds for all fixture helpers and their sentinels."
  (let ((deadline (+ (float-time) 10)))
    (while (> (hash-table-count julia-workbench--doc-jobs) 0)
      (when (> (float-time) deadline) (ert-fail "Documentation worker did not finish"))
      (accept-process-output nil 0.03))))

(ert-deftest workbench-doc-symbol-at-point ()
  "Find qualified, Unicode, operator and macro names at token boundaries."
  (dolist (name '("Base.sin" "Base.@time" "Base.+" "+" "π" "αβ!"))
    (with-temp-buffer
      (insert " " name "(") (backward-char)
      (should (equal name (julia-workbench--doc-symbol-at-point)))))
  (with-temp-buffer
    (insert "α+β")
    (goto-char 1) (should (equal "α" (julia-workbench--doc-symbol-at-point)))
    (goto-char 2) (should (equal "+" (julia-workbench--doc-symbol-at-point)))
    (goto-char 3) (should (equal "β" (julia-workbench--doc-symbol-at-point))))
  (with-temp-buffer (insert "   ") (should-not (julia-workbench--doc-symbol-at-point))))

(ert-deftest workbench-doc-protocol-validation ()
  "Validate multiline Unicode data, command/query identity and malformed data."
  (with-temp-buffer
    (insert (workbench-doc-export "lookup" "Base.sin"))
    (should (string-match-p "α and 🐈" (plist-get (julia-workbench--doc-parse "lookup" "Base.sin") :markdown)))
    (should-error (julia-workbench--doc-parse "search" "Base.sin"))
    (should-error (julia-workbench--doc-parse "lookup" "exit()"))
    (goto-char (point-max)) (insert "Scope\tYmFk\n")
    (should-error (julia-workbench--doc-parse "lookup" "Base.sin")))
  (dolist (export '("#.(error \"cache evaluated\")" "julia-workbench-doc-v1\t1.13.1\tsearch\nScope\t@@\nTruncated\tfalse\n"
                    "julia-workbench-doc-v1\t1.13.1\tsearch\nScope\tYQ==\nTruncated\tyes\n"))
    (with-temp-buffer (insert export) (should-error (julia-workbench--doc-parse "search" "x"))))
  (with-temp-buffer
    (insert (workbench-doc-export "search" "sine" '("Base.sin" "Base.sin")))
    (should-error (julia-workbench--doc-parse "search" "sine"))))

(ert-deftest workbench-doc-context-invalidation ()
  "Invalidate identities after content, selection, executable or environment changes."
  (workbench-doc-with-fixture
   (let ((initial (plist-get (julia-workbench--doc-context) :key)))
     (with-temp-file (expand-file-name "Manifest-v1.13.toml" directory) (insert "a = 1\n"))
     (should-not (equal initial (plist-get (julia-workbench--doc-context) :key))))
   (let ((initial (plist-get (julia-workbench--doc-context) :key)))
     (with-temp-file (expand-file-name "Manifest-v1.13.toml" directory) (insert "a = 2\n"))
     (should-not (equal initial (plist-get (julia-workbench--doc-context) :key))))
   (let ((initial (plist-get (julia-workbench--doc-context) :key)))
     (setq-local julia-workbench-documentation-packages '("Dates"))
     (should-not (equal initial (plist-get (julia-workbench--doc-context) :key))))
   (let ((initial (plist-get (julia-workbench--doc-context) :key)))
     (with-temp-file julia-workbench-julia-command (insert "#!/bin/sh\nexit 7\n"))
     (should-not (equal initial (plist-get (julia-workbench--doc-context) :key))))
   (setq-local julia-workbench-environment "missing")
   (should-error (julia-workbench--doc-context) :type 'user-error)))

(ert-deftest workbench-doc-opening-and-eldoc-never-launch ()
  "Opening a buffer and uncached ElDoc launch no runtime or helper."
  (workbench-doc-with-fixture
   (cl-letf (((symbol-function 'make-process) (lambda (&rest _) (ert-fail "Unexpected helper")))
             ((symbol-function 'call-process) (lambda (&rest _) (ert-fail "Unexpected probe"))))
     (julia-workbench-mode)
     (insert "Base.sin")
     (should (memq #'julia-workbench-documentation-eldoc eldoc-documentation-functions))
     (should-not (julia-workbench-documentation-eldoc #'ignore)))))

(ert-deftest workbench-doc-asynchronous-cache-and-eldoc ()
  "Cache an asynchronous result, then use it without starting a new helper."
  (workbench-doc-with-fixture
   (let* ((context (julia-workbench--doc-context))
          (process (julia-workbench-documentation "Base.sin")))
     (should (processp process))
     (insert "Base.sin")
     (workbench-doc-wait)
     (should-not (buffer-live-p (process-buffer process)))
     (should-not (buffer-live-p (process-get process 'log)))
     (should (file-exists-p (julia-workbench--doc-location context "lookup" "Base.sin")))
     (with-current-buffer "*Julia Documentation*"
       (should (string-match-p "α and 🐈" (buffer-string)))
       (should (derived-mode-p 'julia-workbench-documentation-mode)))
     (cl-letf (((symbol-function 'make-process) (lambda (&rest _) (ert-fail "Cache miss"))))
       (should-not (julia-workbench-documentation "Base.sin"))
       (let ((text nil))
         (should (julia-workbench-documentation-eldoc (lambda (value &rest _) (setq text value))))
         (should (string-match-p "α and 🐈" text)))))))

(ert-deftest workbench-doc-argument-vector-and-scope ()
  "Pass query/package arguments as data and restrict the helper load path."
  (workbench-doc-with-fixture
   (let* ((arguments (expand-file-name "arguments" directory))
          (query "quotes ' \" $() ; α 🐈")
          (julia-workbench-documentation-packages '("Dates" "Example")))
     (with-temp-file response-file (insert (workbench-doc-export "search" query)))
     (with-temp-file julia-workbench-julia-command
       (insert "#!/bin/sh\nprintf '%s\\n' \"$JULIA_LOAD_PATH\" \"$@\" > "
               (shell-quote-argument arguments) "\ncat " (shell-quote-argument response-file) "\n"))
     (set-file-modes julia-workbench-julia-command #o700)
     (julia-workbench-documentation-search query)
     (workbench-doc-wait)
     (with-temp-buffer
       (insert-file-contents arguments)
       (let ((lines (split-string (buffer-string) "\n" t)))
         (should (equal (car lines) "@:@stdlib"))
         (should (member query lines))
         (should (equal (last lines 2) '("Dates" "Example"))))))))

(ert-deftest workbench-doc-preserve-cache-on-failure ()
  "Failed refreshes preserve old documentation and retain actionable logs."
  (workbench-doc-with-fixture
   (let ((context (julia-workbench--doc-context)))
     (julia-workbench-documentation "Base.sin") (workbench-doc-wait)
     (dolist (script '("echo malformed" "echo package-failure >&2; exit 7"))
       (with-temp-file julia-workbench-julia-command (insert "#!/bin/sh\n" script "\n"))
       (set-file-modes julia-workbench-julia-command #o700)
       (let* ((failure nil)
              (process (julia-workbench--doc-request
                        context "lookup" "Base.sin" (lambda (_data err) (setq failure err)) t)))
         (workbench-doc-wait)
          (should failure)
          (should (buffer-live-p (process-get process 'log)))
          (when (string-match-p "package-failure" script)
            (with-current-buffer (process-get process 'log)
              (should (string-match-p "package-failure" (buffer-string)))))
          (should (julia-workbench--doc-cached context "lookup" "Base.sin")))))))

(ert-deftest workbench-doc-cancellation-timeout-and-bounds ()
  "Slow workers remain asynchronous, with cancellation, deadlines and job limits."
  (workbench-doc-with-fixture
   (with-temp-file julia-workbench-julia-command (insert "#!/bin/sh\nexec sleep 5\n"))
   (set-file-modes julia-workbench-julia-command #o700)
   (let* ((context (julia-workbench--doc-context))
          (julia-workbench-documentation-max-jobs 1)
          (process (julia-workbench-documentation "Base.sin")))
     (should (process-live-p process))
     (insert "Typing while the helper runs")
     (should-error (julia-workbench--doc-request context "search" "sine" #'ignore) :type 'user-error)
      (let ((original (buffer-string)))
        (julia-workbench-documentation-cancel)
        (should (equal original (buffer-string))))
     (workbench-doc-wait)
     (should-not (process-live-p process))
     (should-not (buffer-live-p (process-buffer process)))
     (should-not (julia-workbench--doc-cached context "lookup" "Base.sin")))
   (let ((julia-workbench-documentation-timeout 0))
     (julia-workbench-documentation "Base.sin")
     (workbench-doc-wait)
     (with-current-buffer "*Julia Documentation*" (should (string-match-p "timed out" (buffer-string)))))
   (with-temp-file julia-workbench-julia-command
     (insert "#!/bin/sh\ncat " (shell-quote-argument response-file) "\n"))
   (set-file-modes julia-workbench-julia-command #o700)
   (let ((julia-workbench-documentation-max-output 10))
     (julia-workbench-documentation "Base.sin") (workbench-doc-wait)
     (with-current-buffer "*Julia Documentation*" (should (string-match-p "output limit" (buffer-string)))))))

(ert-deftest workbench-doc-stale-environment-and-killed-buffer ()
  "Reject results after package settings change and clean up killed help buffers."
  (workbench-doc-with-fixture
   (with-temp-file julia-workbench-julia-command
     (insert "#!/bin/sh\nsleep 0.1\ncat " (shell-quote-argument response-file) "\n"))
   (set-file-modes julia-workbench-julia-command #o700)
   (julia-workbench-documentation "Base.sin")
   (setq-local julia-workbench-documentation-packages '("Dates"))
   (workbench-doc-wait)
   (with-current-buffer "*Julia Documentation*"
     (should (string-match-p "settings changed" (buffer-string))))
   (let ((process (julia-workbench-documentation "Base.sin")))
     (kill-buffer "*Julia Documentation*")
     (workbench-doc-wait)
     (should-not (process-live-p process))
     (should-not (get-buffer "*Julia Documentation*")))))

(ert-deftest workbench-doc-new-request-wins ()
  "A newer request supersedes the older job without cancellation replacing output."
  (workbench-doc-with-fixture
   (with-temp-file julia-workbench-julia-command
     (insert "#!/bin/sh\nsleep 0.1\ncat " (shell-quote-argument response-file) "\n"))
   (set-file-modes julia-workbench-julia-command #o700)
   (let ((old (julia-workbench-documentation "old")))
     (julia-workbench-documentation "Base.sin") (workbench-doc-wait)
     (should-not (process-live-p old))
     (with-current-buffer "*Julia Documentation*"
       (should (string-match-p "Hello α" (buffer-string)))
       (should-not (string-match-p "cancelled" (buffer-string)))))))

(ert-deftest workbench-doc-buttons-history-and-refresh ()
  "Navigate search buttons, preserve context/history and refresh the displayed request."
  (workbench-doc-with-fixture
   (with-temp-file response-file (insert (workbench-doc-export "search" "sine" '("Base.sin"))))
   (julia-workbench-documentation-search "sine") (workbench-doc-wait)
   (with-temp-file response-file (insert (workbench-doc-export "lookup" "Base.sin")))
   (with-current-buffer "*Julia Documentation*"
     (goto-char (point-min)) (search-forward "Base.sin")
     (button-activate (button-at (1- (point)))))
   (workbench-doc-wait)
   (with-current-buffer "*Julia Documentation*"
     (should (string-match-p "Hello α" (buffer-string)))
     (julia-workbench-documentation-back)
     (should (string-match-p "Documentation search: sine" (buffer-string)))
     (julia-workbench-documentation-forward)
     (should (string-match-p "Hello α" (buffer-string)))
     (should (processp (julia-workbench-documentation-refresh))))
   (workbench-doc-wait)))

(ert-deftest workbench-doc-empty-and-missing-states ()
  "Display useful empty results, generated summaries and invalid cache states."
  (workbench-doc-with-fixture
   (with-temp-file response-file (insert (workbench-doc-export "search" "nothing")))
   (julia-workbench-documentation-search "nothing") (workbench-doc-wait)
   (with-current-buffer "*Julia Documentation*"
     (should (string-match-p "No documentation matches" (buffer-string))))
   (with-temp-file response-file
     (insert (replace-regexp-in-string "Documented\ttrue" "Documented\tfalse"
                                       (workbench-doc-export "lookup" "Base.sin" "Generated summary"))))
   (julia-workbench-documentation "Base.sin") (workbench-doc-wait)
   (with-current-buffer "*Julia Documentation*"
     (should (string-match-p "No docstring found" (buffer-string)))
     (should (string-match-p "Generated summary" (buffer-string))))
   (let* ((context (julia-workbench--doc-context))
          (file (julia-workbench--doc-location context "lookup" "Base.sin")))
     (with-temp-file file (insert "corrupt data"))
     (should-not (julia-workbench--doc-cached context "lookup" "Base.sin")))
   (should-error (julia-workbench-documentation-search "  ") :type 'user-error)))

(ert-deftest workbench-doc-named-completion ()
  "Build the named-symbol completion index asynchronously before lookup."
  (workbench-doc-with-fixture
   (with-temp-file response-file (insert (workbench-doc-export "names" "" '("Base.sin" "Base.@time"))))
   (let ((prompted nil))
     (cl-letf (((symbol-function 'completing-read)
                (lambda (_prompt candidates &rest _args)
                  (should (member "Base.@time" candidates))
                  (setq prompted t)
                  (with-temp-file response-file (insert (workbench-doc-export "lookup" "Base.sin")))
                  "Base.sin")))
       (should (processp (julia-workbench-documentation)))
       (should-not prompted)
       (workbench-doc-wait)
       (should prompted)
       (with-current-buffer "*Julia Documentation*" (should (string-match-p "Hello α" (buffer-string))))))
   (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () t))
             ((symbol-function 'completing-read) (lambda (&rest _) (ert-fail "Interrupted minibuffer"))))
     (should-not (julia-workbench-documentation))
     (with-current-buffer "*Julia Documentation*"
       (should (string-match-p "Base.@time" (buffer-string)))))))

(ert-deftest workbench-doc-eglot-and-official-manual ()
  "Keep connected ElDoc intact and show asynchronous hover and manual search."
  (workbench-doc-with-fixture
   (insert "Base.sin")
   (cl-letf (((symbol-function 'eglot-managed-p) (lambda () t))
             ((symbol-function 'eglot-current-server) (lambda () 'server))
             ((symbol-function 'julia-workbench--doc-hover)
              (lambda (callback _timeout) (funcall callback "Local signature α 🐈" nil))))
     (should-not (julia-workbench-documentation-eldoc #'ignore))
     (julia-workbench-documentation-at-point)
     (with-current-buffer "*Julia Documentation*" (should (string-match-p "Local signature" (buffer-string)))))
   (cl-letf (((symbol-function 'eglot-current-server) (lambda () 'server))
             ((symbol-function 'eglot--TextDocumentPositionParams) (lambda () '(:position (:line 0 :character 0))))
             ((symbol-function 'jsonrpc-async-request)
              (lambda (_server method _params &rest options)
                (should (eq method :textDocument/hover))
                (funcall (plist-get options :error-fn) '(:code -32603))
                (funcall (plist-get options :timeout-fn)))))
     (let ((failures nil))
       (julia-workbench--doc-hover (lambda (_text failure) (push failure failures)) 1)
       (should (string-match-p "timed out" (car failures)))
       (should (string-match-p "failed" (cadr failures)))))
   (let ((url nil))
     (cl-letf (((symbol-function 'browse-url) (lambda (value &rest _) (setq url value))))
       (julia-workbench-documentation-manual-search "α and +")
       (should (string-prefix-p "https://docs.julialang.org/en/v1/search/?q=" url))
       (should (string-match-p "%CE%B1%20and%20%2B" url))))))

(provide 'documentation-ui-tests)
;;; documentation-ui-tests.el ends here
