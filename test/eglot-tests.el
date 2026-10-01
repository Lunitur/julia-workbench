;;; eglot-tests.el --- Julia environment regression tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Project resolution, custom settings, failure guidance and async lifecycle.
;; No Julia installation or running language server is needed for this suite.

;;; Code:

(require 'ert)
(require 'julia-workbench-eglot)

(defmacro workbench-eglot-test-with-project (&rest body)
  "Run BODY in an isolated project directory and Julia buffer."
  (declare (indent 0) (debug t))
  `(let* ((directory (make-temp-file "workbench-environment-" t))
          (julia-workbench-cache-directory (expand-file-name "cache" directory))
          (julia-workbench--runtime-cache (make-hash-table :test #'equal))
          (process-environment (copy-sequence process-environment)))
     (setenv "JULIA_WORKBENCH_SERVER_PROJECT" nil)
     (setenv "JULIA_WORKBENCH_SYMBOL_CACHE" nil)
     (unwind-protect
         (with-temp-buffer
           (setq default-directory (file-name-as-directory directory))
           (let ((julia-workbench-use-tree-sitter nil)) (julia-workbench-mode))
           ,@body)
       (delete-directory directory t))))

(defun workbench-eglot-test-file (file &optional text)
  "Create FILE with TEXT, making parent directories as needed."
  (make-directory (file-name-directory file) t)
  (with-temp-file file (insert (or text "[deps]\n"))))

(ert-deftest workbench-eglot-nearest-project-and-precedence ()
  "Nearest environment wins, with JuliaProject.toml taking precedence."
  (workbench-eglot-test-with-project
    (workbench-eglot-test-file (expand-file-name "Project.toml" directory))
    (workbench-eglot-test-file (expand-file-name "nested/Project.toml" directory))
    (workbench-eglot-test-file (expand-file-name "nested/JuliaProject.toml" directory))
    (make-directory (expand-file-name "nested/src" directory))
    (let* ((default-directory (expand-file-name "nested/src/" directory))
           (resolved (julia-workbench-resolve-project)))
      (should (equal (julia-workbench-project-environment resolved)
                     (expand-file-name "nested/" directory)))
      (should (equal (file-name-nondirectory
                      (julia-workbench--project-file
                       (julia-workbench-project-environment resolved)))
                     "JuliaProject.toml")))))

(ert-deftest workbench-eglot-workspace-distinct-from-environment ()
  "Keep the VC workspace while separating nested environments in Eglot."
  (workbench-eglot-test-with-project
    (make-directory (expand-file-name ".git" directory))
    (workbench-eglot-test-file (expand-file-name "Project.toml" directory))
    (workbench-eglot-test-file (expand-file-name "test/Project.toml" directory))
    (let* ((parent (julia-workbench-resolve-project))
           (nested (julia-workbench-resolve-project
                    (expand-file-name "test" directory))))
      (should (equal (project-root parent) (project-root nested)))
      (should-not (equal parent nested))
      (let ((eglot-lsp-context t))
        (should (julia-workbench-project-p (project-current))))
      (let ((eglot-lsp-context nil))
        (should-not (julia-workbench-project-p (project-current)))))))

(ert-deftest workbench-eglot-explicit-relative-environment ()
  "Resolve explicit files and directories from the workspace root."
  (workbench-eglot-test-with-project
    (workbench-eglot-test-file (expand-file-name "Project.toml" directory))
    (workbench-eglot-test-file (expand-file-name "test/JuliaProject.toml" directory))
    (make-directory (expand-file-name "src" directory))
    (setq default-directory (expand-file-name "src/" directory))
    (setq-local julia-workbench-environment "test/JuliaProject.toml")
    (should (equal (julia-workbench-project-environment
                    (julia-workbench-resolve-project))
                   (expand-file-name "test/" directory)))))

(ert-deftest workbench-eglot-connection-identity ()
  "Siblings share identity; changed environments, executables or contacts do not."
  (workbench-eglot-test-with-project
    (workbench-eglot-test-file (expand-file-name "Project.toml" directory))
    (make-directory (expand-file-name "src" directory))
    (let ((original (julia-workbench-resolve-project)))
      (should (equal original (julia-workbench-resolve-project
                               (expand-file-name "src" directory))))
      (setq-local julia-workbench-julia-command "another-julia")
      (should-not (equal original (julia-workbench-resolve-project)))
      (setq-local julia-workbench-julia-command "julia"
                  julia-workbench-server-command '("custom-server"))
      (should-not (equal original (julia-workbench-resolve-project)))
      (setq-local julia-workbench-server-command nil)
      (let ((eglot-server-programs '((julia-workbench-mode . ("local-server")))))
        (should-not (equal original (julia-workbench-resolve-project)))))))

(ert-deftest workbench-eglot-standalone-no-side-effects ()
  "Resolving standalone files never starts Julia or creates an environment."
  (workbench-eglot-test-with-project
    (cl-letf (((symbol-function 'call-process) (lambda (&rest _) (ert-fail "Probe")))
              ((symbol-function 'make-process) (lambda (&rest _) (ert-fail "Process"))))
      (let ((resolved (julia-workbench-resolve-project)))
        (should-not (julia-workbench-project-environment resolved))
        (should (equal (project-root resolved) (file-name-as-directory directory)))
        (should-not (file-exists-p julia-workbench-cache-directory))))))

(ert-deftest workbench-eglot-custom-command-needs-no-julia ()
  "User contacts bypass local Julia and tooling checks."
  (workbench-eglot-test-with-project
    (setq-local julia-workbench-julia-command "missing-julia"
                julia-workbench-server-command '("custom" "--stdio"))
    (should (equal (julia-workbench--contact nil (julia-workbench-resolve-project))
                   '("custom" "--stdio")))
    (setq-local julia-workbench-server-command
                (lambda (interactive project)
                  (list "custom" (if interactive "yes" "no") (project-root project))))
    (should (equal (cadr (julia-workbench--contact
                         t (julia-workbench-resolve-project))) "yes"))))

(ert-deftest workbench-eglot-registration-preserves-user-mappings ()
  "Do not replace existing single or grouped user contacts."
  (dolist (key '(julia-workbench-mode
                 (julia-workbench-mode :language-id "julia")
                 ((julia-workbench-mode :language-id "julia") other-mode)))
    (let* ((entry (cons key '("user-server")))
           (eglot-server-programs (list entry '(other-mode . ("other")))))
      (julia-workbench-register-eglot)
      (should (equal (car eglot-server-programs) entry))
      (should (= (length eglot-server-programs) 2))
      (should (equal (cdar (car (eglot--lookup-mode 'julia-workbench-mode))) "julia"))))
  (let ((eglot-server-programs '((other-mode . ("other")))))
    (julia-workbench-register-eglot)
    (julia-workbench-register-eglot)
    (should (= (length eglot-server-programs) 2))
    ;; This adapter is intentionally the only internal Eglot inspection here.
    (should (equal (caar (car (eglot--lookup-mode 'julia-workbench-mode)))
                   'julia-workbench-mode))
    (should (equal (cdar (car (eglot--lookup-mode 'julia-workbench-mode))) "julia"))))

(ert-deftest workbench-eglot-missing-tools-guidance ()
  "Missing executables and environments fail with actionable errors."
  (workbench-eglot-test-with-project
    (setq-local julia-workbench-julia-command "workbench-nonexistent-julia")
    (should-error (julia-workbench--contact nil (julia-workbench-resolve-project))
                  :type 'user-error)
    (let ((runtime (list :executable "julia" :tooling (expand-file-name "missing" directory)
                         :environment directory :symbols directory)))
      (cl-letf (((symbol-function 'julia-workbench--runtime) (lambda (_) runtime)))
        (should-error (julia-workbench--contact nil (julia-workbench-resolve-project))
                      :type 'user-error)))))

(ert-deftest workbench-eglot-contact-arguments-and-standalone ()
  "Pass exact environment/cache arguments; create only explicit standalone dirs."
  (workbench-eglot-test-with-project
    (let* ((tooling (expand-file-name "tooling" directory))
           (empty (expand-file-name "standalone" directory))
           (runtime (list :executable "/some path/julia" :tooling tooling
                          :environment empty :symbols "/some path/symbols")))
      (workbench-eglot-test-file (expand-file-name "Project.toml" tooling))
      (workbench-eglot-test-file (expand-file-name "Manifest.toml" tooling))
      (cl-letf (((symbol-function 'julia-workbench--runtime) (lambda (_) runtime)))
        (let ((contact (julia-workbench--contact nil (julia-workbench-resolve-project))))
          (should (equal (car contact) "/some path/julia"))
          (should (equal (nth 4 contact) empty))
          (should (equal (nth 5 contact) "/some path/symbols"))
          (should (file-exists-p (expand-file-name "Project.toml" empty))))
        (setq-local julia-workbench-environment "missing")
        (setq runtime (plist-put runtime :environment
                                 (expand-file-name "missing" directory)))
        (should-error (julia-workbench--contact nil (julia-workbench-resolve-project))
                      :type 'user-error)))))

(ert-deftest workbench-eglot-reconnect-resolves-new-settings ()
  "Reconnect shuts down old connections and invalidates before connecting."
  (workbench-eglot-test-with-project
    (let ((steps nil)
          (julia-workbench-environment-change-hook
           (list (lambda (project)
                   (should (equal (julia-workbench-project-executable project) "new-julia"))))))
      (setq-local julia-workbench-julia-command "new-julia")
      (puthash 'stale t julia-workbench--runtime-cache)
      (cl-letf (((symbol-function 'eglot-current-server) (lambda () 'old))
                ((symbol-function 'eglot-shutdown)
                 (lambda (server &rest _) (should (eq server 'old)) (push 'shutdown steps)))
                ((symbol-function 'julia-workbench-connect)
                 (lambda ()
                   (should (= (hash-table-count julia-workbench--runtime-cache) 0))
                   (push 'connect steps))))
        (julia-workbench-reconnect)
        (should (equal (reverse steps) '(shutdown connect)))))))

(ert-deftest workbench-eglot-runtime-version-and-overrides ()
  "Versioned paths use the selected executable, cache root and explicit settings."
  (workbench-eglot-test-with-project
    (let ((probes 0))
      (cl-letf (((symbol-function 'julia-workbench--executable) (lambda (_) "/bin/sh"))
                ((symbol-function 'call-process)
                 (lambda (&rest _) (cl-incf probes) (insert "julia version 1.12.3\n") 0)))
        (let* ((project (julia-workbench-resolve-project))
               (runtime (julia-workbench--runtime project)))
          (should (equal (plist-get runtime :version) "1.12.3"))
          (should (string-suffix-p "LanguageServer-6.0.1/julia-1.12"
                                  (plist-get runtime :tooling)))
          (should (string-prefix-p julia-workbench-cache-directory
                                   (plist-get runtime :environment)))
          (should (equal runtime (julia-workbench--runtime project)))
          (should (= probes 1)))
        (setenv "JULIA_WORKBENCH_SERVER_PROJECT" (expand-file-name "override" directory))
        (setenv "JULIA_WORKBENCH_SYMBOL_CACHE" (expand-file-name "symbols" directory))
        (let ((runtime (julia-workbench--runtime (julia-workbench-resolve-project))))
          (should (equal (plist-get runtime :tooling) (expand-file-name "override/" directory)))
          (should (equal (plist-get runtime :symbols) (expand-file-name "symbols/" directory))))))))

(ert-deftest workbench-eglot-old-julia-and-remote-guidance ()
  "Bundled tooling rejects old Julia and remote launch with actionable guidance."
  (workbench-eglot-test-with-project
    (cl-letf (((symbol-function 'julia-workbench--executable) (lambda (_) "/bin/sh"))
              ((symbol-function 'call-process)
               (lambda (&rest _) (insert "julia version 1.10.9\n") 0)))
      (should-error (julia-workbench--runtime (julia-workbench-resolve-project))
                    :type 'user-error))
    (should-error (julia-workbench--executable
                   (julia-workbench--make-project :root "/ssh:host:/tmp/" :executable "julia"))
                  :type 'user-error)))

(ert-deftest workbench-eglot-shutdown-timeout-recovery ()
  "A failed graceful shutdown permits reconnect only after the process stops."
  (cl-letf (((symbol-function 'eglot-shutdown)
             (lambda (&rest _) (error "Graceful shutdown timed out")))
            ((symbol-function 'jsonrpc-running-p) (lambda (_) nil)))
    (should (julia-workbench--shutdown-server 'stopped)))
  (cl-letf (((symbol-function 'eglot-shutdown)
             (lambda (&rest _) (error "Unexpected failure")))
            ((symbol-function 'jsonrpc-running-p) (lambda (_) t)))
    (should-error (julia-workbench--shutdown-server 'running))))

(ert-deftest workbench-eglot-doctor-missing-julia-no-installation ()
  "Doctor reports missing Julia without creating caches or starting a server."
  (workbench-eglot-test-with-project
    (setq-local julia-workbench-julia-command "workbench-nonexistent-julia")
    (cl-letf (((symbol-function 'make-process) (lambda (&rest _) (ert-fail "Installation"))))
      (unwind-protect
          (progn
            (julia-workbench-doctor)
            (with-current-buffer "*Julia Workbench doctor*"
              (should (string-match-p "Julia executable.*missing" (buffer-string)))
              (should (string-match-p "Server: disconnected" (buffer-string))))
            (should-not (file-exists-p julia-workbench-cache-directory)))
        (when-let* ((buffer (get-buffer "*Julia Workbench doctor*"))) (kill-buffer buffer))))))

(ert-deftest workbench-eglot-async-setup-success-and-failure ()
  "Setup returns a live process, captures logs and reports nonzero exits."
  (workbench-eglot-test-with-project
    (dolist (exit-code '(0 7))
      (let* ((script (expand-file-name "fake-julia" directory))
             (tooling (expand-file-name "tooling" directory))
             (runtime (list :executable script :version "1.13.1"
                            :tooling tooling :symbols directory))
             (process nil) (buffer nil))
        (workbench-eglot-test-file
         script (format "#!/bin/sh\nprintf 'installation stdout\\n'\nprintf 'installation stderr\\n' >&2\nsleep 0.1\nexit %d\n" exit-code))
        (set-file-modes script #o755)
        (unwind-protect
            (cl-letf (((symbol-function 'julia-workbench--runtime) (lambda (_) runtime)))
              (setq process (julia-workbench-setup-server)
                    buffer (process-buffer process))
              (should (process-live-p process))
              (should-error (julia-workbench-setup-server) :type 'user-error)
              (while (process-live-p process) (accept-process-output nil 0.05))
              (accept-process-output nil 0.05)
              (should (= (process-exit-status process) exit-code))
              (with-current-buffer buffer
                (should (string-match-p "installation stdout" (buffer-string)))
                (should (string-match-p "installation stderr" (buffer-string)))
                (should (string-match-p (format "exit %d" exit-code) (buffer-string)))))
          (when (process-live-p process) (delete-process process))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(provide 'eglot-tests)
;;; eglot-tests.el ends here
