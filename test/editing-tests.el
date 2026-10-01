;;; editing-tests.el --- Julia editing regression fixtures -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Run with Emacs -Q --batch -L . -l test/editing-tests.el
;; -f ert-run-tests-batch-and-exit.  Set JULIA_WORKBENCH_GRAMMAR_PATH to
;; an existing grammar directory for required structural tests.  Otherwise
;; those tests skip if the standard Emacs search path has no Julia grammar.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'imenu)
(require 'julia-workbench)

(defconst workbench-editing-test-directory
  (file-name-directory (or load-file-name buffer-file-name)))

(when-let* ((path (getenv "JULIA_WORKBENCH_GRAMMAR_PATH")))
  (add-to-list 'treesit-extra-load-path path)
  (unless (treesit-ready-p 'julia t)
    (error "Julia grammar unavailable at JULIA_WORKBENCH_GRAMMAR_PATH=%s" path)))

(defun workbench-editing-test-fixture ()
  "Return the representative Julia editing fixture."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "fixtures/editing.jl" workbench-editing-test-directory))
    (buffer-string)))

(defun workbench-editing-test-state (needle)
  "Return syntax state inside the first occurrence of NEEDLE."
  (save-excursion
    (goto-char (point-min))
    (search-forward needle)
    (syntax-ppss (1- (point)))))

(defmacro workbench-editing-test-with-treesit (text &rest body)
  "Enter a Julia grammar buffer containing TEXT and execute BODY."
  (declare (indent 1) (debug t))
  `(progn
     (skip-unless (treesit-ready-p 'julia t))
     (with-temp-buffer
       (insert ,text)
       (let ((julia-workbench-use-tree-sitter t))
         (cl-letf (((symbol-function 'display-warning)
                    (lambda (&rest args) (ert-fail args))))
           (julia-workbench-mode)))
       (should julia-workbench--tree-sitter-active)
       ,@body)))

(ert-deftest workbench-editing-basic-without-tools ()
  (let ((julia-workbench-use-tree-sitter nil)
        (exec-path nil))
    (with-temp-buffer
      (insert (workbench-editing-test-fixture))
      (julia-workbench-mode)
      (should (derived-mode-p 'prog-mode))
      (should-not (treesit-parser-list))
      (font-lock-ensure)
      (should (nth 4 (workbench-editing-test-state "Still the outer")))
      (should-not (nth 4 (workbench-editing-test-state "abstract type")))
      (should (nth 3 (workbench-editing-test-state "literal \"quotes\"")))
      (should-not (nth 3 (workbench-editing-test-state "function greet!")))
      (dolist (text '("letter = 'λ" "newline = '\\n" "apostrophe = '\\'"))
        (should (nth 3 (workbench-editing-test-state text))))
      (dolist (text '("transpose = α'" "chained = [1 2; 3 4]'" "@show"))
        (should-not (nth 3 (workbench-editing-test-state text))))
      (goto-char (point-min))
      (comment-region (line-beginning-position) (line-end-position))
      (should (looking-at "# module"))
      (uncomment-region (line-beginning-position) (line-end-position))
      (should (looking-at "module"))
      (should-error (julia-workbench-mark-top-level) :type 'user-error))
    (with-temp-buffer
      (insert "    previous\nnextvalue\n")
      (julia-workbench-mode)
      (goto-char (point-min))
      (forward-line 1)
      (forward-char 4)
      (indent-according-to-mode)
      (should (equal (buffer-string) "    previous\n    nextvalue\n"))
      (should (looking-at "value")))))

(ert-deftest workbench-editing-grammar-unavailable ()
  (cl-letf (((symbol-function 'treesit-ready-p) (lambda (&rest _) nil)))
    (with-temp-buffer
      (julia-workbench-mode)
      (should-not julia-workbench--tree-sitter-active)
      (should (eq indent-line-function #'julia-workbench--indent-basic)))))

(ert-deftest workbench-editing-file-and-script-selection ()
  (let ((julia-workbench-use-tree-sitter nil))
    (with-temp-buffer
      (setq buffer-file-name "/tmp/workbench-script.jl")
      (set-auto-mode)
      (should (eq major-mode 'julia-workbench-mode)))
    (with-temp-buffer
      (insert "#!/usr/bin/env julia\nprintln(1)\n")
      (set-auto-mode)
      (should (eq major-mode 'julia-workbench-mode)))))

(ert-deftest workbench-editing-multiline-syntax-and-edits ()
  (let ((julia-workbench-use-tree-sitter nil))
    (with-temp-buffer
      (insert "x = \"\"\"first\n\"quoted\" # text\nlast\"\"\"\ny = 'a'\nz = x'\n")
      (julia-workbench-mode)
      (syntax-propertize (point-max))
      (should (nth 3 (workbench-editing-test-state "# text")))
      (should-not (nth 3 (workbench-editing-test-state "y =")))
      (goto-char (point-min))
      (search-forward "# text")
      (insert " and \"quotes\"")
      (should (nth 3 (workbench-editing-test-state "and \"quotes")))
      (should-not (nth 3 (workbench-editing-test-state "y =")))
      (goto-char (point-min))
      (search-forward "last\"\"\"")
      (delete-region (- (point) 3) (point))
      (should (nth 3 (workbench-editing-test-state "y =")))
      (insert "\"\"\"")
      (should-not (nth 3 (workbench-editing-test-state "y ="))))))

(ert-deftest workbench-editing-escaped-and-prefixed-literals ()
  (let ((julia-workbench-use-tree-sitter nil))
    (with-temp-buffer
      (insert "a = '\\u03bb'\nb = '\\U0001f9a6'\nc = '\\x41'\n"
              "text = raw\"\"\"quotes \"here\" and # text\nmore\"\"\"\n"
              "cmd = `echo hello`\nnext = A'\n")
      (julia-workbench-mode)
      (dolist (text '("\\u03bb" "\\U0001f9a6" "\\x41" "# text" "echo hello"))
        (should (nth 3 (workbench-editing-test-state text))))
      (should-not (nth 3 (workbench-editing-test-state "next = A'"))))))

(ert-deftest workbench-editing-comments-inside-literals ()
  (let ((julia-workbench-use-tree-sitter nil))
    (with-temp-buffer
      (insert "#triple quotes \"\"\" inside a line comment\nx = 1\n"
              "#= \"\"\" block #= nested =# still block =#\ny = 2\n"
              "text = \"#= a string =#\"\nz = 3\n")
      (julia-workbench-mode)
      (font-lock-ensure)
      (should (nth 4 (workbench-editing-test-state "inside a line")))
      (should (nth 4 (workbench-editing-test-state "still block")))
      (should (nth 3 (workbench-editing-test-state "a string")))
      (dolist (text '("x = 1" "y = 2" "z = 3"))
        (let ((state (workbench-editing-test-state text)))
          (should-not (nth 3 state))
          (should-not (nth 4 state)))))))

(ert-deftest workbench-editing-tree-font-lock ()
  (workbench-editing-test-with-treesit (workbench-editing-test-fixture)
    (should-not (treesit-node-check (treesit-buffer-root-node 'julia) 'has-error))
    (font-lock-ensure)
    (dolist (entry '(("Still the outer" . font-lock-comment-face)
                     ("literal \"quotes\"" . font-lock-string-face)
                     ("\n        if" . font-lock-keyword-face)
                     ("greet!" . font-lock-function-name-face)
                     ("@show" . font-lock-preprocessor-face)
                     ("$(α)" . font-lock-variable-name-face)))
      (goto-char (point-min))
      (search-forward (car entry))
      (should (eq (get-text-property (1- (point)) 'face) (cdr entry))))))

(ert-deftest workbench-editing-tree-indentation ()
  (workbench-editing-test-with-treesit (workbench-editing-test-fixture)
    (let ((expected (buffer-string)))
      ;; Keep multiline comment contents intact; scramble all other lines.
      (goto-char (point-min))
      (while (not (eobp))
        (unless (nth 4 (save-excursion (syntax-ppss (line-beginning-position))))
          (delete-horizontal-space))
        (forward-line 1))
      (indent-region (point-min) (point-max))
      (should (equal (buffer-string) expected))
      (indent-region (point-min) (point-max))
      (should (equal (buffer-string) expected)))))

(ert-deftest workbench-editing-tree-imenu-and-navigation ()
  (workbench-editing-test-with-treesit (workbench-editing-test-fixture)
    (let ((index (imenu--make-index-alist t)))
      (dolist (category '(("Functions" "greet!") ("Methods" "short" "Base.show")
                          ("Macros" "reveal") ("Types" "Animal" "Byte" "Box")
                          ("Modules" "EditingFixture")))
        (dolist (name (cdr category))
          (should (assoc name (cdr (assoc (car category) index)))))))
    (goto-char (point-min))
    (search-forward "return message")
    (treesit-beginning-of-defun)
    (should (looking-at "    function greet!"))
    (treesit-end-of-defun)
    (should (looking-at "\n    short"))
    (search-forward "α + 1")
    (treesit-beginning-of-defun)
    (should (looking-at "    short(α)"))))

(ert-deftest workbench-editing-tree-selection ()
  (workbench-editing-test-with-treesit "function f(x)\n    x + 1\nend\nf(2)\n"
    (goto-char (point-min))
    (search-forward "x +")
    (julia-workbench-mark-top-level)
    (should (equal (buffer-substring-no-properties (region-beginning) (region-end))
                   "function f(x)\n    x + 1\nend"))
    (deactivate-mark)
    (goto-char (point-min))
    (search-forward "x +")
    (backward-char 3)
    (julia-workbench-mark-node)
    (should (equal (buffer-substring-no-properties (region-beginning) (region-end)) "x"))
    (let ((transient-mark-mode t))
      (julia-workbench-mark-node)
      (should (equal (buffer-substring-no-properties (region-beginning) (region-end))
                     "x + 1")))))

(ert-deftest workbench-editing-tree-incomplete-code ()
  (dolist (text '("function α(x)\nif x > 0\nx +\n"
                  "values = [1,\n"
                  "f(x) = \"unterminated $(x\n"
                  "#= unfinished #= inner =#\n"))
    (workbench-editing-test-with-treesit text
      (font-lock-ensure)
      (indent-region (point-min) (point-max))
      (goto-char (point-max))
      (insert "\n")
      (indent-according-to-mode)
      (font-lock-ensure))))

(ert-deftest workbench-editing-tree-multiline-text-preserved ()
  (workbench-editing-test-with-treesit
      "function f()\n    text = \"\"\"first\n  intentional spaces\n\nlast\"\"\"\n    #= comment\n  intentional comment spaces\n\n    =#\n    text\nend\n"
    (let ((expected (buffer-string)))
      (indent-region (point-min) (point-max))
      (should (equal (buffer-string) expected)))))

(ert-deftest workbench-editing-tree-custom-offset-and-unicode ()
  (let ((julia-workbench-indent-offset 2)
        (exec-path nil))
    (workbench-editing-test-with-treesit
        "function 🦦(α)\nif α ≤ 2\nα + 1\nelse\nα\nend\nend\n"
      (indent-region (point-min) (point-max))
      (should (equal (buffer-string)
                     "function 🦦(α)\n  if α ≤ 2\n    α + 1\n  else\n    α\n  end\nend\n"))
      (should (assoc "🦦" (cdr (assoc "Functions" (imenu--make-index-alist t))))))))

(ert-deftest workbench-editing-tree-operators ()
  (let ((treesit-font-lock-level 4))
    (workbench-editing-test-with-treesit "α = A'\nβ = 'λ'\nγ = α ≤ β\n"
      (font-lock-ensure)
      (should-not (treesit-node-check (treesit-buffer-root-node 'julia) 'has-error))
      (goto-char (point-min))
      (search-forward "≤")
      (should (eq (get-text-property (1- (point)) 'face) 'font-lock-operator-face))
      (should-not (nth 3 (workbench-editing-test-state "A'")))
      (should (nth 3 (workbench-editing-test-state "'λ"))))))

(provide 'editing-tests)
;;; editing-tests.el ends here
