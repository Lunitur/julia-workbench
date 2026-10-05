;;; package-tests.el --- Installed archive validation -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Use a fresh Emacs -Q without the checkout on load-path.  Install through
;; package.el, then exercise generated autoloads and packaged runtime helpers.

;;; Code:

(require 'ert)
(require 'package)
(require 'cl-lib)

(defvar julia-workbench--asset-directory)

(defconst workbench-package-root
  (file-name-directory
   (directory-file-name (file-name-directory (or load-file-name buffer-file-name)))))

(ert-deftest workbench-package-install-autoloads-and-assets ()
  "Install the archive offline and edit using its autoloads and runtime assets."
  (let* ((temporary (make-temp-file "workbench-installed-" t))
         (package-user-dir (expand-file-name "packages" temporary))
         (package-directory-list nil)
         (package-archives nil)
         (package-native-compile nil)
         (package-alist nil)
         (package-activated-list nil)
         (load-path (copy-sequence load-path))
         (archive (or (getenv "JULIA_WORKBENCH_PACKAGE_ARCHIVE")
                      (car (directory-files
                            (expand-file-name "dist" workbench-package-root) t "\\.tar\\'"))))
         (processes (process-list)))
    (unwind-protect
        (progn
          (should-not (featurep 'julia-workbench))
          (should archive)
          ;; Compilation loads dependencies in the installer.  Use a separate
          ;; process so this test checks a fresh user's generated autoloads.
          (with-temp-buffer
            (should
             (zerop
              (call-process
               (expand-file-name invocation-name invocation-directory) nil t nil
               "-Q" "--batch" "--eval"
               (prin1-to-string
                `(progn
                   (require 'package)
                   (setq package-user-dir ,package-user-dir package-archives nil
                         package-directory-list nil package-native-compile nil
                         byte-compile-error-on-warn t)
                   (package-install-file ,archive))))))
            (should-not (string-match-p "\\(?:Error\\|Warning\\):" (buffer-string))))
          (package-initialize)
          (should (autoloadp (symbol-function 'julia-workbench-mode)))
          (should (autoloadp (symbol-function 'julia-workbench-connect)))
          (should (autoloadp (symbol-function 'julia-workbench-repl)))
          (let* ((descriptor (cadr (assq 'julia-workbench package-alist)))
                 (directory (package-desc-dir descriptor)))
            (should (file-in-directory-p directory package-user-dir))
            (dolist (relative (append '("LICENSE" "examples/doom.el" "examples/vanilla.el")
                                      (mapcar (lambda (path)
                                                (file-relative-name path workbench-package-root))
                                              (directory-files-recursively
                                               (expand-file-name "julia" workbench-package-root)
                                               "\\.\\(?:jl\\|toml\\)\\'"))))
              (let ((installed (expand-file-name relative directory))
                    (source (expand-file-name relative workbench-package-root)))
                (should (file-regular-p installed))
                (should (equal (with-temp-buffer
                                 (insert-file-contents-literally installed) (buffer-string))
                               (with-temp-buffer
                                 (insert-file-contents-literally source) (buffer-string))))))
            (cl-letf (((symbol-function 'make-process)
                       (lambda (&rest _) (ert-fail "Opening source launched a process"))))
              (let ((exec-path nil))
                (with-temp-buffer
                  (setq buffer-file-name (expand-file-name "example.jl" temporary))
                  (insert "α = 1; emoji = \"🚀\"\n")
                  (set-auto-mode)
                  (should (eq major-mode 'julia-workbench-mode)))
                (with-temp-buffer
                  (insert "#!/usr/bin/env julia\nx = 1\n")
                  (set-auto-mode)
                  (should (eq major-mode 'julia-workbench-mode)))))
            (should (file-in-directory-p julia-workbench--asset-directory package-user-dir))
            (dolist (feature '(julia-workbench-completion julia-workbench-eglot
                              julia-workbench-doc julia-workbench-plot julia-workbench-repl))
              (require feature)
              (should (file-in-directory-p (locate-library (symbol-name feature)) directory)))
            (let ((julia (or (getenv "JULIA") (executable-find "julia"))))
              (should julia)
              (with-temp-buffer
                (should (zerop (call-process
                                julia nil t nil "--startup-file=no"
                                (expand-file-name "julia/documentation.jl" directory)
                                "lookup" "Base.sin")))
                (should (string-match-p "sine" (buffer-string)))))
            (should-not (cl-set-difference (process-list) processes))))
      (delete-directory temporary t))))

;;; package-tests.el ends here
