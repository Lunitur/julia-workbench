;;; julia-workbench-eglot.el --- Julia projects and Eglot -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Julia Workbench contributors
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "30.1"))

;;; Commentary:
;; Optional Eglot integration.  Loading this file registers the mode, but never
;; starts Julia or installs packages.  Use `julia-workbench-connect' explicitly,
;; or opt into `eglot-ensure' in the major mode hook.  Tooling is installed only
;; by `julia-workbench-setup-server'.

;;; Code:

(require 'julia-workbench)
(require 'eglot)
(require 'project)
(require 'seq)
(require 'subr-x)

(defcustom julia-workbench-environment nil
  "Analyzed environment directory or project file, overriding discovery.
Relative paths are resolved from the ordinary project root.  With nil,
find the nearest JuliaProject.toml or Project.toml.  Standalone files use
an empty environment outside the checkout, created on explicit connection."
  :type '(choice (const :tag "Discover" nil) file)
  :group 'julia-workbench :safe (lambda (value) (or (null value) (stringp value))))
(make-variable-buffer-local 'julia-workbench-environment)

(defcustom julia-workbench-server-command nil
  "Custom Eglot contact, bypassing the bundled Julia launcher and its checks.
Accepts the contact forms documented by `eglot-server-programs', including
a function of INTERACTIVE and PROJECT.  Existing user Eglot mappings also
take precedence.  Changing settings requires an explicit reconnect."
  :type 'sexp :group 'julia-workbench)
(make-variable-buffer-local 'julia-workbench-server-command)

(defcustom julia-workbench-server-project nil
  "Isolated tooling directory, or nil for the Julia helper's versioned path.
With nil, honor JULIA_WORKBENCH_SERVER_PROJECT when set."
  :type '(choice (const nil) directory) :group 'julia-workbench)
(make-variable-buffer-local 'julia-workbench-server-project)

(defcustom julia-workbench-symbol-cache nil
  "Symbol cache directory, or nil for the Julia helper's versioned path.
With nil, honor JULIA_WORKBENCH_SYMBOL_CACHE when set."
  :type '(choice (const nil) directory) :group 'julia-workbench)
(make-variable-buffer-local 'julia-workbench-symbol-cache)

(defcustom julia-workbench-shutdown-timeout 5
  "Seconds to allow a Julia server to shut down before Eglot forces termination."
  :type 'number :group 'julia-workbench)

(defvar julia-workbench-environment-change-hook nil
  "Functions called with the resolved project before explicit reconnect.
Future documentation and completion adapters can invalidate their caches here.
Project and manifest changes take effect after reconnect, never mid-session.")

(defvar julia-workbench--runtime-cache (make-hash-table :test #'equal)
  "Cached Julia runtime probes, cleared on explicit reconnect.")

(cl-defstruct (julia-workbench-project
               (:constructor julia-workbench--make-project))
  "Eglot workspace identity, including its distinct Julia environment."
  root environment executable tooling symbols cache command mapping)

(cl-defmethod project-root ((project julia-workbench-project))
  "Return PROJECT's workspace root, not its active environment."
  (julia-workbench-project-root project))

(defun julia-workbench--directory (path base)
  "Canonicalize directory or project file PATH relative to BASE."
  (let ((expanded (expand-file-name path base)))
    (file-name-as-directory
     (file-truename (if (file-directory-p expanded) expanded
                     (if (member (file-name-nondirectory expanded)
                                 '("JuliaProject.toml" "Project.toml"))
                         (file-name-directory expanded) expanded))))))

(defun julia-workbench--project-file (directory)
  "Find a project file in DIRECTORY using Julia's filename precedence."
  (cl-loop for name in '("JuliaProject.toml" "Project.toml")
           for file = (expand-file-name name directory)
           when (file-regular-p file) return file))

(defun julia-workbench-resolve-project (&optional directory)
  "Resolve workspace and environment for DIRECTORY without running Julia.
Keep the ordinary project root distinct from the nearest package environment.
The returned object also identifies executable and contact settings, so Eglot
shares only compatible connections.  Remote projects require a custom contact."
  (let* ((directory (file-name-as-directory
                     (expand-file-name (or directory default-directory))))
         (project-find-functions
          (remq #'julia-workbench--find-project project-find-functions))
         (eglot-lsp-context nil)
         (ordinary (project-current nil directory))
         (nearest (locate-dominating-file directory
                                         #'julia-workbench--project-file))
         (root (julia-workbench--directory
                (or (and ordinary (project-root ordinary)) nearest directory)
                directory))
         (environment (cond (julia-workbench-environment
                             (julia-workbench--directory
                              julia-workbench-environment root))
                            (nearest (julia-workbench--directory nearest root))))
         (cache (julia-workbench--directory
                 (or julia-workbench-cache-directory
                     (expand-file-name "julia-workbench"
                                       (or (getenv "XDG_CACHE_HOME") "~/.cache")))
                 root)))
    (julia-workbench--make-project
     :root root :environment environment
     :executable (if (string-match-p "/" julia-workbench-julia-command)
                     (expand-file-name julia-workbench-julia-command root)
                   julia-workbench-julia-command)
     :tooling (when-let* ((path (or julia-workbench-server-project
                                   (getenv "JULIA_WORKBENCH_SERVER_PROJECT"))))
                (julia-workbench--directory path root))
     :symbols (when-let* ((path (or julia-workbench-symbol-cache
                                   (getenv "JULIA_WORKBENCH_SYMBOL_CACHE"))))
                (julia-workbench--directory path root))
     :cache cache :command julia-workbench-server-command
     :mapping (cdr (cl-find-if (lambda (entry)
                                (julia-workbench--mode-key-p (car entry)))
                              eglot-server-programs)))))

(defun julia-workbench--find-project (directory)
  "Return Julia's project for DIRECTORY in Eglot's Julia context only."
  (when (and eglot-lsp-context (derived-mode-p 'julia-workbench-mode))
    (julia-workbench-resolve-project directory)))

(defun julia-workbench--asset (name)
  "Return bundled Julia asset NAME, or explain a broken package recipe."
  (let ((file (expand-file-name (concat "julia/" name)
                                julia-workbench--asset-directory)))
    (unless (file-readable-p file)
      (user-error "Missing Julia helper %s; include julia/ in the package recipe" file))
    file))

(defun julia-workbench--executable (project)
  "Check and return PROJECT's local Julia executable."
  (when (file-remote-p (project-root project))
    (user-error "Bundled launcher supports local projects; configure a custom Eglot contact for remote files"))
  (let* ((name (julia-workbench-project-executable project))
         (path (executable-find name)))
    (unless path
      (user-error "Julia executable %s missing; set julia-workbench-julia-command" name))
    path))

(defun julia-workbench--process-environment (project)
  "Return process environment for PROJECT's bundled helpers."
  (let ((process-environment (copy-sequence process-environment)))
    ;; paths.jl uses XDG_CACHE_HOME plus the julia-workbench suffix.  Override
    ;; its two exact paths below after probing, rather than changing XDG globally.
    (when (julia-workbench-project-tooling project)
      (setenv "JULIA_WORKBENCH_SERVER_PROJECT"
              (julia-workbench-project-tooling project)))
    (when (julia-workbench-project-symbols project)
      (setenv "JULIA_WORKBENCH_SYMBOL_CACHE"
              (julia-workbench-project-symbols project)))
    process-environment))

(defun julia-workbench--runtime (project)
  "Probe PROJECT's Julia version and derive versioned tooling paths.
This small synchronous probe happens only during explicit setup/connection
or diagnostics.  It does not load packages or install anything."
  (let* ((executable (julia-workbench--executable project))
         (key (list project executable (file-attributes executable)))
         (cached (gethash key julia-workbench--runtime-cache)))
    (or cached
        (let* ((default-directory (project-root project))
               (process-environment (julia-workbench--process-environment project))
               (version (with-temp-buffer
                          (unless (zerop (call-process executable nil t nil
                                                       "--startup-file=no" "--version"))
                            (user-error "Julia version probe failed: %s" (buffer-string)))
                          (unless (re-search-backward
                                   "\\([0-9]+\\.[0-9]+\\.[0-9]+\\)" nil t)
                            (user-error "Unrecognized Julia version: %s" (buffer-string)))
                          (match-string 1)))
               (minor (mapconcat #'identity (seq-take (split-string version "\\.") 2) "."))
               (cache (julia-workbench-project-cache project))
               (runtime
                (list :executable executable :version version
                      :tooling (or (julia-workbench-project-tooling project)
                                   (expand-file-name
                                    (concat "LanguageServer-6.0.1/julia-" minor) cache))
                      :symbols (or (julia-workbench-project-symbols project)
                                   (expand-file-name
                                    (concat "symbols/LanguageServer-6.0.1/julia-" minor) cache))
                      :environment
                      (or (julia-workbench-project-environment project)
                          (expand-file-name
                           (concat "standalone/julia-" minor "/"
                                   (secure-hash 'sha256 (project-root project))) cache)))))
          (when (version< version "1.11")
            (user-error "LanguageServer 6.0.1 requires Julia 1.11+; found %s" version))
          (puthash key runtime julia-workbench--runtime-cache)
          runtime))))

(defun julia-workbench--contact (interactive project)
  "Return Eglot contact for PROJECT, respecting INTERACTIVE custom contacts."
  (if-let* ((custom (julia-workbench-project-command project)))
      (if (functionp custom) (funcall custom interactive project) custom)
    (let* ((runtime (julia-workbench--runtime project))
           (tooling (plist-get runtime :tooling))
           (environment (plist-get runtime :environment)))
      (unless (and (julia-workbench--project-file tooling)
                   (or (file-readable-p (expand-file-name "Manifest.toml" tooling))
                       (file-readable-p (expand-file-name "JuliaManifest.toml" tooling))))
        (user-error "Server tooling missing at %s; run M-x julia-workbench-setup-server" tooling))
      (if (julia-workbench-project-environment project)
          (unless (julia-workbench--project-file environment)
            (user-error "No JuliaProject.toml or Project.toml in %s" environment))
        (make-directory environment t)
        (unless (julia-workbench--project-file environment)
          (with-temp-file (expand-file-name "Project.toml" environment)
            (insert "[deps]\n"))))
      (list (plist-get runtime :executable) "--startup-file=no"
            (concat "--project=" tooling)
            (julia-workbench--asset "launch-server.jl") environment
            (plist-get runtime :symbols)))))

(defun julia-workbench--mode-key-p (key)
  "Return non-nil when Eglot mode KEY includes the Workbench mode."
  (or (eq key 'julia-workbench-mode)
      (and (consp key)
           (or (memq 'julia-workbench-mode key)
               (cl-some #'julia-workbench--mode-key-p key)))))

(defun julia-workbench-register-eglot ()
  "Register Julia Eglot support without replacing user server mappings."
  ;; Keep Julia's ID when users supply a simple (MODE . COMMAND) mapping.
  ;; Explicit :language-id metadata in their mapping still takes precedence.
  (put 'julia-workbench-mode 'eglot-language-id "julia")
  (unless (cl-some (lambda (entry) (julia-workbench--mode-key-p (car entry)))
                   eglot-server-programs)
    (add-to-list 'eglot-server-programs
                 '((julia-workbench-mode :language-id "julia")
                   . julia-workbench--contact)))
  (add-hook 'project-find-functions #'julia-workbench--find-project))

(defun julia-workbench--shutdown-server (server)
  "Stop SERVER, retaining logs even if graceful shutdown fails.
Eglot guarantees termination in its cleanup path.  When it signals an error
after terminating the process, report that error and allow reconnect to proceed."
  (condition-case err
      (eglot-shutdown server nil julia-workbench-shutdown-timeout t)
    (error
     (if (jsonrpc-running-p server)
         (signal (car err) (cdr err))
       (message "Julia server stopped after shutdown error: %s; logs retained"
                (error-message-string err))))))

;;;###autoload
(defun julia-workbench-connect ()
  "Connect this Julia buffer through Eglot using its current settings.
Missing tooling produces setup instructions; no packages are installed."
  (interactive)
  (unless (derived-mode-p 'julia-workbench-mode)
    (user-error "Use this command in a Julia Workbench buffer"))
  (if-let* ((server (eglot-current-server)))
      (if (jsonrpc-running-p server)
          (message "Julia server already connected; use julia-workbench-reconnect to change settings")
        (julia-workbench-reconnect))
    (call-interactively #'eglot)))

;;;###autoload
(defun julia-workbench-reconnect ()
  "Reconnect deliberately after changing environment or executable settings.
Invalidate runtime probes and notify cache consumers.  Shut down the shared
old connection; other buffers can reconnect using their own current settings.
Unlike `eglot-reconnect', resolve the new contact rather than reuse old args."
  (interactive)
  (let ((project (julia-workbench-resolve-project)))
    (when-let* ((server (eglot-current-server)))
      (julia-workbench--shutdown-server server))
    (clrhash julia-workbench--runtime-cache)
    (run-hook-with-args 'julia-workbench-environment-change-hook project)
    (julia-workbench-connect)))

;;;###autoload
(defun julia-workbench-shutdown ()
  "Shut down this buffer's shared Eglot server, retaining diagnostic logs."
  (interactive)
  (if-let* ((server (eglot-current-server)))
      (julia-workbench--shutdown-server server)
    (user-error "No Julia server for this buffer")))

;;;###autoload
(defun julia-workbench-setup-server ()
  "Asynchronously install or restore the pinned isolated server environment.
Display installation logs.  Repeating this command restores the checked-in
dependency lock rather than upgrading beyond the supported server version.
Cancel with `kill-process' in the log buffer, then rerun this command."
  (interactive)
  (let* ((project (julia-workbench-resolve-project))
         (runtime (julia-workbench--runtime project))
         (buffer (get-buffer-create
                  (format "*Julia setup %s*" (plist-get runtime :tooling))))
         (process-environment (julia-workbench--process-environment project))
         (default-directory (project-root project)))
    (when (process-live-p (get-buffer-process buffer))
      (user-error "Setup already running; see %s" (buffer-name buffer)))
    (setenv "JULIA_WORKBENCH_SERVER_PROJECT" (plist-get runtime :tooling))
    (setenv "JULIA_WORKBENCH_SYMBOL_CACHE" (plist-get runtime :symbols))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)) (erase-buffer))
      (special-mode))
    (prog1
        (make-process
         :name "julia-workbench-setup" :buffer buffer :noquery t
         :connection-type 'pipe :coding 'utf-8-unix :stderr buffer
         :command (list (plist-get runtime :executable) "--startup-file=no"
                        (julia-workbench--asset "setup-server.jl"))
         :sentinel
         (lambda (process event)
           (when (memq (process-status process) '(exit signal))
             (when (buffer-live-p (process-buffer process))
               (with-current-buffer (process-buffer process)
                 (let ((inhibit-read-only t))
                   (goto-char (point-max))
                   (insert (format "\nSetup %s (exit %s).\n"
                                   (string-trim event) (process-exit-status process))))))
             (message "Julia setup %s; see %s" (string-trim event) (buffer-name buffer)))))
      (display-buffer buffer))))

;;;###autoload
(defun julia-workbench-doctor ()
  "Show resolved settings, missing tools and Eglot logs without installation."
  (interactive)
  (let* ((project (julia-workbench-resolve-project))
         (server (eglot-current-server))
         (report
          (concat
           (format "Emacs: %s\nWorkspace root: %s\nEnvironment: %s\nExecutable: %s\nCustom contact: %S\n"
                   emacs-version (project-root project)
                   (or (julia-workbench-project-environment project) "standalone (empty)")
                   (julia-workbench-project-executable project)
                   (julia-workbench-project-command project))
           (condition-case err
               (let ((runtime (julia-workbench--runtime project)))
                 (format "Julia: %s\nTooling: %s\nTooling installed: %s\nSymbol cache: %s\nAnalyzed environment: %s\n"
                         (plist-get runtime :version) (plist-get runtime :tooling)
                         (if (julia-workbench--project-file (plist-get runtime :tooling))
                             "project present (connection verifies dependencies)" "missing; run julia-workbench-setup-server")
                         (plist-get runtime :symbols) (plist-get runtime :environment)))
             (error (format "Problem: %s\n" (error-message-string err))))
           (format "Server: %s\n" (cond ((and server (jsonrpc-running-p server)) "running")
                                         (server "stopped; run julia-workbench-reconnect")
                                         (t "disconnected")))
           (format "Eglot mapping: %S\nShell for project file listing: %s\n"
                   (julia-workbench-project-mapping project) shell-file-name)
           (when (fboundp 'trusted-content-p)
             (format "Flymake content trust: %s\n"
                     (if (trusted-content-p) "trusted"
                       "untrusted; check trusted-content if Flymake disables its backend")))
           (when server
             (format "Events: %s\nStderr: %s\n"
                     (buffer-name (jsonrpc-events-buffer server))
                     (when-let* ((buffer (jsonrpc-stderr-buffer server))) (buffer-name buffer))))
           "\nUse eglot-events-buffer / eglot-stderr-buffer for protocol and server logs.\nReconnect after settings or project/manifest changes.\n")))
    (with-help-window "*Julia Workbench doctor*" (princ report))))

(julia-workbench-register-eglot)

(provide 'julia-workbench-eglot)
;;; julia-workbench-eglot.el ends here
