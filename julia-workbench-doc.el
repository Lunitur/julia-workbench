;;; julia-workbench-doc.el --- Asynchronous Julia documentation -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Julia Workbench contributors
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "30.1"))

;;; Commentary:
;; Explicit lookup, name indexing and literal docstring search use bounded Julia
;; workers.  Opening files and ElDoc never launch helpers.  ElDoc consumes cached
;; lookups locally; connected buffers keep Eglot's hover/signature providers.
;; Selected packages load only in these helpers, separately from a user REPL.

;;; Code:

(require 'julia-workbench-eglot)
(require 'button)
(require 'eldoc)
(require 'browse-url)
(require 'url-util)

(defcustom julia-workbench-documentation-packages nil
  "Package names explicitly loaded by documentation helpers.
Include standard libraries here to request their docs.  Loading selected
packages executes their ordinary Julia initialization code in the helper.
Unselected dependencies are not automatically imported."
  :type '(repeat string) :group 'julia-workbench)
(make-variable-buffer-local 'julia-workbench-documentation-packages)

(defcustom julia-workbench-documentation-timeout 30
  "Seconds allowed for one asynchronous documentation helper."
  :type 'number :group 'julia-workbench)

(defcustom julia-workbench-documentation-max-output (* 8 1024 1024)
  "Maximum bytes of documentation output accepted from one helper."
  :type 'natnum :group 'julia-workbench)

(defcustom julia-workbench-documentation-max-jobs 4
  "Maximum number of concurrent documentation helpers."
  :type 'natnum :group 'julia-workbench)

(defvar julia-workbench--doc-jobs (make-hash-table :test #'eq)
  "Active helper processes, for bounded concurrency and shutdown cleanup.")
(defvar julia-workbench--doc-cache (make-hash-table :test #'equal)
  "Validated documentation results indexed by context and query.")
(defvar julia-workbench--doc-input-history nil
  "Minibuffer history of symbol lookup and text search queries.")
(defvar-local julia-workbench--doc-context nil
  "Captured source settings for a documentation results buffer.")
(defvar-local julia-workbench--doc-process nil
  "Current helper for this results buffer.")
(defvar-local julia-workbench--doc-generation 0
  "Request generation, preventing stale callbacks from replacing newer output.")
(defvar-local julia-workbench--doc-history nil
  "Rendered documentation history, newest entry first.")
(defvar-local julia-workbench--doc-history-position 0
  "Current index in rendered documentation history.")
(defvar-local julia-workbench--doc-last-request nil
  "Last (COMMAND QUERY) for explicit refresh.")

(defun julia-workbench--doc-file-identity (file)
  "Return content identity for readable FILE, or nil."
  (when (file-regular-p file)
    (with-temp-buffer
      (insert-file-contents-literally file)
      (secure-hash 'sha256 (current-buffer)))))

(defun julia-workbench--doc-context (&optional hover)
  "Capture project/helper settings without running Julia.
With HOVER, capture a server-only context that needs no local Julia executable."
  (if hover
      (let ((project (julia-workbench-resolve-project)))
        (list :key (list project (buffer-chars-modified-tick)) :hover t
              :source (current-buffer) :point (copy-marker (point))
              :root (project-root project)
              :environment (or (julia-workbench-project-environment project) "server workspace")
              :timeout julia-workbench-documentation-timeout))
    (let* ((project (julia-workbench-resolve-project))
           (executable (file-truename (julia-workbench--executable project)))
           (attributes (file-attributes executable))
           (root (project-root project))
           (environment (or (julia-workbench-project-environment project)
                            (expand-file-name
                             (concat "standalone/docs/" (secure-hash 'sha256 root))
                             (julia-workbench-project-cache project))))
           (packages (sort (delete-dups
                            (copy-sequence julia-workbench-documentation-packages))
                           #'string<))
           (files (when (and (julia-workbench-project-environment project)
                             (file-directory-p environment))
                    (directory-files environment t
                                     "\\`\\(?:Julia\\)?\\(?:Project\\|Manifest\\(?:-v[0-9.]+\\)?\\)\\.toml\\'")))
           (helper (julia-workbench--asset "documentation.jl"))
           (key (list executable (file-attribute-size attributes)
                      (file-attribute-modification-time attributes)
                      root environment packages
                      (mapcar (lambda (file)
                                (cons file (julia-workbench--doc-file-identity file))) files)
                      (julia-workbench--doc-file-identity helper))))
      (when (file-remote-p (julia-workbench-project-cache project))
        (user-error "Documentation caches must use a local writable directory"))
      (when (and (julia-workbench-project-environment project)
                 (not (julia-workbench--project-file environment)))
        (user-error "No Julia project file in %s" environment))
      (list :key key :executable executable :environment environment
            :standalone (not (julia-workbench-project-environment project))
            :root root :packages packages :helper helper :source (current-buffer)
            :timeout julia-workbench-documentation-timeout
            :max-output julia-workbench-documentation-max-output
            :cache (expand-file-name "documentation" (julia-workbench-project-cache project))))))

(defun julia-workbench--doc-location (context command query)
  "Return cache filename for CONTEXT, COMMAND and QUERY."
  (expand-file-name
   (concat (secure-hash 'sha256
                        (prin1-to-string (list (plist-get context :key) command query)))
           ".tsv")
   (plist-get context :cache)))

(defun julia-workbench--doc-decode (value)
  "Decode a strictly validated base64 UTF-8 field VALUE."
  (let* ((bytes (base64-decode-string value))
         (string (decode-coding-string bytes 'utf-8-unix)))
    (unless (equal value (base64-encode-string
                          (encode-coding-string string 'utf-8-unix) t))
      (error "Invalid documentation UTF-8/base64 field"))
    string))

(defun julia-workbench--doc-parse (command query)
  "Validate the current protocol buffer for COMMAND and QUERY and return data."
  (goto-char (point-min))
  (unless (looking-at "julia-workbench-doc-v1\t\\([0-9]+\\.[0-9]+\\.[0-9]+[^\t\n]*\\)\t\\(lookup\\|search\\|names\\)\n")
    (error "Invalid documentation protocol header"))
  (let ((data (list :version (match-string-no-properties 1) :command command))
        (seen nil) (names nil))
    (unless (equal command (match-string-no-properties 2))
      (error "Unexpected documentation response kind"))
    (forward-line 1)
    (while (< (point) (point-max))
      (unless (looking-at "\\([A-Za-z]+\\)\t\\([^\n\t]*\\)\n")
        (error "Invalid documentation protocol row"))
      (let ((field (match-string-no-properties 1))
            (value (match-string-no-properties 2)))
        (when (and (not (equal field "Name")) (member field seen))
          (error "Duplicate documentation field %s" field))
        (push field seen)
        (pcase field
          ("Scope" (setq data (plist-put data :scope (julia-workbench--doc-decode value))))
          ("Symbol" (setq data (plist-put data :symbol (julia-workbench--doc-decode value))))
          ("Markdown" (setq data (plist-put data :markdown (julia-workbench--doc-decode value))))
          ((or "Documented" "Truncated")
           (unless (member value '("true" "false")) (error "Invalid documentation flag"))
           (setq data (plist-put data (if (equal field "Documented") :found :truncated)
                                 (equal value "true"))))
          ("Name" (push (julia-workbench--doc-decode value) names))
          (_ (error "Unknown documentation field %s" field))))
      (forward-line 1))
    (unless (and (member "Scope" seen)
                 (if (equal command "lookup")
                     (and (member "Symbol" seen) (member "Documented" seen)
                          (member "Markdown" seen) (not (member "Truncated" seen))
                          (not names) (equal query (plist-get data :symbol)))
                   (and (member "Truncated" seen) (not (member "Symbol" seen))
                        (not (member "Markdown" seen)) (not (member "Documented" seen)))))
      (error "Incomplete or mismatched documentation response"))
    (when (or (cl-some #'string-empty-p names)
              (/= (length names) (length (delete-dups (copy-sequence names)))))
      (error "Invalid documentation symbol list"))
    (plist-put data :symbols (nreverse names))))

(defun julia-workbench--doc-cached (context command query)
  "Return a validated cached result for CONTEXT, COMMAND and QUERY, or nil."
  (let* ((file (julia-workbench--doc-location context command query))
         (attributes (file-attributes file))
         (key (list file (and attributes (file-attribute-size attributes))
                    (and attributes (file-attribute-modification-time attributes)))))
    (or (gethash key julia-workbench--doc-cache)
        (when (and attributes
                   (<= (file-attribute-size attributes) (plist-get context :max-output)))
          (condition-case nil
              (with-temp-buffer
                (let ((coding-system-for-read 'utf-8-unix)) (insert-file-contents file))
                (let ((data (julia-workbench--doc-parse command query)))
                  (puthash key data julia-workbench--doc-cache)
                  data))
            (error nil))))))

(defun julia-workbench--doc-save (context command query)
  "Atomically save this validated protocol buffer for CONTEXT, COMMAND and QUERY."
  (let* ((file (julia-workbench--doc-location context command query))
         (directory (file-name-directory file)) (temporary nil))
    (make-directory directory t)
    (unwind-protect
        (progn
          (setq temporary (make-temp-file (expand-file-name ".doc-" directory)))
          (let ((coding-system-for-write 'utf-8-unix))
            (write-region (point-min) (point-max) temporary nil 'silent))
          (rename-file temporary file t))
      (when (and temporary (file-exists-p temporary)) (delete-file temporary)))
    (clrhash julia-workbench--doc-cache)))

(defun julia-workbench--doc-current-p (context)
  "Return non-nil if CONTEXT still agrees with its live source buffer."
  (when-let* ((source (plist-get context :source)) ((buffer-live-p source)))
    (with-current-buffer source
      (condition-case nil
          (equal (plist-get context :key)
                 (plist-get (julia-workbench--doc-context (plist-get context :hover)) :key))
        (error nil)))))

(defun julia-workbench--doc-request (context command query callback &optional refresh)
  "Request COMMAND/QUERY for CONTEXT, calling CALLBACK with (DATA ERROR).
Use a cached result unless REFRESH is non-nil.  Return a process for a helper
or nil for a cache hit.  Julia startup and queries never block the command loop."
  (if-let* ((data (and (not refresh) (julia-workbench--doc-cached context command query))))
      (progn (funcall callback data nil) nil)
    (when (>= (hash-table-count julia-workbench--doc-jobs)
              julia-workbench-documentation-max-jobs)
      (user-error "Too many documentation helpers; cancel an existing request"))
    (let* ((default-directory (plist-get context :root))
           (environment (plist-get context :environment))
           (process-environment (copy-sequence process-environment))
           (output (generate-new-buffer " *Julia documentation output*"))
           (log (generate-new-buffer "*Julia documentation log*"))
           (timer nil))
      (condition-case err
          (when (plist-get context :standalone)
            (make-directory environment t)
            (unless (julia-workbench--project-file environment)
              (with-temp-file (expand-file-name "Project.toml" environment) (insert "[deps]\n"))))
        (error
         (kill-buffer output) (kill-buffer log)
         (signal (car err) (cdr err))))
      ;; Never fall back to packages in the user's default global environment.
      (setenv "JULIA_LOAD_PATH" "@:@stdlib")
      (with-current-buffer log (special-mode))
      (condition-case err
          (let ((process
                 (make-process
                  :name "julia-workbench-documentation" :buffer output :stderr log
                  :noquery t :connection-type 'pipe :coding 'utf-8-unix
                  :command (append (list (plist-get context :executable)
                                         "--startup-file=no" "--history-file=no"
                                         (concat "--project=" environment)
                                         (plist-get context :helper) "--protocol" command query)
                                   (plist-get context :packages))
                  :filter
                  (lambda (process text)
                    (when (buffer-live-p output)
                      (with-current-buffer output
                        (goto-char (point-max)) (insert text)
                        (when (> (position-bytes (point-max))
                                 (1+ (plist-get context :max-output)))
                          (process-put process 'failure "Documentation output limit exceeded")
                          (delete-process process)))))
                  :sentinel
                  (lambda (process event)
                    (when (memq (process-status process) '(exit signal))
                      (when timer (cancel-timer timer))
                      (remhash process julia-workbench--doc-jobs)
                      (let ((data nil) (failure nil))
                        (condition-case err
                            (progn
                              (unless (and (eq (process-status process) 'exit)
                                           (zerop (process-exit-status process)))
                                (error "%s" (or (process-get process 'failure)
                                                (string-trim event))))
                              (with-current-buffer output
                                (setq data (julia-workbench--doc-parse command query))
                                (unless (julia-workbench--doc-current-p context)
                                  (error "Documentation settings changed; request again"))
                                ;; Cache persistence failure should still show valid docs.
                                (condition-case err
                                    (julia-workbench--doc-save context command query)
                                  (file-error (message "Documentation cache: %s"
                                                       (error-message-string err))))))
                          (error (setq data nil failure (error-message-string err))))
                        (when (buffer-live-p output) (kill-buffer output))
                        (when-let* ((stderr (get-buffer-process log))) (delete-process stderr))
                        (if failure
                            (when (buffer-live-p log)
                              (with-current-buffer log
                                (let ((inhibit-read-only t))
                                  (goto-char (point-max)) (insert "\n" failure "\n"))))
                          (when (buffer-live-p log) (kill-buffer log)))
                        (funcall callback data (when failure
                                                 (format "%s; see %s" failure (buffer-name log))))))))))
            (process-put process 'log log)
            (puthash process t julia-workbench--doc-jobs)
            (setq timer (run-at-time (plist-get context :timeout) nil
                                     (lambda ()
                                       (when (process-live-p process)
                                         (process-put process 'failure "Documentation helper timed out")
                                         (delete-process process)))))
            process)
        (error
         (kill-buffer output) (kill-buffer log)
         (signal (car err) (cdr err)))))))

(defun julia-workbench--doc-symbol-at-point ()
  "Return a Julia qualified name, macro or operator around point, or nil."
  (save-excursion
    (let ((position (point)) (fallback nil) (found nil)
          (pattern (concat "\\(?:[[:alpha:]_][[:alnum:]_!]*\\.\\)*"
                           "\\(?:@?[[:alpha:]_][[:alnum:]_!]*"
                           "\\|[!+*/^%<>=~&|:$?\\-]+\\|\\.\\{2,3\\}\\)")))
      (goto-char (line-beginning-position))
      (while (and (not found) (re-search-forward pattern (line-end-position) t))
        (cond ((and (<= (match-beginning 0) position) (< position (match-end 0)))
               (setq found (match-string-no-properties 0)))
              ((= position (match-end 0)) (setq fallback (match-string-no-properties 0)))))
      (or found fallback))))

(defvar julia-workbench-documentation-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (keymap-set map "n" #'forward-button)
    (keymap-set map "p" #'backward-button)
    (keymap-set map "l" #'julia-workbench-documentation-back)
    (keymap-set map "r" #'julia-workbench-documentation-forward)
    (keymap-set map "g" #'julia-workbench-documentation-refresh)
    (keymap-set map "c" #'julia-workbench-documentation-cancel)
    map)
  "Keymap for persistent documentation and search results.")

(define-derived-mode julia-workbench-documentation-mode special-mode "Julia Docs"
  "Persistent Julia help with symbol buttons and rendered history."
  (setq-local font-lock-defaults
              '((("^#+ .*$" . font-lock-function-name-face)
                 ("`[^`\n]+`" . font-lock-constant-face)
                 ("^    .+$" . font-lock-string-face)))))

(defun julia-workbench--doc-cancel-buffer ()
  "Cancel this results buffer's request and invalidate its callbacks."
  (cl-incf julia-workbench--doc-generation)
  (when (process-live-p julia-workbench--doc-process)
    (process-put julia-workbench--doc-process 'failure "Documentation request cancelled")
    (delete-process julia-workbench--doc-process))
  (setq julia-workbench--doc-process nil))

(defun julia-workbench--doc-buffer (context command query)
  "Prepare and display a persistent results buffer for CONTEXT, COMMAND and QUERY."
  (let ((buffer (get-buffer-create "*Julia Documentation*")))
    (with-current-buffer buffer
      (unless (derived-mode-p 'julia-workbench-documentation-mode)
        (julia-workbench-documentation-mode)
        (add-hook 'kill-buffer-hook #'julia-workbench--doc-cancel-buffer nil t))
      (julia-workbench--doc-cancel-buffer)
      (setq julia-workbench--doc-context context
            julia-workbench--doc-last-request (list command query))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Julia documentation: %s %s\n\nLoading asynchronously…\n\nEnvironment: %s\nExplicit packages: %s\n\nCancel: c\n"
                        command query (plist-get context :environment)
                        (if (plist-get context :packages)
                            (string-join (plist-get context :packages) ", ") "none")))))
    (display-buffer buffer)
    buffer))

(defun julia-workbench--doc-render (context command query data failure)
  "Render DATA or FAILURE for COMMAND/QUERY in CONTEXT in the current help buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (format "%s: %s\n\n" (if (equal command "search") "Documentation search" "Julia documentation") query))
    (insert (format "Environment: %s\n" (plist-get context :environment)))
    (if failure
        (insert "\n" failure "\n\nRefresh: g   Cancel: c\n")
      (insert (format "Julia %s\nScope: %s\n\n" (plist-get data :version) (plist-get data :scope)))
      (if (equal command "lookup")
          (progn
            (unless (plist-get data :found)
              (insert "No docstring found; a defined binding may have a generated summary.\n\n"))
            (insert (plist-get data :markdown)))
        (insert (format "%d results%s\n\n" (length (plist-get data :symbols))
                        (if (plist-get data :truncated) " (truncated at 100)" "")))
        (unless (plist-get data :symbols)
          (insert "No documentation matches in the selected scope.\n"))
        (dolist (symbol (plist-get data :symbols))
          (insert-text-button symbol 'follow-link t
                              'action (lambda (_button)
                                        (julia-workbench--doc-show context "lookup" symbol)))
          (insert "\n")))
      (insert "\n\nLookup: RET on a symbol   History: l/r   Refresh: g   Cancel: c\n"))
    (goto-char (point-min))
    (setq julia-workbench--doc-history
          (cons (list context command query (buffer-substring (point-min) (point-max)))
                (nthcdr julia-workbench--doc-history-position julia-workbench--doc-history))
          julia-workbench--doc-history-position 0)))

(defun julia-workbench--doc-show (context command query &optional refresh)
  "Display asynchronous documentation COMMAND/QUERY for CONTEXT.
With REFRESH, bypass the cached result."
  (let* ((buffer (julia-workbench--doc-buffer context command query))
         (generation (buffer-local-value 'julia-workbench--doc-generation buffer)))
    (condition-case err
        (let ((process
               (julia-workbench--doc-request
                context command query
                (lambda (data failure)
                  (when (buffer-live-p buffer)
                    (with-current-buffer buffer
                      (when (= generation julia-workbench--doc-generation)
                        (setq julia-workbench--doc-process nil)
                        (julia-workbench--doc-render context command query data failure)))))
                refresh)))
          (with-current-buffer buffer (setq julia-workbench--doc-process process))
          process)
      (error
       (with-current-buffer buffer
         (julia-workbench--doc-render context command query nil (error-message-string err)))
       nil))))

;;;###autoload
(defun julia-workbench-documentation (&optional symbol refresh)
  "Look up SYMBOL with completion from the selected helper's documented names.
Interactively, build a missing name index asynchronously before prompting.
A supplied SYMBOL starts lookup immediately.  With REFRESH, bypass the cache.
Neither path evaluates query text."
  (interactive)
  (let* ((context (julia-workbench--doc-context))
         (source (current-buffer))
         (default (julia-workbench--doc-symbol-at-point)))
    (if symbol (julia-workbench--doc-show context "lookup" symbol refresh)
      (let* ((buffer (julia-workbench--doc-buffer context "names" ""))
             (generation (buffer-local-value 'julia-workbench--doc-generation buffer))
             (process
              (julia-workbench--doc-request
               context "names" ""
               (lambda (data failure)
                 (when (and (buffer-live-p buffer) (buffer-live-p source)
                            (= generation (buffer-local-value 'julia-workbench--doc-generation buffer)))
                   (with-current-buffer buffer (setq julia-workbench--doc-process nil))
                   (cond
                    (failure
                     (with-current-buffer buffer
                       (julia-workbench--doc-render context "names" "" nil failure)))
                    ((active-minibuffer-window)
                     (with-current-buffer buffer
                       (julia-workbench--doc-render context "names" "" data nil))
                     (message "Julia name index ready; invoke julia-workbench-documentation to choose a symbol"))
                    (t
                     (with-current-buffer source
                       (condition-case nil
                           (julia-workbench--doc-show
                            context "lookup"
                            (completing-read "Julia symbol: " (plist-get data :symbols)
                                             nil nil nil 'julia-workbench--doc-input-history default))
                         (quit (with-current-buffer buffer
                                 (julia-workbench--doc-render context "names" "" nil "Lookup cancelled")))))))))
               refresh)))
        ;; A cache hit can invoke the callback and start a lookup immediately.
        (when process (with-current-buffer buffer (setq julia-workbench--doc-process process)))
        process))))

;;;###autoload
(defun julia-workbench-documentation-search (query)
  "Search docstring text literally for QUERY in the explicitly selected scope."
  (interactive (list (read-string "Julia documentation text: " nil
                                  'julia-workbench--doc-input-history)))
  (when (string-empty-p (string-trim query)) (user-error "Enter documentation search text"))
  (julia-workbench--doc-show (julia-workbench--doc-context) "search" query))

(defun julia-workbench--doc-hover (callback timeout)
  "Request persistent Eglot hover, calling CALLBACK with (TEXT ERROR).
Use TIMEOUT seconds.  Keep version-sensitive position/markup adapters here;
unlike the ElDoc provider this request survives hiding the source window."
  (jsonrpc-async-request
   (eglot-current-server) :textDocument/hover (eglot--TextDocumentPositionParams)
   :timeout timeout
   :success-fn (lambda (response)
                 (let ((contents (plist-get response :contents)))
                   (if (seq-empty-p contents)
                       (funcall callback nil "No language-server documentation at point; use named lookup")
                     (funcall callback (eglot--format-markup contents) nil))))
   :error-fn (lambda (error) (funcall callback nil (format "Language-server hover failed: %S" error)))
   :timeout-fn (lambda () (funcall callback nil "Language-server hover timed out"))))

;;;###autoload
(defun julia-workbench-documentation-at-point ()
  "Display persistent documentation at point.
Use Eglot's asynchronous hover for connected source buffers, including local
bindings; otherwise look up the name in a separate project-aware helper."
  (interactive)
  (let* ((source (current-buffer))
         (symbol (or (julia-workbench--doc-symbol-at-point) (user-error "No Julia symbol at point")))
         (hover (and (eglot-managed-p) (eglot-current-server)))
         (context (julia-workbench--doc-context hover)))
    (if hover
        (let* ((buffer (julia-workbench--doc-buffer context "lookup" symbol))
               (generation (buffer-local-value 'julia-workbench--doc-generation buffer)))
          ;; A display rule can select help immediately (e.g. Doom popups).
          ;; Build server/position parameters in the captured source buffer.
          (with-current-buffer source
            (julia-workbench--doc-hover
             (lambda (text failure)
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (when (= generation julia-workbench--doc-generation)
                     (julia-workbench--doc-render
                      context "lookup" symbol
                      (list :version "(Eglot hover)" :scope "Current language-server workspace"
                            :found t :markdown text)
                      (if (julia-workbench--doc-current-p context) failure
                        "Source settings changed; request again"))))))
             (plist-get context :timeout))))
      (julia-workbench--doc-show context "lookup" symbol))))

;;;###autoload
(defun julia-workbench-documentation-select-packages (packages)
  "Select PACKAGES explicitly for documentation in this buffer.
Interactively read comma-separated names.  Selection itself loads no packages."
  (interactive (list (split-string
                      (read-string "Documentation packages (comma-separated): "
                                   (string-join julia-workbench-documentation-packages ", "))
                      "[ ,]+" t)))
  (setq-local julia-workbench-documentation-packages (delete-dups packages))
  (message "Documentation packages: %s"
           (if packages (string-join packages ", ") "none")))

(defun julia-workbench--doc-history-move (offset)
  "Move OFFSET entries through this help buffer's rendered history."
  (let* ((position (+ julia-workbench--doc-history-position offset))
         (entry (and (>= position 0) (nth position julia-workbench--doc-history))))
    (unless entry (user-error "No further documentation history"))
    (julia-workbench--doc-cancel-buffer)
    (setq julia-workbench--doc-history-position position
          julia-workbench--doc-context (nth 0 entry)
          julia-workbench--doc-last-request (list (nth 1 entry) (nth 2 entry)))
    (let ((inhibit-read-only t)) (erase-buffer) (insert (nth 3 entry)) (goto-char (point-min)))))

(defun julia-workbench-documentation-back ()
  "Display the previous documentation history entry."
  (interactive) (julia-workbench--doc-history-move 1))

(defun julia-workbench-documentation-forward ()
  "Display the next documentation history entry."
  (interactive) (julia-workbench--doc-history-move -1))

(defun julia-workbench-documentation-refresh ()
  "Refresh this help buffer's request with current source settings.
Bypass its cached result.  An unchanged runtime wrapper can also be refreshed."
  (interactive)
  (unless julia-workbench--doc-last-request (user-error "No documentation request to refresh"))
  (let* ((request julia-workbench--doc-last-request)
         (old-context julia-workbench--doc-context)
         (source (plist-get julia-workbench--doc-context :source))
         (context (if (buffer-live-p source)
                      (with-current-buffer source
                        (julia-workbench--doc-context (plist-get old-context :hover)))
                    (user-error "Source buffer was killed; start a new documentation request"))))
    (cond
     ((plist-get old-context :hover)
      (let ((position (plist-get old-context :point)))
        (with-current-buffer source
          (save-excursion (goto-char position) (julia-workbench-documentation-at-point)))))
     ((equal (car request) "names")
      (with-current-buffer source (julia-workbench-documentation nil t)))
     (t (julia-workbench--doc-show context (car request) (cadr request) t)))))

(defun julia-workbench-documentation-cancel ()
  "Cancel this help buffer's current request, retaining its captured error log."
  (interactive)
  (let ((buffer (if (derived-mode-p 'julia-workbench-documentation-mode)
                    (current-buffer) (get-buffer "*Julia Documentation*"))))
    (unless buffer (user-error "No documentation results buffer"))
    (with-current-buffer buffer
      (julia-workbench--doc-cancel-buffer)
      (let ((inhibit-read-only t)) (goto-char (point-max)) (insert "\nRequest cancelled.\n")))))

;;;###autoload
(defun julia-workbench-documentation-manual-search (query)
  "Open official Julia manual search for QUERY using `browse-url'.
This optional command uses the network; local documentation remains offline."
  (interactive (list (read-string "Julia manual search: " (julia-workbench--doc-symbol-at-point))))
  (browse-url (concat "https://docs.julialang.org/en/v1/search/?q=" (url-hexify-string query))))

(defun julia-workbench-documentation-eldoc (callback &rest _ignored)
  "Offer cached helper documentation at point to ElDoc CALLBACK.
Never start a process while typing; Eglot supplies connected-buffer docs."
  (unless (eglot-managed-p)
    (when-let* ((symbol (julia-workbench--doc-symbol-at-point))
                (context (condition-case nil (julia-workbench--doc-context) (error nil)))
                (data (julia-workbench--doc-cached context "lookup" symbol))
                ((plist-get data :found)))
      (funcall callback (plist-get data :markdown) :thing symbol)
      t)))

(defun julia-workbench--setup-documentation ()
  "Install a cache-only ElDoc provider locally, preserving other providers."
  (add-hook 'eldoc-documentation-functions #'julia-workbench-documentation-eldoc t t))

(defun julia-workbench--doc-invalidate (_project)
  "Invalidate helper caches and outstanding callbacks after changing PROJECT."
  (clrhash julia-workbench--doc-cache)
  (when-let* ((buffer (get-buffer "*Julia Documentation*")))
    (with-current-buffer buffer (julia-workbench--doc-cancel-buffer))))

(defun julia-workbench--doc-cleanup ()
  "Terminate all documentation helpers on Emacs shutdown."
  (maphash (lambda (process _value)
             (when (process-live-p process) (delete-process process)))
           (copy-hash-table julia-workbench--doc-jobs)))

(add-hook 'julia-workbench-environment-change-hook #'julia-workbench--doc-invalidate)
(add-hook 'kill-emacs-hook #'julia-workbench--doc-cleanup)

(provide 'julia-workbench-doc)
;;; julia-workbench-doc.el ends here
