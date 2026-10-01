;;; julia-workbench.el --- Julia editing with built-in facilities -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Julia Workbench contributors
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; Keywords: languages

;;; Commentary:

;; Julia editing, with optional tree-sitter structural support.  Neither Julia
;; nor a language server is needed to edit files.  Configure the standard
;; `treesit-extra-load-path' for an existing Julia grammar, or explicitly run
;; `julia-workbench-install-grammar'.  See README.md for installation details.

;;; Code:

(require 'cl-lib)
(require 'treesit)

(autoload 'julia-workbench-connect "julia-workbench-eglot" nil t)
(autoload 'julia-workbench-reconnect "julia-workbench-eglot" nil t)
(autoload 'julia-workbench-shutdown "julia-workbench-eglot" nil t)
(autoload 'julia-workbench-setup-server "julia-workbench-eglot" nil t)
(autoload 'julia-workbench-doctor "julia-workbench-eglot" nil t)
(autoload 'julia-workbench-setup-unicode "julia-workbench-completion" nil t)
(autoload 'julia-workbench-cancel-unicode-setup "julia-workbench-completion" nil t)
(autoload 'julia-workbench--setup-completion "julia-workbench-completion")
(autoload 'julia-workbench--setup-documentation "julia-workbench-doc")
(autoload 'julia-workbench-documentation "julia-workbench-doc" nil t)
(autoload 'julia-workbench-documentation-at-point "julia-workbench-doc" nil t)
(autoload 'julia-workbench-documentation-search "julia-workbench-doc" nil t)
(autoload 'julia-workbench-documentation-select-packages "julia-workbench-doc" nil t)
(autoload 'julia-workbench-documentation-manual-search "julia-workbench-doc" nil t)
(autoload 'julia-workbench-repl "julia-workbench-repl" nil t)
(autoload 'julia-workbench-repl-restart "julia-workbench-repl" nil t)
(autoload 'julia-workbench-repl-interrupt "julia-workbench-repl" nil t)
(autoload 'julia-workbench-repl-activate-project "julia-workbench-repl" nil t)
(autoload 'julia-workbench-copy-last-eval-result "julia-workbench-repl" nil t)
(autoload 'julia-workbench-send-line "julia-workbench-repl" nil t)
(autoload 'julia-workbench-send-region "julia-workbench-repl" nil t)
(autoload 'julia-workbench-send-top-level-form "julia-workbench-repl" nil t)
(autoload 'julia-workbench-send-buffer "julia-workbench-repl" nil t)
(autoload 'julia-workbench-send-buffer-file "julia-workbench-repl" nil t)
(autoload 'julia-workbench-send-dwim "julia-workbench-repl" nil t)
(autoload 'julia-workbench-repl-documentation "julia-workbench-repl" nil t)
(autoload 'julia-workbench-repl-complete "julia-workbench-repl" nil t)

(defgroup julia-workbench nil
  "Julia editing and development."
  :group 'languages
  :prefix "julia-workbench-")

(defcustom julia-workbench-julia-command "julia"
  "Julia executable name or path, also usable in directory-local settings.
Executable settings are intentionally not marked safe local variables."
  :type 'string :group 'julia-workbench)
(make-variable-buffer-local 'julia-workbench-julia-command)

(defcustom julia-workbench-cache-directory nil
  "Writable cache root, or nil for XDG_CACHE_HOME/julia-workbench.
Tooling, completion data and standalone environments live outside the checkout."
  :type '(choice (const nil) directory) :group 'julia-workbench)

(defconst julia-workbench--asset-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Installed directory containing the Julia helper assets.")

(defcustom julia-workbench-indent-offset 4
  "Number of spaces per Julia indentation level."
  :type 'natnum
  :safe #'natnump)

(defcustom julia-workbench-use-tree-sitter t
  "Whether to use the Julia grammar when available.
Without it, provide basic syntax, font locking and comment editing."
  :type 'boolean)

(defcustom julia-workbench-grammar-source
  '("https://github.com/tree-sitter/tree-sitter-julia" "master" "src")
  "Julia grammar source for explicit installation.
The value is the source recipe accepted by `treesit-language-source-alist'.
Set its revision to a commit to pin an installation.  An existing grammar
on `treesit-extra-load-path' does not require downloading anything."
  :type '(list (string :tag "Repository")
               (string :tag "Revision") (string :tag "Source directory")))

(defvar-local julia-workbench--tree-sitter-active nil
  "Non-nil when structural support is active in this buffer.")

(defvar julia-workbench--font-lock-cache nil
  "Font lock rules validated against the loaded Julia grammar.")

(defconst julia-workbench--keywords
  '("abstract" "baremodule" "begin" "break" "catch" "const" "continue"
    "do" "else" "elseif" "end" "export" "finally" "for" "function"
    "global" "if" "import" "in" "isa" "let" "local" "macro" "module"
    "mutable" "outer" "primitive" "public" "quote" "return" "struct"
    "try" "type" "using" "where" "while")
  "Julia keywords used for font locking.")

(defvar julia-workbench-mode-syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?_ "w" table)
    (modify-syntax-entry ?! "w" table)
    (modify-syntax-entry ?# "< 14" table)
    (modify-syntax-entry ?= ". 23bn" table)
    (modify-syntax-entry ?\n ">" table)
    (modify-syntax-entry ?\' "." table)
    (modify-syntax-entry ?` "\"" table)
    (dolist (char '(?+ ?- ?* ?/ ?^ ?% ?& ?| ?< ?> ?: ?$ ?@ ?~ ?\?))
      (modify-syntax-entry char "." table))
    table)
  "Syntax table for `julia-workbench-mode'.")

(defconst julia-workbench--font-lock-keywords
  `((,(regexp-opt julia-workbench--keywords 'symbols) . font-lock-keyword-face)
    (,(regexp-opt '("true" "false" "nothing" "missing") 'symbols)
     . font-lock-constant-face)
    ("@[[:word:]!]+" . font-lock-preprocessor-face))
  "Basic font locking used without a Julia grammar.")

(defun julia-workbench--escaped-p (position)
  "Return non-nil if the character at POSITION follows odd backslashes."
  (let ((count 0))
    (save-excursion
      (goto-char position)
      (while (eq (char-before) ?\\)
        (cl-incf count)
        (backward-char)))
    (cl-oddp count)))

(defun julia-workbench--syntax-propertize (start end)
  "Apply Julia string and character syntax between START and END.
Nested comments are handled by the syntax table.  This is a lexical aid,
not a structural parser; tree-sitter supplies structural editing."
  (goto-char start)
  (while (re-search-forward
          "\"\"\"\\|'\\(?:[^'\\\\\n]\\|\\\\\\(?:[uUx][[:xdigit:]]+\\|[0-7]+\\|[^\n]\\)\\)'"
          end t)
    (let* ((beg (match-beginning 0))
           (finish (match-end 0))
           (triple (eq (char-after beg) ?\"))
           (state (save-excursion (syntax-ppss beg))))
      (unless (or (nth 3 state) (nth 4 state)
                  (julia-workbench--escaped-p beg))
        (if triple
            (let (close)
              (while (and (not close) (search-forward "\"\"\"" end t))
                (unless (julia-workbench--escaped-p (- (point) 3))
                  (setq close (point))))
              (put-text-property beg (1+ beg) 'syntax-table (string-to-syntax "|"))
              (put-text-property (1+ beg) finish 'syntax-table (string-to-syntax "."))
              (when close
                (put-text-property (- close 3) (1- close)
                                   'syntax-table (string-to-syntax "."))
                (put-text-property (1- close) close
                                   'syntax-table (string-to-syntax "|")))
              (put-text-property beg (or close end) 'syntax-multiline t))
          ;; An apostrophe after an expression is Julia's adjoint operator.
          (unless (or (memq (char-before beg) '(?\) ?\] ?\} ?\' ?.))
                      (and (char-before beg)
                           (memq (char-syntax (char-before beg)) '(?w ?_))))
            (put-text-property beg (1+ beg) 'syntax-table (string-to-syntax "\""))
            (put-text-property (1- finish) finish
                               'syntax-table (string-to-syntax "\""))))))))

(defun julia-workbench--syntax-extend (start end)
  "Extend syntax propertization from START through END to complete lines.
Include multiline strings intersecting the changed region."
  (let ((new-start (save-excursion (goto-char start) (line-beginning-position)))
        (new-end (save-excursion (goto-char end) (line-end-position))))
    (unless (and (= start new-start) (= end new-end))
      (cons new-start new-end))))

(defun julia-workbench--indent-basic ()
  "Preserve previous indentation in buffers without structural support."
  (let ((offset (- (point) (save-excursion (back-to-indentation) (point))))
        (indent (save-excursion
                  (forward-line -1)
                  (current-indentation))))
    (indent-line-to indent)
    (when (> offset 0) (move-to-column (+ indent offset)))))

(defun julia-workbench--definition-name (node)
  "Return the name of definition NODE, including short-form methods."
  (let* ((type (treesit-node-type node))
         (head (if (equal type "module_definition")
                   (treesit-node-child-by-field-name node "name")
                 (treesit-node-child node 0 t))))
    ;; Signatures, return annotations and `where' wrap the actual name.
    (while (and head
                (member (treesit-node-type head)
                        '("signature" "type_head" "call_expression"
                          "broadcast_call_expression" "parametrized_type_expression"
                          "typed_expression" "where_expression" "binary_expression")))
      (setq head (treesit-node-child head 0 t)))
    (when head (treesit-node-text head t))))

(defun julia-workbench--method-assignment-p (node)
  "Return non-nil if assignment NODE defines a short-form method."
  (let ((head (treesit-node-child node 0 t)))
    (while (and head (member (treesit-node-type head)
                            '("where_expression" "typed_expression")))
      (setq head (treesit-node-child head 0 t)))
    (and head (equal (treesit-node-type head) "call_expression"))))

(defun julia-workbench--definition-p (node)
  "Return non-nil if NODE is a navigable Julia definition."
  (or (string-match-p "\\`\\(?:function\\|macro\\|module\\|struct\\|abstract\\|primitive\\)_definition\\'"
                      (treesit-node-type node))
      (and (equal (treesit-node-type node) "assignment")
           (julia-workbench--method-assignment-p node))))

(defun julia-workbench--font-lock-settings ()
  "Return tree-sitter font lock rules for the available Julia grammar."
  (let ((keywords
         (cl-remove-if-not
          (lambda (word)
            (condition-case nil
                (progn (treesit-query-compile 'julia `((,word) @capture) t) t)
              (treesit-query-error nil)))
          julia-workbench--keywords))
        (interpolation
         ;; Grammar revisions use different names for interpolation nodes.
         (cl-find-if
          (lambda (type)
            (condition-case nil
                (progn (treesit-query-compile 'julia `((,type) @capture) t) t)
              (treesit-query-error nil)))
          '(string_interpolation interpolation_expression))))
    (apply
     #'treesit-font-lock-rules
     (append
      (list
       :language 'julia :feature 'comment
       '([(line_comment) (block_comment)] @font-lock-comment-face)
       :language 'julia :feature 'string
       '([(string_literal) (prefixed_string_literal) (command_literal)
          (prefixed_command_literal) (character_literal)] @font-lock-string-face)
       :language 'julia :feature 'keyword
       `([,@keywords] @font-lock-keyword-face)
       :language 'julia :feature 'number
       '([(integer_literal) (float_literal)] @font-lock-number-face)
       :language 'julia :feature 'constant
       '((boolean_literal) @font-lock-constant-face)
       :language 'julia :feature 'macro
       '((macro_identifier) @font-lock-preprocessor-face)
       :language 'julia :feature 'definition
       '((function_definition (signature (call_expression
                                         (_) @font-lock-function-name-face)))
         (macro_definition (signature (call_expression
                                      (_) @font-lock-function-name-face)))
         (module_definition name: (identifier) @font-lock-type-face)
         (struct_definition (type_head (_) @font-lock-type-face)))
       :language 'julia :feature 'operator
       '((operator) @font-lock-operator-face)
       :language 'julia :feature 'bracket
       '(["(" ")" "[" "]" "{" "}"] @font-lock-bracket-face))
      (when interpolation
        (list :language 'julia :feature 'interpolation :override t
              `((,interpolation) @font-lock-variable-name-face)))))))

(defun julia-workbench--block-anchor (_node parent _bol)
  "Return the beginning of the container's line for block PARENT.
The first child of a block is its body, so anchor at its enclosing form."
  (save-excursion
    (goto-char (treesit-node-start (treesit-node-parent parent)))
    (back-to-indentation)
    (point)))

(defun julia-workbench--literal-line-p (_node _parent bol)
  "Return non-nil if BOL is inside multiline text that should be preserved."
  (let ((node (treesit-node-at bol 'julia))
        found)
    (while (and node (not found))
      (when (and (member (treesit-node-type node)
                         '("string_literal" "prefixed_string_literal"
                           "command_literal" "prefixed_command_literal"
                           "block_comment"))
                 (< (treesit-node-start node) bol)
                 (< bol (treesit-node-end node)))
        (setq found t))
      (setq node (treesit-node-parent node)))
    found))

(defun julia-workbench--current-indent-anchor (_node _parent bol)
  "Return the current indentation position on the line containing BOL."
  (save-excursion
    (goto-char bol)
    (back-to-indentation)
    (point)))

(defun julia-workbench--treesit-setup ()
  "Enable structural Julia editing in the current buffer."
  (treesit-parser-create 'julia)
  (setq-local
   treesit-font-lock-settings
   (or julia-workbench--font-lock-cache
       (setq julia-workbench--font-lock-cache (julia-workbench--font-lock-settings)))
   treesit-font-lock-feature-list
   '((comment string) (keyword definition) (constant number macro interpolation)
     (operator bracket))
   treesit-simple-indent-rules
   `((julia
      (julia-workbench--literal-line-p julia-workbench--current-indent-anchor 0)
      ((parent-is "source_file") column-0 0)
      ((node-is "end\\|else\\|elseif\\|catch\\|finally") parent-bol 0)
      ((node-is ")\\|]\\|}") parent-bol 0)
      ((parent-is "string_literal\\|command_literal\\|block_comment") no-indent 0)
      ((parent-is "\\`block\\'") julia-workbench--block-anchor julia-workbench-indent-offset)
      ((parent-is "argument_list\\|curly_expression\\|vector_expression\\|tuple_expression\\|matrix_expression")
       parent-bol julia-workbench-indent-offset)
      ((parent-is ".*_definition\\|.*_statement\\|.*_clause")
       parent-bol julia-workbench-indent-offset)
      (catch-all prev-line 0)))
   treesit-defun-type-regexp #'julia-workbench--definition-p
   treesit-defun-name-function #'julia-workbench--definition-name
   treesit-defun-tactic 'nested
   treesit-simple-imenu-settings
   '(("Functions" "\\`function_definition\\'" nil julia-workbench--definition-name)
     ("Methods" "\\`assignment\\'" julia-workbench--method-assignment-p
      julia-workbench--definition-name)
     ("Macros" "\\`macro_definition\\'" nil julia-workbench--definition-name)
     ("Types" "\\`\\(?:struct\\|abstract\\|primitive\\)_definition\\'"
      nil julia-workbench--definition-name)
     ("Modules" "\\`module_definition\\'" nil julia-workbench--definition-name)))
  (treesit-major-mode-setup)
  (setq-local julia-workbench--tree-sitter-active t))

(defun julia-workbench--require-parser ()
  "Signal a useful error unless structural editing is available."
  (unless julia-workbench--tree-sitter-active
    (user-error "Set treesit-extra-load-path or run M-x julia-workbench-install-grammar, then reopen the buffer")))

(defun julia-workbench--top-level-node ()
  "Return the current Julia top-level form, or signal a user error."
  (julia-workbench--require-parser)
  (let ((node (treesit-node-at (point) 'julia)))
    (while (and node (treesit-node-parent node)
                (not (equal (treesit-node-type (treesit-node-parent node))
                            "source_file")))
      (setq node (treesit-node-parent node)))
    (when (or (null node) (equal (treesit-node-type node) "source_file"))
      (user-error "No Julia form at point"))
    node))

(defun julia-workbench-mark-top-level ()
  "Select the current Julia top-level form using the syntax tree."
  (interactive)
  (let ((node (julia-workbench--top-level-node)))
    (goto-char (treesit-node-start node))
    (push-mark (treesit-node-end node) nil t)))

(defun julia-workbench-mark-node ()
  "Select the syntax node at point; expand an active region to its parent."
  (interactive)
  (julia-workbench--require-parser)
  (let ((node (treesit-node-at (if (use-region-p) (region-beginning) (point))
                               'julia)))
    (when (use-region-p)
      (while (and (treesit-node-parent node)
                  (<= (treesit-node-end node) (region-end)))
        (setq node (treesit-node-parent node))))
    (unless node (user-error "No Julia node at point"))
    (goto-char (treesit-node-start node))
    (push-mark (treesit-node-end node) nil t)))

;;;###autoload
(defun julia-workbench-install-grammar ()
  "Explicitly download and compile the Julia tree-sitter grammar.
Requires Git and a C compiler.  Prefer an existing system grammar on
`treesit-extra-load-path' when available.  Reopen buffers after installation."
  (interactive)
  (unless (treesit-available-p)
    (user-error "This Emacs was built without tree-sitter support"))
  (let ((treesit-language-source-alist
         (cons (cons 'julia julia-workbench-grammar-source)
               (assq-delete-all 'julia (copy-tree treesit-language-source-alist)))))
    (treesit-install-language-grammar 'julia)))

(defvar julia-workbench-mode-map
  (let ((map (make-sparse-keymap)))
    (keymap-set map "C-c C-SPC" #'julia-workbench-mark-top-level)
    (keymap-set map "C-c C-e" #'julia-workbench-mark-node)
    (keymap-set map "C-c C-d" #'julia-workbench-documentation-at-point)
    (keymap-set map "C-c C-h" #'julia-workbench-documentation)
    (keymap-set map "C-c C-s" #'julia-workbench-documentation-search)
    (keymap-set map "C-c C-z" #'julia-workbench-repl)
    (keymap-set map "C-c C-l" #'julia-workbench-send-line)
    (keymap-set map "C-c C-r" #'julia-workbench-send-region)
    (keymap-set map "C-c C-c" #'julia-workbench-send-dwim)
    (keymap-set map "C-c C-b" #'julia-workbench-send-buffer)
    (keymap-set map "C-c C-f" #'julia-workbench-send-buffer-file)
    map)
  "Keymap for `julia-workbench-mode'.")

;;;###autoload
(define-derived-mode julia-workbench-mode prog-mode "Julia Workbench"
  "Major mode for Julia with optional tree-sitter structural editing.
Without the grammar, preserve basic syntax and comment editing.  No Julia
executable or server is launched when entering this mode."
  :syntax-table julia-workbench-mode-syntax-table
  (setq-local comment-start "# "
              comment-end ""
              comment-start-skip "#= *\\|#+ *"
              comment-use-syntax t
              indent-tabs-mode nil
              indent-line-function #'julia-workbench--indent-basic
              font-lock-defaults '(julia-workbench--font-lock-keywords)
              syntax-propertize-function #'julia-workbench--syntax-propertize)
  (julia-workbench--setup-completion)
  (julia-workbench--setup-documentation)
  (add-hook 'syntax-propertize-extend-region-functions
            #'syntax-propertize-multiline nil t)
  (add-hook 'syntax-propertize-extend-region-functions
            #'julia-workbench--syntax-extend nil t)
  (if (and julia-workbench-use-tree-sitter (treesit-ready-p 'julia t))
      (julia-workbench--treesit-setup)
    (message "Julia basic editing: set treesit-extra-load-path or run M-x julia-workbench-install-grammar for structural support")))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.jl\\'" . julia-workbench-mode))
;;;###autoload
(add-to-list 'interpreter-mode-alist '("julia" . julia-workbench-mode))

(provide 'julia-workbench)
;;; julia-workbench.el ends here
