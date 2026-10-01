;;; documentation-integration-tests.el --- Live Julia documentation -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Exercise the public asynchronous UI against real, already installed Julia.
;; No language server, downloads or package installation is needed.

;;; Code:

(require 'ert)
(require 'julia-workbench-doc)

(defconst workbench-doc-integration-directory
  (file-name-directory (or load-file-name buffer-file-name)))
(defvar workbench-doc-integration-timings nil
  "Elapsed UI worker and cache durations recorded by the live fixtures.")

(defmacro workbench-doc-live-fixture (&rest body)
  "Run BODY in a disposable project with actual Julia and writable caches."
  (declare (indent 0) (debug t))
  `(let* ((directory (make-temp-file "workbench-doc-live-" t))
          (fixture (expand-file-name "Example" directory))
          (julia-workbench-cache-directory (expand-file-name "cache" directory))
          (julia-workbench-julia-command (or (getenv "JULIA") "julia"))
          (julia-workbench-use-tree-sitter nil)
          (source (generate-new-buffer " *Julia live docs*")))
     (unwind-protect
         (progn
           (copy-directory (expand-file-name "fixtures/Example" workbench-doc-integration-directory)
                           fixture nil t t)
           (with-current-buffer source
             (setq default-directory (file-name-as-directory fixture))
             (julia-workbench-mode)
             ,@body))
       (julia-workbench--doc-cleanup)
       (when-let* ((buffer (get-buffer "*Julia Documentation*"))) (kill-buffer buffer))
       (when (buffer-live-p source) (kill-buffer source))
       (delete-directory directory t))))

(defun workbench-doc-live-wait ()
  "Wait at most forty seconds for asynchronous workers and UI callbacks."
  (let ((deadline (+ (float-time) 40)))
    (while (> (hash-table-count julia-workbench--doc-jobs) 0)
      (when (> (float-time) deadline) (ert-fail "Documentation helper timed out"))
      (accept-process-output nil 0.05))))

(defun workbench-doc-live-text ()
  "Return current persistent help text."
  (with-current-buffer "*Julia Documentation*" (buffer-string)))

(defun workbench-doc-live-time (label function)
  "Run FUNCTION and await workers, recording elapsed time under LABEL."
  (let ((start (float-time)))
    (funcall function)
    (workbench-doc-live-wait)
    (push (cons label (- (float-time) start)) workbench-doc-integration-timings)))

(ert-deftest workbench-doc-live-lookup-search-and-completion ()
  "Check real Base, project/std-library docs, name completion and cached UI."
  (workbench-doc-live-fixture
   (let ((timer-fired nil))
     (run-at-time 0 nil (lambda () (setq timer-fired t)))
     (workbench-doc-live-time "fresh-base-lookup"
                              (lambda ()
                                (let ((process (julia-workbench-documentation "Base.sin")))
                                  (should (process-live-p process))
                                  (insert "Typing α 🐈 while Julia loads\n"))))
     (should timer-fired))
   (should (string-match-p "sine" (workbench-doc-live-text)))
   (workbench-doc-live-time "cached-base-lookup"
                            (lambda () (should-not (julia-workbench-documentation "Base.sin"))))
   (workbench-doc-live-time "unselected-package-search"
                            (lambda () (julia-workbench-documentation-search "quasarotter")))
   (should (string-match-p "No documentation matches" (workbench-doc-live-text)))
   (julia-workbench-documentation-select-packages '("WorkbenchExample" "Dates"))
   (workbench-doc-live-time "selected-package-search"
                            (lambda () (julia-workbench-documentation-search "quasarotter")))
   (should (string-match-p "WorkbenchExample.greet" (workbench-doc-live-text)))
   (should (string-match-p "explicit packages: Dates, WorkbenchExample" (workbench-doc-live-text)))
   (with-current-buffer "*Julia Documentation*"
     (goto-char (point-min)) (search-forward "WorkbenchExample.greet")
     (button-activate (button-at (1- (point)))))
   (workbench-doc-live-wait)
   (should (string-match-p "greet(name)" (workbench-doc-live-text)))
   (should (string-match-p "α and 🐈" (workbench-doc-live-text)))
   (julia-workbench-documentation "Dates.Date") (workbench-doc-live-wait)
   (should (string-match-p "Date" (workbench-doc-live-text)))
   (julia-workbench-documentation "WorkbenchExample.undocumented") (workbench-doc-live-wait)
   (should (string-match-p "No docstring found" (workbench-doc-live-text)))
   (let ((prompted nil))
     (cl-letf (((symbol-function 'completing-read)
                (lambda (_prompt names &rest _args)
                  (should (member "Base.@time" names))
                  (should (member "WorkbenchExample.greet" names))
                  (setq prompted t) "WorkbenchExample.greet")))
       (workbench-doc-live-time "name-index-and-cached-lookup" #'julia-workbench-documentation)
       (should prompted)))
   (let ((results (expand-file-name "results/documentation-ui-timings.el"
                                    workbench-doc-integration-directory)))
     (make-directory (file-name-directory results) t)
     (with-temp-file results
       (insert ";; Elapsed seconds including asynchronous process completion.\n")
       (prin1 (reverse workbench-doc-integration-timings) (current-buffer))))))

(ert-deftest workbench-doc-live-standalone-and-errors ()
  "Use a private empty standalone environment and report helper errors."
  (workbench-doc-live-fixture
   (delete-file (expand-file-name "Project.toml" fixture))
   (let ((context (julia-workbench--doc-context)))
     (should (plist-get context :standalone))
     (should-not (file-exists-p (plist-get context :environment)))
     (julia-workbench-documentation "Base.@time") (workbench-doc-live-wait)
     (should (string-match-p "time" (workbench-doc-live-text)))
     (should (file-exists-p (expand-file-name "Project.toml" (plist-get context :environment))))
     (should (julia-workbench--doc-cached context "lookup" "Base.@time")))
   (julia-workbench-documentation "exit()") (workbench-doc-live-wait)
   (should (string-match-p "exited abnormally" (workbench-doc-live-text)))
   (let ((context (julia-workbench--doc-context)))
     (should-not (julia-workbench--doc-cached context "lookup" "exit()")))
   (julia-workbench-documentation-select-packages '("WorkbenchPackageThatDoesNotExist"))
   (julia-workbench-documentation "Base.sin") (workbench-doc-live-wait)
   (should (string-match-p "exited abnormally" (workbench-doc-live-text)))))

(ert-deftest workbench-doc-live-two-environments ()
  "Separate selected docs by environment and invalidate after project-file changes."
  (workbench-doc-live-fixture
   (julia-workbench-documentation-select-packages '("WorkbenchExample"))
   (julia-workbench-documentation "WorkbenchExample.greet") (workbench-doc-live-wait)
   (let* ((context (julia-workbench--doc-context))
          (other (expand-file-name "Other" directory)))
     (copy-directory (expand-file-name "fixtures/Other" workbench-doc-integration-directory)
                     other nil t t)
     (setq-local julia-workbench-environment other)
     (julia-workbench-documentation-select-packages '("WorkbenchOther"))
     (julia-workbench-documentation-search "quasarotter") (workbench-doc-live-wait)
     (should (string-match-p "No documentation matches" (workbench-doc-live-text)))
     (should-not (equal (plist-get context :key) (plist-get (julia-workbench--doc-context) :key)))
     (setq-local julia-workbench-environment nil)
     (julia-workbench-documentation-select-packages '("WorkbenchExample"))
     (should-not (julia-workbench-documentation "WorkbenchExample.greet"))
     (with-temp-file (expand-file-name "Manifest.toml" fixture)
       (insert "# A project change invalidates the old documentation cache.\n"))
     (should-not (julia-workbench--doc-cached (julia-workbench--doc-context)
                                              "lookup" "WorkbenchExample.greet")))))

(provide 'documentation-integration-tests)
;;; documentation-integration-tests.el ends here
