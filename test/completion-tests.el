;;; completion-tests.el --- Julia CAPF tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Unit tests need neither Julia nor a server.  Fake runtime exports exercise
;; the actual asynchronous setup and writable cache lifecycle.

;;; Code:

(require 'ert)
(require 'julia-workbench-completion)
(require 'eglot)

(defconst workbench-completion-export
  "julia-workbench-unicode-v1\t1.13.1\n\\alpha\tα\n\\:smile:\t😄\n\\hat\t̂\n\\_2\t₂\n\\1/2\t½\n"
  "Small runtime export, including astral and combining characters.")

(defmacro workbench-completion-with-cache (&rest body)
  "Run BODY with an isolated on-disk Unicode table and source buffer."
  (declare (indent 0) (debug t))
  `(let* ((directory (make-temp-file "workbench-completion-" t))
          (file (expand-file-name "unicode.tsv" directory))
          (julia-workbench--unicode-cache (make-hash-table :test #'equal))
          (julia-workbench-use-tree-sitter nil))
     (unwind-protect
         (progn
           (with-temp-file file (insert workbench-completion-export))
           (cl-letf (((symbol-function 'julia-workbench--unicode-location)
                      (lambda () (list "/unused/julia" file))))
             (with-temp-buffer
               (julia-workbench-mode)
               ,@body)))
       (delete-directory directory t))))

(defun workbench-completion-accept (capf name &optional status)
  "Accept NAME from CAPF with STATUS, default finished, as a UI would."
  (let* ((properties (nthcdr 3 capf))
         (candidate (car (member name (all-completions "" (nth 2 capf))))))
    (should candidate)
    (delete-region (nth 0 capf) (nth 1 capf))
    (goto-char (nth 0 capf))
    (insert candidate)
    (when-let* ((exit (plist-get properties :exit-function)))
      (funcall exit candidate (or status 'finished)))))

(ert-deftest workbench-completion-vanilla-unicode ()
  "Use the standard Emacs completion command after BMP and astral text."
  (workbench-completion-with-cache
    (insert "α = \"🚀\"; x = \\alpha")
    (should (completion-at-point))
    (should (equal (buffer-string) "α = \"🚀\"; x = α"))))

(ert-deftest workbench-completion-emoji-and-combining ()
  "Accept emoji, combining marks, subscripts and fraction inputs."
  (dolist (pair '(("\\:smile:" . "😄") ("\\hat" . "̂")
                  ("\\_2" . "₂") ("\\1/2" . "½")))
    (workbench-completion-with-cache
      (insert "x" (car pair))
      (should (completion-at-point))
      (should (equal (buffer-string) (concat "x" (cdr pair)))))))

(ert-deftest workbench-completion-docs-and-annotations ()
  "Unicode CAPF exposes a glyph and readable code-point documentation."
  (workbench-completion-with-cache
    (insert "\\:smi")
    (let* ((capf (julia-workbench-unicode-completion-at-point))
           (properties (nthcdr 3 capf))
           (doc (funcall (plist-get properties :company-doc-buffer) "\\:smile:")))
      (should (equal (funcall (plist-get properties :annotation-function) "\\:smile:") " 😄"))
      (with-current-buffer doc
        (should (string-match-p (regexp-quote "U+1F604") (buffer-string)))
        (should (string-match-p "1.13.1" (buffer-string))))
      (workbench-completion-accept capf "\\:smile:")
      (should (equal (buffer-string) "😄")))))

(ert-deftest workbench-completion-does-not-convert-unaccepted-input ()
  "A partial completion or cancelled selection does not insert a glyph."
  (workbench-completion-with-cache
    (insert "\\al")
    (workbench-completion-accept (julia-workbench-unicode-completion-at-point)
                                 "\\alpha" 'sole)
    (should (equal (buffer-string) "\\alpha"))))

(ert-deftest workbench-completion-contexts ()
  "Offer Unicode in code, comments and strings, decline escapes and operators."
  (workbench-completion-with-cache
    (dolist (prefix '("x = " "# " "s = \""))
      (erase-buffer) (insert prefix "\\al")
      (should (julia-workbench-unicode-completion-at-point)))
    (dolist (text '("\\\\alpha" "a \\ b" "Base.sin" "\\missing"))
      (erase-buffer) (insert text)
      (should-not (julia-workbench-unicode-completion-at-point)))))

(ert-deftest workbench-completion-no-runtime-on-open-or-capf ()
  "Opening files and invoking CAPFs never launch Julia or require a cache."
  (let ((exec-path nil) (julia-workbench-use-tree-sitter nil))
    (cl-letf (((symbol-function 'make-process) (lambda (&rest _) (ert-fail "Process started")))
              ((symbol-function 'call-process) (lambda (&rest _) (ert-fail "Process started"))))
      (with-temp-buffer
        (julia-workbench-mode)
        (insert "\\alpha")
        (should-not (julia-workbench-unicode-completion-at-point))
        (should-not (julia-workbench-path-completion-at-point))))))

(ert-deftest workbench-completion-cache-validation ()
  "Decline malformed data without evaluating it or breaking other CAPFs."
  (workbench-completion-with-cache
    (with-temp-file file (insert "#.(error \"evaluated\")\n"))
    (insert "\\alpha")
    (should-not (julia-workbench-unicode-completion-at-point)))
  (dolist (text '("julia-workbench-unicode-v1\t1.13.1\n"
                  "julia-workbench-unicode-v1\t1.13.1\n\\x\tx\n\\x\ty\n"
                  "julia-workbench-unicode-v1\t1.13.1\n\\x\t\n"))
    (with-temp-buffer
      (insert text)
      (should-error (julia-workbench--parse-unicode)))))

(ert-deftest workbench-completion-cache-identity ()
  "Different executables and replacement binaries use distinct cache files."
  (let* ((directory (make-temp-file "workbench-runtime-" t))
         (default-directory (file-name-as-directory directory))
         (julia-workbench-cache-directory (expand-file-name "cache" directory))
         (julia-workbench-julia-command (expand-file-name "julia" directory)))
    (unwind-protect
        (progn
          (with-temp-file julia-workbench-julia-command (insert "#!/bin/sh\nexit 0\n"))
          (set-file-modes julia-workbench-julia-command #o700)
          (let ((original (cadr (julia-workbench--unicode-location))))
            (with-temp-file julia-workbench-julia-command (insert "#!/bin/sh\nexit 12345\n"))
            (should-not (equal original (cadr (julia-workbench--unicode-location))))
            (should-not (file-exists-p julia-workbench-cache-directory))))
      (delete-directory directory t))))

(ert-deftest workbench-completion-paths-and-spaces ()
  "Standard file completion handles paths and spaces after Unicode text."
  (let* ((directory (make-temp-file "workbench-path-" t))
         (default-directory (file-name-as-directory directory))
         (julia-workbench-use-tree-sitter nil))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "data file.txt" directory))
          (make-directory (expand-file-name "nested" directory))
          (with-temp-buffer
            (julia-workbench-mode)
            (insert "α = \"🚀\"; include(\"data f")
            (should (completion-at-point))
            (should (equal (buffer-string) "α = \"🚀\"; include(\"data file.txt"))
            (erase-buffer) (insert "include(\"nest")
            (should (completion-at-point))
            (should (equal (buffer-string) "include(\"nested/"))))
      (delete-directory directory t))))

(ert-deftest workbench-completion-path-contexts ()
  "Paths do not claim symbols, comments, escapes or interpolated strings."
  (let ((julia-workbench-use-tree-sitter nil))
    (with-temp-buffer
      (julia-workbench-mode)
      (dolist (text '("Base.si" "# \"data" "x = \"$dir/data" "x = \"a\\n" "`command"))
        (erase-buffer) (insert text)
        (should-not (julia-workbench-path-completion-at-point))))))

(ert-deftest workbench-completion-provider-order ()
  "Keep provider ordering through management changes without duplicates."
  (let ((julia-workbench-use-tree-sitter nil))
    (with-temp-buffer
      (julia-workbench-mode)
      (setq-local eglot--managed-mode t)
      (add-hook 'completion-at-point-functions 'eglot-completion-at-point nil t)
      (add-hook 'completion-at-point-functions 'ignore t t)
      (julia-workbench--setup-completion)
      (julia-workbench--setup-completion)
      (should (equal (seq-take completion-at-point-functions 3)
                     '(julia-workbench-unicode-completion-at-point
                       julia-workbench-path-completion-at-point julia-workbench-semantic-completion-at-point)))
      (should (memq 'ignore completion-at-point-functions))
      (add-hook 'completion-at-point-functions 'eglot-completion-at-point nil t)
      (julia-workbench--setup-completion)
      (should (= 1 (cl-count #'julia-workbench-semantic-completion-at-point completion-at-point-functions)))
      (setq-local eglot--managed-mode nil)
      (julia-workbench--setup-completion)
      (should-not (memq #'julia-workbench-semantic-completion-at-point completion-at-point-functions)))))

(ert-deftest workbench-completion-semantic-signatures-and-edits ()
  "Show types even without a docstring, retaining the server edit callback."
  (let* ((edited nil)
         (candidate (propertize "convert_value" 'eglot--lsp-item '(:kind 3)))
         (table (list candidate))
         (original (list 1 4 table :company-docsig (lambda (_) "convert_value(x::Int)::String")
                         :company-doc-buffer (lambda (_) nil)
                         :exit-function (lambda (_ status) (setq edited status) (insert "!")))))
    (cl-letf (((symbol-function 'eglot-completion-at-point) (lambda () original)))
      (with-temp-buffer
        (insert "con")
        (let* ((capf (julia-workbench-semantic-completion-at-point))
               (properties (nthcdr 3 capf))
               (buffer (funcall (plist-get properties :company-doc-buffer) candidate)))
          (should (eq table (nth 2 capf)))
          (should (equal (seq-take capf 2) '(1 4)))
          (with-current-buffer buffer
            (should (equal (buffer-string) "convert_value(x::Int)::String\n\n")))
          (workbench-completion-accept capf "convert_value")
          (should (eq edited 'finished))
          (should (equal (buffer-string) "convert_value!")))))))

(ert-deftest workbench-completion-semantic-doc-signature ()
  "Use a typed doc signature when the server's detail is only a kind."
  (let ((doc (generate-new-buffer " *test completion docs*")))
    (unwind-protect
        (progn
          (with-current-buffer doc (insert "    f(x::AbstractString)\n\nDocumentation."))
          (should (equal (julia-workbench--completion-signature
                          "f" (list :company-docsig (lambda (_) "Function")
                                    :company-doc-buffer (lambda (_) doc)))
                         "f(x::AbstractString)")))
      (kill-buffer doc))))

(defun workbench-completion-wait (process)
  "Wait at most ten seconds for export PROCESS and its sentinel."
  (let ((deadline (+ (float-time) 10)))
    (while (process-live-p process)
      (when (> (float-time) deadline) (ert-fail "Export did not finish"))
      (accept-process-output nil 0.05))))

(ert-deftest workbench-completion-asynchronous-export ()
  "Run setup through a fake runtime, then complete from its on-disk cache."
  (let* ((directory (make-temp-file "workbench-export-" t))
         (default-directory (file-name-as-directory directory))
         (julia-workbench-cache-directory (expand-file-name "cache" directory))
         (julia-workbench-julia-command (expand-file-name "julia" directory))
         (julia-workbench-use-tree-sitter nil))
    (unwind-protect
        (progn
          (with-temp-file julia-workbench-julia-command
            (insert "#!/bin/sh\ncat <<'DATA'\n" workbench-completion-export "DATA\n"))
          (set-file-modes julia-workbench-julia-command #o700)
          (with-temp-buffer
            (julia-workbench-mode)
            (let ((process (julia-workbench-setup-unicode)))
              (workbench-completion-wait process)
              (should (zerop (hash-table-count julia-workbench--unicode-jobs)))
              (should (file-exists-p (cadr (julia-workbench--unicode-location))))
              (should-not (buffer-live-p (process-buffer process)))
              (insert "\\alpha")
              (should (completion-at-point))
              (should (equal (buffer-string) "α")))))
      (delete-directory directory t))))

(ert-deftest workbench-completion-failure-cancellation-and-timeout ()
  "Preserve a good cache after invalid output, failure, cancellation or timeout."
  (workbench-completion-with-cache
    (let* ((executable (expand-file-name "fake-julia" directory))
           (julia-workbench--unicode-jobs (make-hash-table :test #'equal)))
      (cl-letf (((symbol-function 'julia-workbench--unicode-location)
                 (lambda () (list executable file))))
        (dolist (script '("echo broken" "exit 7" "sleep 5"))
          (with-temp-file executable (insert "#!/bin/sh\n" script "\n"))
          (set-file-modes executable #o700)
          (let ((process (julia-workbench-setup-unicode)))
            (when (equal script "sleep 5")
              (should-error (julia-workbench-setup-unicode) :type 'user-error)
              (julia-workbench-cancel-unicode-setup))
            (workbench-completion-wait process)
            (should-not (buffer-live-p (process-buffer process)))
            (should (zerop (hash-table-count julia-workbench--unicode-jobs)))
            (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                           workbench-completion-export))))
        (let ((julia-workbench-unicode-setup-timeout 0))
          (let ((process (julia-workbench-setup-unicode)))
            (workbench-completion-wait process)
            (should (eq (process-status process) 'signal))
            (should (zerop (hash-table-count julia-workbench--unicode-jobs)))))))))

(provide 'completion-tests)
;;; completion-tests.el ends here
