;;; julia-workbench-completion.el --- Julia CAPFs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Julia Workbench contributors
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "31.1"))

;;; Commentary:
;; Unicode data is exported by an explicit asynchronous Julia job and cached
;; outside the package.  CAPFs never launch Julia.  The semantic adapter keeps
;; Eglot's table, ordering and edits, and adds signature display to its docs.

;;; Code:

(require 'julia-workbench)
(require 'project)
(require 'seq)
(require 'subr-x)

(declare-function eglot-completion-at-point "eglot")
(declare-function eglot-current-server "eglot")
(declare-function eglot-server-capable "eglot" (capability &rest more))
(declare-function eglot--async-request "eglot" (server method params &rest args))
(declare-function eglot--TextDocumentPositionParams "eglot" ())
(declare-function eglot--sig-info "eglot" (sig &optional sig-active briefp))
(declare-function corfu-mode "corfu" (&optional arg))
(defvar corfu-auto)
(defvar corfu-auto-prefix)
(defvar corfu-auto-delay)
(defvar corfu-popupinfo-mode)
(defvar corfu-popupinfo-delay)

(defcustom julia-workbench-automatic-completion t
  "Enable automatic completion and candidate documentation with installed Corfu.
Settings apply only to Julia Workbench buffers.  No UI package is installed.
Set to nil before opening a buffer to keep your own completion UI settings."
  :type 'boolean :group 'julia-workbench)

(defcustom julia-workbench-unicode-setup-timeout 30
  "Seconds allowed for an explicit Unicode data export."
  :type 'natnum :group 'julia-workbench)

(defvar julia-workbench--unicode-cache (make-hash-table :test #'equal)
  "Parsed Unicode tables indexed by cache filename and file identity.")

(defvar julia-workbench--unicode-jobs (make-hash-table :test #'equal)
  "Active Unicode exports indexed by cache filename.")

(defun julia-workbench--unicode-location ()
  "Return (EXECUTABLE CACHE-FILE) for this buffer, without starting Julia.
Cache identity includes the resolved executable path, size and modification
time.  Refresh explicitly after changing a runtime behind a launcher script."
  (unless (file-remote-p default-directory)
    (let* ((project (project-current nil))
           (root (if project (project-root project) default-directory))
           (command (if (string-match-p "/" julia-workbench-julia-command)
                        (expand-file-name julia-workbench-julia-command root)
                      julia-workbench-julia-command))
           (executable (unless (file-remote-p command) (executable-find command))))
      (when executable
        (let* ((resolved (file-truename executable))
               (attributes (file-attributes resolved))
               (key (secure-hash
                     'sha256 (prin1-to-string
                              (list resolved (file-attribute-size attributes)
                                    (file-attribute-modification-time attributes)))))
               (cache (expand-file-name
                       "unicode" (or julia-workbench-cache-directory
                                     (expand-file-name
                                      "julia-workbench"
                                      (or (getenv "XDG_CACHE_HOME") "~/.cache"))))))
          (list executable (expand-file-name (concat key ".tsv") cache)))))))

(defun julia-workbench--parse-unicode ()
  "Validate the current export buffer and return (VERSION . TABLE).
Use a plain data format; never evaluate Lisp from a writable cache."
  (goto-char (point-min))
  (unless (looking-at "julia-workbench-unicode-v1\t\\([0-9]+\\.[0-9]+\\.[0-9]+[^\n\t]*\\)\n")
    (error "Invalid Julia Unicode export header"))
  (let ((version (match-string-no-properties 1))
        (table (make-hash-table :test #'equal)))
    (forward-line 1)
    (while (< (point) (point-max))
      (unless (looking-at "\\(\\\\[^\t\n\r]+\\)\t\\([^\t\n\r]+\\)\n")
        (error "Invalid Julia Unicode export row"))
      (let ((name (match-string-no-properties 1))
            (value (match-string-no-properties 2)))
        (when (gethash name table) (error "Duplicate Julia Unicode input %s" name))
        (puthash name value table))
      (forward-line 1))
    (when (zerop (hash-table-count table)) (error "Empty Julia Unicode export"))
    (cons version table)))

(defun julia-workbench--unicode-data ()
  "Read cached data for this buffer, or return nil when unavailable.
Missing or malformed caches leave ordinary editing and semantic completion
available.  Use `julia-workbench-setup-unicode' to create or refresh the data."
  (when-let* ((location (julia-workbench--unicode-location))
              (file (cadr location))
              (attributes (file-attributes file)))
    (let* ((key (list file (file-attribute-size attributes)
                      (file-attribute-modification-time attributes)))
           (cached (gethash key julia-workbench--unicode-cache 'missing)))
      (if (not (eq cached 'missing)) cached
        (let ((data (condition-case nil
                        (with-temp-buffer
                          (let ((coding-system-for-read 'utf-8-unix))
                            (insert-file-contents file))
                          (julia-workbench--parse-unicode))
                      (error nil))))
          (puthash key data julia-workbench--unicode-cache)
          data)))))

;;;###autoload
(defun julia-workbench-setup-unicode ()
  "Asynchronously export this Julia runtime's LaTeX and emoji input table.
Only Julia standard libraries are used.  Save validated UTF-8 data atomically
outside the checkout.  Existing data survives failures and cancellation.
Display logs; cancel with `julia-workbench-cancel-unicode-setup'."
  (interactive)
  (let* ((location (or (julia-workbench--unicode-location)
                       (user-error "Local Julia executable missing; set julia-workbench-julia-command")))
         (executable (car location))
         (file (cadr location))
         (helper (expand-file-name "julia/unicode.jl" julia-workbench--asset-directory))
         (log (get-buffer-create (format "*Julia Unicode setup %s*" executable)))
         (output (generate-new-buffer " *Julia Unicode export*"))
         (timer nil))
    (unless (file-readable-p helper)
      (kill-buffer output)
      (user-error "Missing %s; include julia/ in the package recipe" helper))
    (when (process-live-p (gethash file julia-workbench--unicode-jobs))
      (kill-buffer output)
      (user-error "Unicode setup already running for %s" executable))
    (with-current-buffer log
      (let ((inhibit-read-only t)) (erase-buffer))
      (special-mode))
    (condition-case err
        (let ((process
               (make-process
                :name "julia-workbench-unicode" :buffer output :stderr log
                :noquery t :connection-type 'pipe :coding 'utf-8-unix
                :command (list executable "--startup-file=no" "--history-file=no" helper)
                :sentinel
                (lambda (process event)
                  (when (memq (process-status process) '(exit signal))
                    (when timer (cancel-timer timer))
                    (remhash file julia-workbench--unicode-jobs)
                    (let ((result
                           (condition-case err
                               (progn
                                 (unless (and (eq (process-status process) 'exit)
                                              (zerop (process-exit-status process)))
                                   (error "Export %s" (if (process-get process 'timeout)
                                                           "timed out" (string-trim event))))
                                 (with-current-buffer output
                                   (let* ((data (julia-workbench--parse-unicode))
                                          (directory (file-name-directory file))
                                          (temporary nil))
                                     (make-directory directory t)
                                     (unwind-protect
                                         (progn
                                           (setq temporary (make-temp-file
                                                            (expand-file-name ".unicode-" directory)))
                                           (let ((coding-system-for-write 'utf-8-unix))
                                             (write-region (point-min) (point-max) temporary nil 'silent))
                                           (rename-file temporary file t))
                                       (when (and temporary (file-exists-p temporary))
                                         (delete-file temporary)))
                                     (clrhash julia-workbench--unicode-cache)
                                     (format "Julia %s: cached %d Unicode inputs in %s"
                                             (car data) (hash-table-count (cdr data)) file))))
                             (error (format "Unicode setup failed: %s" (error-message-string err))))))
                      (when (buffer-live-p log)
                        (with-current-buffer log
                          (let ((inhibit-read-only t))
                            (goto-char (point-max)) (insert result "\n"))))
                      (message "%s" result))
                    (when (buffer-live-p output) (kill-buffer output)))))))
          (puthash file process julia-workbench--unicode-jobs)
          (setq timer (run-at-time julia-workbench-unicode-setup-timeout nil
                                   (lambda ()
                                     (when (process-live-p process)
                                       (process-put process 'timeout t)
                                       (delete-process process)))))
          (display-buffer log)
          process)
      (error (kill-buffer output) (signal (car err) (cdr err))))))

;;;###autoload
(defun julia-workbench-cancel-unicode-setup ()
  "Cancel the Unicode export for this buffer's selected Julia executable."
  (interactive)
  (let* ((file (cadr (julia-workbench--unicode-location)))
         (process (gethash file julia-workbench--unicode-jobs)))
    (unless (process-live-p process) (user-error "No Unicode setup running"))
    (delete-process process)))

(defun julia-workbench--unicode-doc-buffer (name value version)
  "Return documentation for Unicode input NAME, VALUE and Julia VERSION."
  (with-current-buffer (get-buffer-create " *Julia Unicode documentation*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (format "%s → %s\n\nJulia %s Unicode input\n\n" name value version))
      (mapc (lambda (character)
              (insert (format "U+%04X  %s\n" character
                              (or (get-char-code-property character 'name) "Unnamed character"))))
            (string-to-list value)))
    (special-mode)
    (current-buffer)))

(defun julia-workbench-unicode-completion-at-point ()
  "Complete Julia backslash Unicode and emoji inputs using cached data.
Offer glyph annotations and documentation through ordinary CAPF properties.
Convert a selected complete input only after the UI accepts it."
  (let* ((end (point))
         (begin (save-excursion
                  (when (search-backward "\\" (line-beginning-position) t)
                    (point))))
         (prefix (and begin (buffer-substring-no-properties begin end))))
    (when (and prefix (not (eq (char-before begin) ?\\))
               (string-match-p "\\`\\\\[A-Za-z0-9_:^!()+/<>=>-]*\\'" prefix))
      (when-let* ((data (julia-workbench--unicode-data))
                  (table (cdr data))
                  (matches (all-completions prefix table)))
        (let ((marker (copy-marker begin))
              (buffer (current-buffer)))
          (list begin end
                (lambda (string predicate action)
                  (if (eq action 'metadata)
                      '(metadata (category . julia-unicode))
                    (complete-with-action action matches string predicate)))
                :exclusive 'no
                :annotation-function (lambda (name) (concat " " (gethash name table)))
                :company-kind (lambda (_) 'text)
                :company-doc-buffer
                (lambda (name)
                  (julia-workbench--unicode-doc-buffer name (gethash name table) (car data)))
                :exit-function
                (lambda (name status)
                  (when (and (memq status '(finished exact)) (gethash name table)
                             (buffer-live-p buffer) (marker-position marker))
                    (with-current-buffer buffer
                      (let ((start (marker-position marker)))
                        (when (and (<= (+ start (length name)) (point-max))
                                   (equal name (buffer-substring-no-properties
                                                start (+ start (length name)))))
                          (delete-region start (+ start (length name)))
                          (goto-char start)
                          (insert (gethash name table)))))))))))))

(defun julia-workbench-path-completion-at-point ()
  "Complete local paths in plain double-quoted Julia strings.
Decline escapes and interpolation rather than guessing their evaluation.
Use Emacs's file completion table, including directory continuation."
  (unless (file-remote-p default-directory)
    (let* ((state (syntax-ppss))
           (start (nth 8 state))
           (begin (and (eq (nth 3 state) ?\") start
                       (+ start (if (save-excursion (goto-char start)
                                                   (looking-at "\"\"\"")) 3 1)))))
      (when (and begin (<= begin (point)))
        (let ((prefix (buffer-substring-no-properties begin (point))))
          (unless (string-match-p "[\\\\$\"\n\r]" prefix)
            (list begin (point)
                  (lambda (string predicate action)
                    (completion-table-with-predicate
                     #'completion-file-name-table
                     (lambda (name) (not (string-match-p "[\\\\$\"\n\r]" name))) t
                     string predicate action))
                  :exclusive 'no)))))))

(defun julia-workbench--signature-whitespace (signature &optional compact)
  "Normalize SIGNATURE's whitespace outside strings, removing it if COMPACT."
  (with-temp-buffer
    (set-syntax-table julia-workbench-mode-syntax-table)
    (insert signature)
    (goto-char (point-min))
    (while (re-search-forward "[ \t\n\r]+" nil t)
      (unless (nth 3 (save-excursion (syntax-ppss (match-beginning 0))))
        (replace-match (if compact "" " ") t t)))
    (string-trim (buffer-string))))

(defun julia-workbench--signatures-in-text (name text)
  "Extract signatures of NAME from TEXT, including multiline and list entries.
Ignore prose and call bodies.  NAME may be qualified, a macro or an operator."
  (when (stringp text)
    (with-temp-buffer
      (set-syntax-table julia-workbench-mode-syntax-table)
      (insert text)
      (goto-char (point-min))
      (let ((pattern (concat "^[ \t]*\\(?:[0-9]+\\.[ \t]+\\)?`?"
                             "\\(?:[[:alnum:]_]+\\.\\)*"
                             (regexp-quote (substring-no-properties name))
                             "[ \t]*\\(?:{[^}\n]*}[ \t]*\\)?("))
            signatures)
        (while (re-search-forward pattern nil t)
          (let* ((start (save-excursion
                          (goto-char (match-beginning 0))
                          (skip-chars-forward " \t0123456789.`") (point)))
                 (end (ignore-errors (scan-sexps (1- (point)) 1))))
            (when end
              (goto-char end)
              ;; Return annotations and `where' constraints follow the call.
              (when (looking-at "[ \t]*\\(?:::[^`\n]+\\|where[ \t]+[^`\n]+\\)")
                (goto-char (match-end 0)))
              (let ((signature (concat
                                (buffer-substring-no-properties start end)
                                (car (split-string (buffer-substring-no-properties end (point))
                                                   "[ \t]+\\(?:in\\|at\\)[ \t]+\\|[ \t]*=")))))
                (push (julia-workbench--signature-whitespace signature) signatures)))))
        (nreverse signatures)))))

(defun julia-workbench--unique-signatures (signatures)
  "Deduplicate SIGNATURES while keeping their order and displayed spelling."
  (let ((seen (make-hash-table :test #'equal)))
    (seq-filter
     (lambda (signature)
       ;; Return types do not distinguish Julia methods.  Server detail may
       ;; append a synthetic `::Function' to an otherwise identical signature.
       (let* ((key (with-temp-buffer
                     (set-syntax-table julia-workbench-mode-syntax-table)
                     (insert signature)
                     (goto-char (point-min))
                     (when (search-forward "(" nil t)
                       (when-let* ((end (ignore-errors (scan-sexps (1- (point)) 1))))
                         (goto-char end)
                         (when (looking-at "::")
                           (delete-region end (if (re-search-forward "[ \t]+where\\_>" nil t)
                                                  (match-beginning 0) (point-max))))))
                     (buffer-string)))
              (key (julia-workbench--signature-whitespace key t)))
         (unless (gethash key seen)
           (puthash key t seen))))
     signatures)))

(defun julia-workbench--completion-signatures (candidate &optional detail text)
  "Combine available signatures for CANDIDATE with server DETAIL and TEXT."
  (let* ((name (substring-no-properties candidate))
         (item (get-text-property 0 'eglot--lsp-item candidate))
         (documentation (plist-get item :documentation)))
    (julia-workbench--unique-signatures
     (append
      (julia-workbench--signatures-in-text name (julia-workbench--local-signatures name))
      (julia-workbench--signatures-in-text
       name (if (stringp documentation) documentation (plist-get documentation :value)))
      (julia-workbench--signatures-in-text name text)
      (julia-workbench--signatures-in-text name (plist-get item :detail))
      (julia-workbench--signatures-in-text name detail)))))

(defun julia-workbench--completion-signature (candidate properties)
  "Return combined signatures for CANDIDATE from CAPF PROPERTIES."
  (let* ((docsig (plist-get properties :company-docsig))
         (detail (and docsig (funcall docsig candidate)))
         (documentation (plist-get properties :company-doc-buffer))
         (buffer (and documentation (funcall documentation candidate)))
         (text (and (buffer-live-p buffer) (with-current-buffer buffer (buffer-string))))
         (signatures (julia-workbench--completion-signatures candidate detail text)))
    (if signatures (string-join signatures "\n") detail)))

(defun julia-workbench-semantic-completion-at-point ()
  "Adapt Eglot completion to display signatures on selection and acceptance.
Preserve the original completion table, bounds, metadata and edit callback."
  (when-let* ((capf (eglot-completion-at-point)))
    (let* ((properties (nthcdr 3 capf))
           (annotation (plist-get properties :annotation-function))
           (docsig (plist-get properties :company-docsig))
           (documentation (plist-get properties :company-doc-buffer))
           (exit (plist-get properties :exit-function))
           (source (current-buffer))
           (cache (make-hash-table :test #'equal)))
      (cl-labels
          ((entry (candidate &optional resolve)
             (when (buffer-live-p source)
               (with-current-buffer source
                 (let* ((key (list (buffer-chars-modified-tick)
                                   (substring-no-properties candidate)
                                   (get-text-property 0 'eglot--lsp-item candidate)))
                        (cached (gethash key cache)))
                   (when (or (null cached) (and resolve (not (plist-get cached :resolved))))
                     (let* ((detail (and resolve docsig (funcall docsig candidate)))
                            (original (and resolve documentation (funcall documentation candidate)))
                            (text (and (buffer-live-p original)
                                       (with-current-buffer original (buffer-string)))))
                       (setq cached (list :resolved resolve :text text
                                          :signatures (julia-workbench--completion-signatures
                                                       candidate detail text)))
                       (puthash key cached cache)))
                   cached)))))
      (append
       (seq-take capf 3)
       (list
        :annotation-function
        (lambda (candidate)
          ;; Never resolve completion items or request docs for menu rows.
          (let* ((original (and annotation (funcall annotation candidate)))
                 (count (length (plist-get (entry candidate) :signatures))))
            (concat original (when (> count 1) (format " [%d methods]" count)))))
        :company-doc-buffer
        (lambda (candidate)
          (when (buffer-live-p source)
            (with-current-buffer source
              (let* ((data (entry candidate t))
                     (signatures (plist-get data :signatures))
                     (text (plist-get data :text)))
                (when (or signatures text)
                  (with-current-buffer (get-buffer-create " *Julia completion documentation*")
                    (let ((inhibit-read-only t))
                      (erase-buffer)
                      (when signatures
                        (when (> (length signatures) 1)
                          (insert (format "%d available methods\n\n" (length signatures))))
                        (insert (string-join signatures "\n") "\n\n"))
                      (when text (insert text)))
                    (current-buffer)))))))
        :exit-function
        (lambda (candidate status)
          (when (buffer-live-p source)
            (with-current-buffer source
              (let ((signatures (and (memq status '(finished exact))
                                     (plist-get (entry candidate) :signatures))))
                (when exit (funcall exit candidate status))
                (when signatures
                  (message "%s%s" (car signatures)
                           (if (cdr signatures)
                               (format " (+%d methods)" (1- (length signatures))) ""))))))))
       properties)))))

(defvar-local julia-workbench--signature-positions nil
  "Markers for available methods in a signature help buffer.")

(defun julia-workbench-signature-next (&optional previous)
  "Move to the next displayed method, or the previous one when PREVIOUS."
  (interactive)
  (let ((positions (if previous (reverse julia-workbench--signature-positions)
                     julia-workbench--signature-positions)))
    (when-let* ((position (or (seq-find (lambda (pos) (if previous (< pos (point)) (> pos (point))))
                                       positions)
                             (car positions))))
      (goto-char position))))

(defun julia-workbench-signature-previous ()
  "Move to the previous displayed method."
  (interactive)
  (julia-workbench-signature-next t))

(define-derived-mode julia-workbench-signature-mode special-mode "Julia Methods"
  "Browse method signatures with active argument highlighting."
  (setq-local truncate-lines nil))
(keymap-set julia-workbench-signature-mode-map "n" #'julia-workbench-signature-next)
(keymap-set julia-workbench-signature-mode-map "p" #'julia-workbench-signature-previous)

(defun julia-workbench--show-signatures (result)
  "Display method signatures and the active parameter from server RESULT."
  (let* ((signatures (plist-get result :signatures))
         (active (or (plist-get result :activeSignature) 0))
         (parameter (or (plist-get result :activeParameter) 0)))
    (if (zerop (length signatures)) (message "No method signatures at this position")
      (with-current-buffer (get-buffer-create "*Julia Methods*")
        (julia-workbench-signature-mode)
        (let ((inhibit-read-only t) (index 0))
          (erase-buffer)
          (setq julia-workbench--signature-positions nil)
          (insert (format "%d available methods\n\nn: next method   p: previous method   q: close\n\n"
                          (length signatures)))
          (mapc
           (lambda (signature)
             (push (copy-marker (point)) julia-workbench--signature-positions)
             (insert (format "%s%d. " (if (= index active) "→ " "  ") (1+ index))
                     (eglot--sig-info signature parameter nil) "\n\n")
             (setq index (1+ index)))
           signatures)
          (setq julia-workbench--signature-positions (nreverse julia-workbench--signature-positions))
          (goto-char (or (nth active julia-workbench--signature-positions) (point-min))))
        (display-buffer (current-buffer))))))

;;;###autoload
(defun julia-workbench-signature-help ()
  "Asynchronously browse available methods for the call at point.
Invoke inside a call after `(' or `,'.  Use the existing Eglot server only.
Ignore replies if the source position, contents or server have changed."
  (interactive)
  (require 'eglot)
  (let ((server (eglot-current-server))
        (source (current-buffer))
        (position (point))
        (tick (buffer-chars-modified-tick)))
    (unless (and server (eglot-server-capable :signatureHelpProvider))
      (user-error "Connect Eglot to a server with signature help first"))
    (cl-labels ((current-p ()
                  (and (buffer-live-p source)
                       (with-current-buffer source
                         (and (= position (point)) (= tick (buffer-chars-modified-tick))
                              (eq server (eglot-current-server)))))))
      (eglot--async-request
       server :textDocument/signatureHelp (eglot--TextDocumentPositionParams)
       :success-fn
       (lambda (result)
         (when (current-p)
           (with-current-buffer source (julia-workbench--show-signatures result))))
       :error-fn (lambda (error)
                   (when (current-p) (message "Julia signature help failed: %s" error)))
       :timeout-fn (lambda ()
                     (when (current-p) (message "Julia signature help timed out")))
       :timeout 10 :hint :julia-workbench-signature-help))))

(defun julia-workbench--setup-completion-ui ()
  "Enable installed Corfu and automatic documentation locally when requested."
  (when (and julia-workbench-automatic-completion (require 'corfu nil t))
    (setq-local corfu-auto t corfu-auto-prefix 2 corfu-auto-delay 0.2)
    ;; Re-enable to install Corfu's automatic completion hook if already active.
    (corfu-mode -1)
    (corfu-mode 1)
    (when (require 'corfu-popupinfo nil t)
      ;; Popupinfo is a global minor mode; a local binding scopes it to Julia.
      (setq-local corfu-popupinfo-mode t corfu-popupinfo-delay '(0.2 . 0.1)))))

(defun julia-workbench--setup-completion ()
  "Install local CAPFs before Eglot, preserving other completion providers.
Run again when Eglot changes management state, since it prepends its CAPF."
  (when (derived-mode-p 'julia-workbench-mode)
    (setq-local completion-at-point-functions
                (delete-dups
                 (mapcar (lambda (provider)
                           (if (eq provider #'eglot-completion-at-point)
                               #'julia-workbench-semantic-completion-at-point
                             provider))
                         completion-at-point-functions)))
    (unless (bound-and-true-p eglot--managed-mode)
      (remove-hook 'completion-at-point-functions
                   #'julia-workbench-semantic-completion-at-point t))
    (remove-hook 'completion-at-point-functions
                 #'julia-workbench-unicode-completion-at-point t)
    (remove-hook 'completion-at-point-functions
                 #'julia-workbench-path-completion-at-point t)
    (add-hook 'completion-at-point-functions
              #'julia-workbench-path-completion-at-point nil t)
    (add-hook 'completion-at-point-functions
              #'julia-workbench-unicode-completion-at-point nil t)
    (add-hook 'eglot-managed-mode-hook #'julia-workbench--setup-completion nil t)
    (julia-workbench--setup-completion-ui)))

(with-eval-after-load 'julia-workbench-eglot
  (add-hook 'julia-workbench-environment-change-hook
            (lambda (_project) (clrhash julia-workbench--unicode-cache))))

(provide 'julia-workbench-completion)
;;; julia-workbench-completion.el ends here
