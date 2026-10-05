;;; repl-tests.el --- Julia REPL unit fixtures -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Process-independent checks for scope, encoded source, framing and cleanup.

;;; Code:

(require 'ert)
(require 'julia-workbench-repl)

(when-let* ((path (getenv "JULIA_WORKBENCH_GRAMMAR_PATH")))
  (add-to-list 'treesit-extra-load-path path)
  (unless (treesit-ready-p 'julia t) (error "Julia grammar unavailable: %s" path)))

(defun workbench-repl-frame (id kind status text)
  "Return a hidden response for ID, KIND, STATUS and TEXT."
  (format "\036test-token\t%s\t%s\t%s\t%s\037"
          id kind status (julia-workbench--repl-encode text)))

(ert-deftest workbench-repl-exit-with-read-only-prompt ()
  "Retain exit status output when the process mark touches a protected prompt."
  (with-temp-buffer
    (julia-workbench-repl-mode)
    (insert (propertize "julia> " 'read-only t 'front-sticky '(read-only)))
    (let ((process (make-pipe-process :name "workbench-exit-test" :buffer (current-buffer)
                                      :noquery t :sentinel #'ignore)))
      (unwind-protect
          (progn
            (set-marker (process-mark process) (point-max))
            (delete-process process)
            (process-put process 'julia-workbench-original-sentinel
                         #'internal-default-process-sentinel)
            (julia-workbench--repl-sentinel process "finished\n")
            (should (eq julia-workbench--repl-state 'stopped))
            (should (string-match-p "finished" (buffer-string)))
            (should (get-text-property (point-min) 'read-only)))
        (when (process-live-p process) (delete-process process))))))

(ert-deftest workbench-repl-opening-does-not-launch ()
  "Opening source and loading the adapter must not start a process."
  (cl-letf (((symbol-function 'make-process) (lambda (&rest _) (ert-fail "Unexpected process"))))
    (let ((julia-workbench-use-tree-sitter nil))
      (with-temp-buffer (julia-workbench-mode)))))

(ert-deftest workbench-repl-scope-and-isolation ()
  "Scope sessions by workspace/environment/runtime/options, independent of LSP."
  (let* ((directory (make-temp-file "workbench-repl-scope-" t))
         (default-directory (file-name-as-directory directory))
         (julia-workbench-cache-directory (expand-file-name "cache" directory)))
    (unwind-protect
        (cl-letf (((symbol-function 'julia-workbench--executable) (lambda (_) "/bin/sh")))
          (with-temp-file (expand-file-name "Project.toml" directory) (insert "[deps]\n"))
          (with-temp-buffer
            (let* ((first (julia-workbench--repl-settings))
                   (julia-workbench-server-command '("other-server"))
                   (julia-workbench-server-project "/other-tooling"))
              (should (equal (plist-get first :key) (plist-get (julia-workbench--repl-settings) :key)))
              (let ((julia-workbench-environment "nested"))
                (should-not (equal (plist-get first :key) (plist-get (julia-workbench--repl-settings) :key))))
              (let ((julia-workbench-repl-arguments '("--threads=auto")))
                (should-not (equal (plist-get first :key) (plist-get (julia-workbench--repl-settings) :key))))
              (delete-file (expand-file-name "Project.toml" directory))
              (let ((standalone (julia-workbench--repl-settings)))
                (should (plist-get standalone :standalone))
                (should-not (file-exists-p (plist-get standalone :environment)))))))
      (delete-directory directory t))))

(ert-deftest workbench-repl-fragmented-output ()
  "Hide frames split at every possible boundary, preserving visible Unicode."
  (let ((output (concat "printed α 🐈\n" (workbench-repl-frame 0 "ready" "ok" "1.13.1") "julia> ")))
    (dotimes (boundary (1+ (length output)))
      (with-temp-buffer
        (julia-workbench-repl-mode)
        (setq julia-workbench--repl-token "test-token" julia-workbench--repl-state 'starting)
        (should (equal (concat (julia-workbench--repl-filter (substring output 0 boundary))
                               (julia-workbench--repl-filter (substring output boundary)))
                       "printed α 🐈\njulia> "))
        (should (eq julia-workbench--repl-state 'idle))
        (should (equal julia-workbench--repl-version "1.13.1"))
        (should (equal julia-workbench--repl-fragment ""))))))

(ert-deftest workbench-repl-results-and-stale-records ()
  "Copy only successful values; errors/stale replies preserve the old result."
  (with-temp-buffer
    (julia-workbench-repl-mode)
    (setq julia-workbench--repl-token "test-token"
          julia-workbench--repl-state 'busy
          julia-workbench--repl-last-result "old"
          julia-workbench--repl-pending '(:id 2 :kind "eval"))
    (julia-workbench--repl-filter (workbench-repl-frame 1 "eval" "ok" "stale"))
    (should (eq julia-workbench--repl-state 'busy))
    (should (equal julia-workbench--repl-last-result "old"))
    (julia-workbench--repl-filter (workbench-repl-frame 2 "eval" "error" "failure"))
    (should (equal julia-workbench--repl-last-result "old"))
    (setq julia-workbench--repl-pending '(:id 3 :kind "eval"))
    (julia-workbench--repl-filter (workbench-repl-frame 3 "eval" "ok" "\"α 🐈\""))
    (should (equal julia-workbench--repl-last-result "\"α 🐈\""))
    (cl-letf (((symbol-function 'julia-workbench--repl-buffer) (lambda (&rest _) (current-buffer))))
      (julia-workbench-copy-last-eval-result)
      (should (equal (current-kill 0) "\"α 🐈\"")))))

(ert-deftest workbench-repl-ordinary-control-output ()
  "Preserve ordinary control-character output without waiting for a frame."
  (with-temp-buffer
    (julia-workbench-repl-mode)
    (setq julia-workbench--repl-token "test-token")
    (should (equal (julia-workbench--repl-filter "\036ordinary stdout\n") "\036ordinary stdout\n"))
    (should (equal julia-workbench--repl-fragment ""))
    (should (equal (julia-workbench--repl-filter "\036other-token\t0\037") "\036other-token\t0\037"))))

(ert-deftest workbench-repl-callback-failure-does-not-stall ()
  "A failed UI callback must not stall queued Julia evaluations."
  (with-temp-buffer
    (julia-workbench-repl-mode)
    (setq julia-workbench--repl-token "test-token" julia-workbench--repl-state 'busy
          julia-workbench--repl-pending (list :id 1 :kind "eval" :callback (lambda (&rest _) (error "UI failure")))
          julia-workbench--repl-queue '((:id 2 :kind "eval" :wire "next")))
    (let (sent)
      (cl-letf (((symbol-function 'comint-send-string) (lambda (_ wire) (setq sent wire))))
        (julia-workbench--repl-filter (workbench-repl-frame 1 "eval" "ok" "1"))
        (should (equal sent "next"))
        (should (= (plist-get julia-workbench--repl-pending :id) 2))))))

(ert-deftest workbench-repl-empty-source-and-invalid-environment ()
  "Reject empty sends before launch and explain missing or remote environments."
  (with-temp-buffer
    (insert "  ")
    (cl-letf (((symbol-function 'julia-workbench--repl-buffer) (lambda (&rest _) (ert-fail "Unexpected launch"))))
      (should-error (julia-workbench-send-line) :type 'user-error)))
  (let ((directory (make-temp-file "workbench-repl-invalid-" t)))
    (unwind-protect
        (should-error (julia-workbench--repl-start (list :environment directory :cache directory))
                      :type 'user-error)
      (delete-directory directory t))))

(ert-deftest workbench-repl-queue-and-safe-source ()
  "Queue during startup, send in order, and encode source rather than interpolate it."
  (with-temp-buffer
    (julia-workbench-repl-mode)
    (setq julia-workbench--repl-token "test-token" julia-workbench--repl-state 'starting)
    (let (sent)
      (cl-letf (((symbol-function 'comint-check-proc) (lambda (_) t))
                ((symbol-function 'comint-send-string) (lambda (_ wire) (push wire sent))))
        (julia-workbench--repl-request (current-buffer) "eval" "\"$(`α 🐈`)\"\n1" "/path with \"quotes\".jl" 7)
        (julia-workbench--repl-request (current-buffer) "eval" "2" "REPL" 1)
        (should-not sent)
        (julia-workbench--repl-filter (workbench-repl-frame 0 "ready" "ok" "1.13.1"))
        (should (= (length sent) 1))
        (should-not (string-match-p "α\|quotes" (car sent)))
        (should (string-match-p ", 7);\n" (car sent)))
        (julia-workbench--repl-filter (workbench-repl-frame 1 "eval" "ok" "1"))
        (should (= (length sent) 2))
        (should (string-prefix-p "WorkbenchREPL.request(2," (car sent)))
        (should (eq julia-workbench--repl-state 'busy))
        (julia-workbench--repl-filter (workbench-repl-frame 2 "eval" "ok" "2"))
        (should (eq julia-workbench--repl-state 'idle))
        (let ((julia-workbench-repl-queue-limit 0))
          (should-error (julia-workbench--repl-request (current-buffer) "eval" "3" "REPL" 1)
                        :type 'user-error))))))

(ert-deftest workbench-repl-source-lines-and-unsaved-content ()
  "Use absolute line numbers under narrowing; buffer evaluation includes unsaved text."
  (with-temp-buffer
    (insert "# first\n# second\nα = 2\nα + 3\n")
    (setq buffer-file-name "/tmp/α 🐈.jl")
    (let (request)
      (cl-letf (((symbol-function 'julia-workbench--repl-buffer) (lambda (&rest _) (current-buffer)))
                ((symbol-function 'julia-workbench--repl-request) (lambda (&rest args) (setq request args)))
                ((symbol-function 'display-buffer) #'ignore))
        (narrow-to-region 18 (point-max))
        (goto-char (point-min))
        (julia-workbench-send-line)
        (should (= (nth 4 request) 3))
        (julia-workbench-send-buffer)
        (should (equal (nth 2 request) "# first\n# second\nα = 2\nα + 3\n"))
        (should (= (nth 4 request) 1))
        (should-error (julia-workbench-send-buffer-file) :type 'user-error)))))

(ert-deftest workbench-repl-structured-selection ()
  "Select the whole containing form, declining missing grammars and incomplete trees."
  (with-temp-buffer
    (let ((julia-workbench-use-tree-sitter nil)) (julia-workbench-mode))
    (insert "x = 1")
    (should-error (julia-workbench-send-top-level-form) :type 'user-error))
  (skip-unless (treesit-ready-p 'julia t))
  (with-temp-buffer
    (insert "module Outer\nfunction inner(x)\n  x + 1\nend\nend\n")
    (julia-workbench-mode)
    (goto-char (point-min)) (search-forward "x + 1")
    (let (selected)
      (cl-letf (((symbol-function 'julia-workbench--repl-send)
                 (lambda (start end) (setq selected (buffer-substring start end)))))
        (julia-workbench-send-top-level-form)
        (should (string-prefix-p "module Outer" selected))
        (goto-char (point-max)) (delete-char -5)
        (goto-char (point-min)) (search-forward "x + 1")
        (should-error (julia-workbench-send-top-level-form) :type 'user-error)))))

(ert-deftest workbench-repl-interrupt-discards-queued-work ()
  "Interrupt the running request but never execute queued work afterwards."
  (with-temp-buffer
    (julia-workbench-repl-mode)
    (setq julia-workbench--repl-pending '(:id 1 :kind "eval")
          julia-workbench--repl-token "test-token" julia-workbench--repl-state 'busy)
    (let (cancelled interrupted)
      (setq julia-workbench--repl-queue
            (list (list :callback (lambda (ok _text) (setq cancelled (not ok))))))
      (cl-letf (((symbol-function 'julia-workbench--repl-buffer) (lambda (&rest _) (current-buffer)))
                ((symbol-function 'interrupt-process) (lambda (&rest _) (setq interrupted t))))
        (julia-workbench-repl-interrupt)
        (should interrupted) (should cancelled)
        (should julia-workbench--repl-pending) (should-not julia-workbench--repl-queue)
        (julia-workbench--repl-filter (workbench-repl-frame 1 "eval" "error" "InterruptException"))
        (should (eq julia-workbench--repl-state 'idle))))))

(ert-deftest workbench-repl-query-source-staleness ()
  "Reject asynchronous completion after text or point changes."
  (with-temp-buffer
    (insert "α 🐈 runtime_na")
    (let (callback inserted)
      (cl-letf (((symbol-function 'julia-workbench--repl-buffer) (lambda (&rest _) (current-buffer)))
                ((symbol-function 'julia-workbench--repl-request)
                 (lambda (_buffer _kind _source _filename _line function &rest _) (setq callback function)))
                ((symbol-function 'completion-in-region)
                 (lambda (start stop names &rest _) (setq inserted (list start stop names)))))
        (julia-workbench-repl-complete)
        (funcall callback t (concat "4\t14\n" (julia-workbench--repl-encode "runtime_name")))
        (should (equal inserted '(5 15 ("runtime_name"))))
        (setq inserted nil)
        (insert "moved")
        (funcall callback t (concat "4\t14\n" (julia-workbench--repl-encode "runtime_name")))
        (should-not inserted)))))

(ert-deftest workbench-repl-cleanup-and-startup-deadline ()
  "Startup timeout and killing the buffer cancel workers and registry entries."
  (with-temp-buffer
    (julia-workbench-repl-mode)
    (setq julia-workbench--repl-context '(:key ("test"))
          julia-workbench--repl-state 'starting)
    (puthash '("test") (current-buffer) julia-workbench--repl-sessions)
    (let (deleted)
      (cl-letf (((symbol-function 'get-buffer-process) (lambda (_) 'fake))
                ((symbol-function 'comint-output-filter) #'ignore)
                ((symbol-function 'delete-process) (lambda (_) (setq deleted t))))
        (julia-workbench--repl-deadline (current-buffer) 'fake)
        (should deleted)
        (julia-workbench--repl-cleanup)
        (should-not (gethash '("test") julia-workbench--repl-sessions))
        (setq julia-workbench--repl-context nil)))))

(provide 'repl-tests)
;;; repl-tests.el ends here
