;;; julia-workbench-repl.el --- Project Julia REPL and evaluation -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Julia Workbench contributors
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "30.1"))

;;; Commentary:
;; Explicit, project/environment-scoped comint sessions.  Source requests use
;; Julia's include APIs with filenames and line offsets.  Runtime documentation
;; and completion use the live Main module, separately from Eglot/helper jobs.

;;; Code:

(require 'julia-workbench-eglot)
(require 'julia-workbench-plot)
(require 'comint)
(require 'help-mode)

(defcustom julia-workbench-repl-arguments nil
  "Additional Julia command-line options for REPL sessions.
Use options such as --threads=auto, leaving project, startup and entry-point
options to Workbench.  Changing this list selects a distinct session."
  :type '(repeat string) :group 'julia-workbench)
(make-variable-buffer-local 'julia-workbench-repl-arguments)

(defcustom julia-workbench-repl-startup-timeout 30
  "Seconds to wait for a new Julia REPL to initialize."
  :type 'number :group 'julia-workbench)

(defcustom julia-workbench-repl-queue-limit 32
  "Maximum outstanding editor evaluations in one REPL."
  :type 'natnum :group 'julia-workbench)

(defvar julia-workbench--repl-sessions (make-hash-table :test #'equal)
  "REPL buffers indexed by workspace, environment, executable and arguments.")
(defvar-local julia-workbench--repl-context nil
  "Captured session settings, independent of subsequent source settings.")
(defvar-local julia-workbench--repl-token nil
  "Unique session token delimiting hidden response records.")
(defvar-local julia-workbench--repl-fragment ""
  "Incomplete response frame retained between process output chunks.")
(defvar-local julia-workbench--repl-state 'stopped
  "Current process state: starting, idle, busy or stopped.")
(defvar-local julia-workbench--repl-version nil
  "Julia version reported by the initialized process.")
(defvar-local julia-workbench--repl-last-result nil
  "Rendered last successful evaluation, including semicolon-suppressed values.")
(defvar-local julia-workbench--repl-pending nil
  "Request currently evaluating in Julia.")
(defvar-local julia-workbench--repl-queue nil
  "Editor requests waiting for startup or a previous evaluation.")
(defvar-local julia-workbench--repl-serial 0
  "Monotonically increasing request identifier for this session.")
(defvar-local julia-workbench--repl-timer nil
  "Startup deadline timer, cancelled on readiness or process termination.")
(defvar-local julia-workbench--repl-source nil
  "Most recent source buffer, for switching back from the REPL.")

(defun julia-workbench--repl-settings ()
  "Resolve local REPL settings without starting or probing Julia."
  (if (derived-mode-p 'julia-workbench-repl-mode)
      julia-workbench--repl-context
    (let* ((project (julia-workbench-resolve-project))
           (executable (file-truename (julia-workbench--executable project)))
           (root (project-root project))
           (environment
            (or (julia-workbench-project-environment project)
                (expand-file-name
                 (concat "standalone/repl/"
                         (secure-hash 'sha256 (prin1-to-string (list root executable))))
                 (julia-workbench-project-cache project))))
           (formats (julia-workbench--plot-formats))
           (_ (unless (and (integerp julia-workbench-plot-max-bytes)
                           (> julia-workbench-plot-max-bytes 0))
                (user-error "Julia plot byte limit must be a positive integer")))
           (key (list root environment executable (copy-sequence julia-workbench-repl-arguments)
                      formats julia-workbench-plot-max-bytes)))
      (list :key key :root root :environment environment :executable executable
            :arguments (copy-sequence julia-workbench-repl-arguments)
            :cache (julia-workbench-project-cache project)
            :plot-formats formats :plot-max-bytes julia-workbench-plot-max-bytes
            :standalone (null (julia-workbench-project-environment project))))))

(defun julia-workbench--repl-history ()
  "Persist the current comint history outside the package checkout."
  (when comint-input-ring-file-name
    (condition-case err (comint-write-input-ring)
      (file-error (message "Julia history: %s" (error-message-string err))))))

(defun julia-workbench--repl-discard (reason)
  "Discard pending requests and notify their callbacks of REASON."
  (let ((requests (append (when julia-workbench--repl-pending
                            (list julia-workbench--repl-pending))
                          julia-workbench--repl-queue)))
    (setq julia-workbench--repl-pending nil julia-workbench--repl-queue nil)
    (dolist (request requests)
      (when-let* ((callback (plist-get request :callback)))
        (funcall callback nil reason)))))

(defun julia-workbench--repl-cleanup ()
  "Stop this buffer's process, timers and requests when it is killed."
  (setq julia-workbench--repl-state 'stopped)
  (when (timerp julia-workbench--repl-timer)
    (cancel-timer julia-workbench--repl-timer))
  (julia-workbench--repl-history)
  (julia-workbench--repl-discard "REPL buffer killed")
  (when julia-workbench--repl-context
    (let ((key (plist-get julia-workbench--repl-context :key)))
      (when (eq (gethash key julia-workbench--repl-sessions) (current-buffer))
        (remhash key julia-workbench--repl-sessions))))
  (when-let* ((process (get-buffer-process (current-buffer))))
    (delete-process process))
  (julia-workbench--plot-cleanup))

(defun julia-workbench--repl-sentinel (process event)
  "Update session status and preserve history for PROCESS and EVENT."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (unless (process-live-p process)
        (setq julia-workbench--repl-state 'stopped)
        (when (timerp julia-workbench--repl-timer)
          (cancel-timer julia-workbench--repl-timer))
        (julia-workbench--repl-discard (string-trim event))
        (julia-workbench--repl-history))
      (when-let* ((sentinel (process-get process 'julia-workbench-original-sentinel)))
        (funcall sentinel process event))
      (force-mode-line-update))))

(defun julia-workbench--repl-deadline (buffer process)
  "Terminate PROCESS if BUFFER still awaits initial readiness."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and (eq process (get-buffer-process buffer))
                 (eq julia-workbench--repl-state 'starting))
        (comint-output-filter process "\nJulia REPL startup timed out; inspect this buffer and restart.\n")
        (delete-process process)))))

(defun julia-workbench--repl-dispatch ()
  "Send the next queued request when the Julia process is idle."
  (when (and (eq julia-workbench--repl-state 'idle)
             julia-workbench--repl-queue)
    (let* ((request (pop julia-workbench--repl-queue))
           (process (get-buffer-process (current-buffer))))
      (setq julia-workbench--repl-pending request julia-workbench--repl-state 'busy)
      (comint-send-string process (plist-get request :wire))
      (force-mode-line-update))))

(defun julia-workbench--repl-record (frame)
  "Consume the hidden response FRAME for this session only."
  (let ((fields (split-string frame "\t")))
    (when (and (= (length fields) 5) (equal (car fields) julia-workbench--repl-token))
      (condition-case err
          (let* ((id (nth 1 fields)) (kind (nth 2 fields))
                 (ok (equal (nth 3 fields) "ok"))
                 (text (decode-coding-string (base64-decode-string (nth 4 fields)) 'utf-8))
                 (request julia-workbench--repl-pending))
            (cond
             ((and (equal id "0") (equal kind "plot") ok
                   (memq julia-workbench--repl-state '(idle busy)))
              (julia-workbench--plot-receive text))
             ((and (equal id "0") (equal kind "ready")
                   (eq julia-workbench--repl-state 'starting) ok)
              (setq julia-workbench--repl-state 'idle julia-workbench--repl-version text)
              (when (timerp julia-workbench--repl-timer)
                (cancel-timer julia-workbench--repl-timer)))
             ((and request (equal id (number-to-string (plist-get request :id)))
                   (equal kind (plist-get request :kind)))
              (setq julia-workbench--repl-pending nil julia-workbench--repl-state 'idle)
              (when (and ok (member kind '("eval" "file")))
                (setq julia-workbench--repl-last-result text))
              (when-let* ((callback (plist-get request :callback)))
                (funcall callback ok text)))))
        (error (message "Julia REPL response: %s" (error-message-string err))))
      (julia-workbench--repl-dispatch)
      (force-mode-line-update))))

(defun julia-workbench--repl-filter (output)
  "Remove hidden records from OUTPUT, allowing arbitrary process chunk splits."
  (let ((text (concat julia-workbench--repl-fragment output)) (visible "")
        (prefix (concat "\036" julia-workbench--repl-token "\t")))
    (setq julia-workbench--repl-fragment "")
    (while (not (string-empty-p text))
      (if-let* ((start (string-match "\036" text)))
          (progn
            (setq visible (concat visible (substring text 0 start))
                  text (substring text start))
            (cond
             ((not (or (string-prefix-p prefix text) (string-prefix-p text prefix)))
              (setq visible (concat visible "\036") text (substring text 1)))
             ((string-match "\037" text)
              (let ((stop (match-beginning 0)))
                (julia-workbench--repl-record (substring text 1 stop))
                (setq text (substring text (1+ stop)))))
             (t
              (if (> (length text) 1000000) (setq visible (concat visible text))
                (setq julia-workbench--repl-fragment text))
              (setq text ""))))
        (setq visible (concat visible text) text "")))
    visible))

(defun julia-workbench--repl-shutdown-all ()
  "Save history and stop all Workbench REPLs when Emacs exits."
  (maphash (lambda (_key buffer)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer (julia-workbench--repl-cleanup))))
           (copy-hash-table julia-workbench--repl-sessions)))

(defun julia-workbench--repl-header ()
  "Return a readable Julia process/environment status."
  (format " Julia %s | %s%s | %s"
          (or julia-workbench--repl-version "starting") julia-workbench--repl-state
          (if julia-workbench--repl-queue
              (format " (%d queued)" (length julia-workbench--repl-queue)) "")
          (plist-get julia-workbench--repl-context :environment)))

(defvar julia-workbench-repl-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map comint-mode-map)
    (keymap-set map "C-c C-z" #'julia-workbench-repl)
    (keymap-set map "C-c C-c" #'julia-workbench-repl-interrupt)
    (keymap-set map "C-c C-r" #'julia-workbench-repl-restart)
    (keymap-set map "C-c C-d" #'julia-workbench-repl-documentation)
    (keymap-set map "C-c C-p" #'julia-workbench-show-plots)
    (keymap-set map "C-j" #'comint-accumulate)
    (keymap-set map "M-TAB" #'julia-workbench-repl-complete)
    map)
  "Keymap for project Julia comint buffers.")

(define-derived-mode julia-workbench-repl-mode comint-mode "Julia REPL"
  "Comint mode for an explicitly started Julia runtime.
\\<julia-workbench-repl-mode-map>\\[comint-send-input] evaluates complete input;
\\[comint-accumulate] accumulates multiline input.  Navigate persistent
history with \\[comint-previous-input] and \\[comint-next-input].
Runtime lookup/completion query Main."
  :syntax-table julia-workbench-mode-syntax-table
  (setq-local comint-prompt-regexp "^julia> "
              comint-use-prompt-regexp t
              comint-prompt-read-only t
              comint-input-sender #'julia-workbench--repl-input
              comint-process-echoes nil
              comint-input-ring-separator "\n\000\n"
              header-line-format '(:eval (julia-workbench--repl-header)))
  (add-hook 'comint-preoutput-filter-functions #'julia-workbench--repl-filter nil t)
  (add-hook 'kill-buffer-hook #'julia-workbench--repl-cleanup nil t))

(defun julia-workbench--repl-start (context &optional buffer)
  "Start CONTEXT's session asynchronously in BUFFER or a new comint buffer."
  (let* ((key (plist-get context :key))
         (environment (plist-get context :environment))
         (history (expand-file-name
                   (concat "repl-history/" (secure-hash 'sha256 (prin1-to-string key)))
                   (plist-get context :cache)))
         (helper (julia-workbench--asset "repl.jl"))
         (_ (when (or (file-remote-p environment)
                      (and (not (plist-get context :standalone))
                           (not (julia-workbench--project-file environment))))
              (user-error "REPL requires a local Julia project: %s" environment)))
         (buffer (or buffer (generate-new-buffer
                             (format "*Julia REPL %s*"
                                     (file-name-nondirectory
                                      (directory-file-name environment))))))
         (token (secure-hash 'sha256 (format "%s %s %s" key (float-time) (random)))))
    (when (plist-get context :standalone)
      (make-directory environment t)
      (unless (julia-workbench--project-file environment)
        (with-temp-file (expand-file-name "Project.toml" environment) (insert "[deps]\n"))))
    (make-directory (file-name-directory history) t)
    (with-current-buffer buffer
      (julia-workbench--plot-cleanup)
      (julia-workbench-repl-mode)
      (setq default-directory (plist-get context :root)
            julia-workbench--repl-context context julia-workbench--repl-token token
            julia-workbench--repl-state 'starting comint-input-ring-file-name history)
      (comint-read-input-ring t)
      (condition-case err
          (let* ((process-connection-type nil)
                 (process-environment (copy-sequence process-environment))
                 (_ (progn
                      (when (plist-get context :plot-formats)
                        ;; GR can open gksqt while measuring/drawing MIME output.
                        ;; Choose its null workstation before GR is loaded, while
                        ;; respecting explicitly configured workstation settings.
                        (unless (or (getenv "GKSwstype") (getenv "GKS_WSTYPE"))
                          (setenv "GKSwstype" "100"))
                        (let ((root (expand-file-name "plots" (plist-get context :cache))))
                          (make-directory root t)
                          (setq julia-workbench--plot-directory
                                (make-temp-file (expand-file-name "session-" root) t))))
                      (setenv "JULIA_WORKBENCH_PLOT_DIRECTORY" julia-workbench--plot-directory)
                      (setenv "JULIA_WORKBENCH_PLOT_FORMATS"
                              (mapconcat #'symbol-name (plist-get context :plot-formats) ","))
                      (setenv "JULIA_WORKBENCH_PLOT_MAX_BYTES"
                              (number-to-string (or (plist-get context :plot-max-bytes)
                                                    julia-workbench-plot-max-bytes)))
                      (setenv "TERM" "dumb")
                      (setenv "JULIA_LOAD_PATH" (concat "@" path-separator "@stdlib"))
                      (apply #'make-comint-in-buffer "julia-workbench-repl" buffer
                           (plist-get context :executable) nil
                           (append (plist-get context :arguments)
                                   (list "--startup-file=no" "--history-file=no" "--color=no"
                                         "--banner=no" (concat "--project=" environment)
                                         "--interactive" "-L" helper "-e"
                                         (format "WorkbenchREPL.run(\"%s\"); exit()" token))))))
                 (process (get-buffer-process buffer)))
            (set-process-coding-system process 'utf-8-unix 'utf-8-unix)
            (set-process-query-on-exit-flag process nil)
            (process-put process 'julia-workbench-original-sentinel (process-sentinel process))
            (set-process-sentinel process #'julia-workbench--repl-sentinel)
            (setq julia-workbench--repl-timer
                  (run-at-time julia-workbench-repl-startup-timeout nil
                               #'julia-workbench--repl-deadline buffer process))
            (puthash key buffer julia-workbench--repl-sessions))
        (error (setq julia-workbench--repl-state 'stopped)
               (julia-workbench--plot-cleanup)
               (signal (car err) (cdr err)))))
    buffer))

(defun julia-workbench--repl-buffer (&optional start)
  "Find the current session; when START is non-nil, create it if needed."
  (let* ((context (julia-workbench--repl-settings))
         (buffer (if (derived-mode-p 'julia-workbench-repl-mode) (current-buffer)
                   (gethash (plist-get context :key) julia-workbench--repl-sessions))))
    (cond
     ((and (buffer-live-p buffer) (comint-check-proc buffer)) buffer)
     (start (julia-workbench--repl-start context (and (buffer-live-p buffer) buffer)))
     (t (user-error "No live Julia REPL for this environment; run M-x julia-workbench-repl")))))

;;;###autoload
(defun julia-workbench-repl ()
  "Start or show this project's Julia REPL; switch back when called there."
  (interactive)
  (if (and (derived-mode-p 'julia-workbench-repl-mode)
           (buffer-live-p julia-workbench--repl-source))
      (pop-to-buffer julia-workbench--repl-source)
    (let ((source (current-buffer)) (buffer (julia-workbench--repl-buffer t)))
      (with-current-buffer buffer
        (unless (eq buffer source) (setq julia-workbench--repl-source source)))
      (pop-to-buffer buffer))))

(defun julia-workbench--repl-encode (text)
  "Encode TEXT as an unbroken base64 UTF-8 Julia string argument."
  (base64-encode-string (encode-coding-string text 'utf-8) t))

(defun julia-workbench--repl-request (buffer kind source filename line &optional callback label)
  "Queue KIND with SOURCE, FILENAME and LINE in BUFFER.
CALLBACK receives success and rendered text.
LABEL is an optional transcript note."
  (with-current-buffer buffer
    (unless (comint-check-proc buffer) (user-error "Julia REPL is stopped"))
    (when (>= (+ (length julia-workbench--repl-queue)
                 (if julia-workbench--repl-pending 1 0)) julia-workbench-repl-queue-limit)
      (user-error "Julia evaluation queue is full; interrupt or wait"))
    (let* ((id (cl-incf julia-workbench--repl-serial))
           (wire (format "WorkbenchREPL.request(%d, \"%s\", \"%s\", \"%s\", %d);\n"
                         id kind (julia-workbench--repl-encode source)
                         (julia-workbench--repl-encode filename) line))
           (request (list :id id :kind kind :wire wire :callback callback)))
      (when label
        (comint-output-filter (get-buffer-process buffer) (concat "# " label "\n")))
      (setq julia-workbench--repl-queue
            (nconc julia-workbench--repl-queue (list request)))
      (julia-workbench--repl-dispatch)
      id)))

(defun julia-workbench--repl-input (process input)
  "Send complete comint INPUT through PROCESS using the same evaluation path."
  (julia-workbench--repl-request (process-buffer process) "eval" input "REPL" 1))

(defun julia-workbench--repl-send (start end)
  "Evaluate source between START and END with its original filename and line."
  (let* ((source (current-buffer))
         (text (buffer-substring-no-properties start end))
         (filename (or buffer-file-name (expand-file-name "untitled.jl" default-directory)))
         (line (line-number-at-pos start t))
         (buffer nil))
    (when (string-empty-p (string-trim text)) (user-error "No Julia code selected"))
    (setq buffer (julia-workbench--repl-buffer t))
    (with-current-buffer buffer (setq julia-workbench--repl-source source))
    (julia-workbench--repl-request buffer "eval" text filename line nil
                                   (format "%s:%d" filename line))
    (display-buffer buffer)))

;;;###autoload
(defun julia-workbench-send-line ()
  "Evaluate the current line in this project's REPL."
  (interactive)
  (julia-workbench--repl-send (line-beginning-position) (line-end-position)))

;;;###autoload
(defun julia-workbench-send-region (start end)
  "Evaluate the region from START to END in this project's REPL."
  (interactive "r")
  (julia-workbench--repl-send start end))

;;;###autoload
(defun julia-workbench-send-top-level-form ()
  "Evaluate the containing top-level form selected by Julia's syntax tree."
  (interactive)
  (let ((node (julia-workbench--top-level-node)))
    (when (treesit-node-check node 'has-error)
      (user-error "Julia form is incomplete; repair it or send a region explicitly"))
    (julia-workbench--repl-send (treesit-node-start node) (treesit-node-end node))))

;;;###autoload
(defun julia-workbench-send-buffer ()
  "Evaluate the whole buffer's current contents, including unsaved edits."
  (interactive)
  (save-restriction
    (widen)
    (julia-workbench--repl-send (point-min) (point-max))))

;;;###autoload
(defun julia-workbench-send-buffer-file ()
  "Include the current saved file in this project's REPL.
For unsaved edits use `julia-workbench-send-buffer', or save the file first."
  (interactive)
  (unless buffer-file-name (user-error "This buffer has no file; use send-buffer"))
  (when (buffer-modified-p) (user-error "Buffer modified; save first or use send-buffer"))
  (when (or (file-remote-p buffer-file-name) (not (file-readable-p buffer-file-name)))
    (user-error "Evaluation requires a readable local file"))
  (let ((source (current-buffer)) (filename buffer-file-name)
        (buffer (julia-workbench--repl-buffer t)))
    (with-current-buffer buffer (setq julia-workbench--repl-source source))
    (julia-workbench--repl-request buffer "file" "" filename 1 nil filename)
    (display-buffer buffer)))

;;;###autoload
(defun julia-workbench-send-dwim ()
  "Evaluate the active region, or the containing structured top-level form.
Without a Julia grammar, explicitly select a region or use send-line/buffer."
  (interactive)
  (if (use-region-p) (julia-workbench-send-region (region-beginning) (region-end))
    (julia-workbench-send-top-level-form)))

;;;###autoload
(defun julia-workbench-repl-activate-project ()
  "Explicitly activate the session's selected project.
No packages are installed.
This restores its original environment after manual Pkg activation.  Source
environment changes select a different session; Eglot is unaffected."
  (interactive)
  (let ((buffer (julia-workbench--repl-buffer t)))
    (with-current-buffer buffer
      (julia-workbench--repl-request
       buffer "activate" (plist-get julia-workbench--repl-context :environment) "" 1 nil
       "Activate selected project"))
    (display-buffer buffer)))

;;;###autoload
(defun julia-workbench-copy-last-eval-result ()
  "Copy the last successful evaluation's text, excluding stdout and prompts."
  (interactive)
  (with-current-buffer (julia-workbench--repl-buffer)
    (unless julia-workbench--repl-last-result (user-error "No successful Julia evaluation yet"))
    (kill-new julia-workbench--repl-last-result)
    (message "Copied last Julia evaluation result")))

;;;###autoload
(defun julia-workbench-repl-interrupt ()
  "Interrupt Julia and discard queued evaluations in this project's session."
  (interactive)
  (with-current-buffer (julia-workbench--repl-buffer)
    ;; Retain the active request until Julia acknowledges its interruption.
    (let ((pending julia-workbench--repl-pending))
      (setq julia-workbench--repl-pending nil)
      (julia-workbench--repl-discard "Queued request cancelled by interrupt")
      (setq julia-workbench--repl-pending pending))
    (interrupt-process (get-buffer-process (current-buffer)))))

;;;###autoload
(defun julia-workbench-repl-restart ()
  "Restart this session explicitly, clearing runtime state and pending requests."
  (interactive)
  (let* ((context (julia-workbench--repl-settings))
         (buffer (if (derived-mode-p 'julia-workbench-repl-mode) (current-buffer)
                   (gethash (plist-get context :key) julia-workbench--repl-sessions)))
         (source (if (derived-mode-p 'julia-workbench-repl-mode)
                     julia-workbench--repl-source (current-buffer))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (julia-workbench--repl-cleanup)
        (let ((inhibit-read-only t)) (goto-char (point-max)) (insert "\n--- Restarting Julia ---\n"))))
    (setq buffer (julia-workbench--repl-start context (and (buffer-live-p buffer) buffer)))
    (with-current-buffer buffer (setq julia-workbench--repl-source source))
    (pop-to-buffer buffer)))

;;;###autoload
(defun julia-workbench-repl-documentation (query)
  "Look up named symbol QUERY in the live REPL, including evaluated definitions.
This asynchronous request shares runtime state.
Helper documentation and LSP use separate processes."
  (interactive (list (read-string "Runtime Julia symbol: " (thing-at-point 'symbol t))))
  (let* ((buffer (julia-workbench--repl-buffer))
         (scope (with-current-buffer buffer
                  (plist-get julia-workbench--repl-context :environment))))
    (julia-workbench--repl-request
     buffer "documentation" query "" 1
     (lambda (ok text)
       (when (and (buffer-live-p buffer)
                  (with-current-buffer buffer (not (eq julia-workbench--repl-state 'stopped))))
         (let ((help (get-buffer-create "*Julia Runtime Documentation*")))
           (with-current-buffer help
             (let ((inhibit-read-only t))
               (erase-buffer)
               (insert (format "Runtime documentation: %s\nSelected environment: %s\n\n%s\n"
                               query scope (if ok text (concat "Lookup failed: " text))))
               (help-mode)))
           (display-buffer help)))))))

(defun julia-workbench--repl-completions (text)
  "Parse runtime completion TEXT into character offsets and candidate strings."
  (let* ((lines (split-string text "\n" t))
         (range (split-string (car lines) "\t")))
    (unless (and (= (length range) 2)
                 (cl-every (lambda (part) (string-match-p "\\`[0-9]+\\'" part)) range))
      (error "Invalid Julia completion range"))
    (list (string-to-number (car range)) (string-to-number (cadr range))
          (mapcar (lambda (line) (decode-coding-string (base64-decode-string line) 'utf-8))
                  (cdr lines)))))

;;;###autoload
(defun julia-workbench-repl-complete ()
  "Request completion asynchronously from the existing runtime's Main module.
Insert candidates only if the source text and point are still unchanged.
This explicit command complements Eglot CAPF; it never replaces that provider."
  (interactive)
  (let* ((buffer (julia-workbench--repl-buffer))
         (source (current-buffer))
         (begin (if (derived-mode-p 'julia-workbench-repl-mode)
                    (marker-position (process-mark (get-buffer-process source)))
                  (line-beginning-position)))
         (end (point)) (tick (buffer-chars-modified-tick))
         (input (progn
                  (when (< end begin) (user-error "Place point in the current REPL input"))
                  (buffer-substring-no-properties begin end))))
    (julia-workbench--repl-request
     buffer "completion" input "" 1
     (lambda (ok text)
       (if (not ok) (message "Julia runtime completion: %s" text)
         (when (buffer-live-p source)
           (with-current-buffer source
             (when (and (= tick (buffer-chars-modified-tick)) (= (point) end))
               (pcase-let ((`(,start ,stop ,candidates) (julia-workbench--repl-completions text)))
                 (when (<= 0 start stop (length input))
                   (completion-in-region (+ begin start) (+ begin stop) candidates)))))))))))

(add-hook 'kill-emacs-hook #'julia-workbench--repl-shutdown-all)

(provide 'julia-workbench-repl)
;;; julia-workbench-repl.el ends here
