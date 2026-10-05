;;; package.el --- Build the Julia Workbench release archive -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Run with Emacs -Q --batch -l scripts/package.el.  Only source and runtime
;; assets enter the archive; GNU tar normalizes order, timestamps and ownership.

;;; Code:

(require 'package)

(let* ((root (file-name-directory
              (directory-file-name (file-name-directory load-file-name))))
       (descriptor (with-temp-buffer
                     (insert-file-contents (expand-file-name "julia-workbench.el" root))
                     (package-buffer-info)))
       (version (package-version-join (package-desc-version descriptor)))
       (name (format "julia-workbench-%s" version))
       (output (file-name-as-directory
                (expand-file-name (or (getenv "RELEASE_DIRECTORY") "dist") root)))
       (archive (expand-file-name (concat name ".tar") output))
       (temporary (make-temp-file "julia-workbench-package-" t))
       (directory (expand-file-name name temporary)))
  (unwind-protect
      (progn
        (make-directory directory)
        (dolist (file (append (directory-files root nil "\\`julia-workbench.*\\.el\\'")
                             '("LICENSE" "README.md" "COMPATIBILITY.md"
                               "IMPLEMENTATION_PLAN.md")))
          (copy-file (expand-file-name file root) (expand-file-name file directory)))
        (copy-directory (expand-file-name "julia" root)
                        (expand-file-name "julia" directory))
        (copy-directory (expand-file-name "examples" root)
                        (expand-file-name "examples" directory))
        (with-temp-file (expand-file-name "julia-workbench-pkg.el" directory)
          (insert ";;; Generated package metadata -*- lexical-binding: t; no-byte-compile: t; -*-\n")
          (prin1 `(define-package "julia-workbench" ,version
                    ,(package-desc-summary descriptor)
                    ',(mapcar (lambda (requirement)
                                (list (car requirement)
                                      (package-version-join (cadr requirement))))
                              (package-desc-reqs descriptor)))
                 (current-buffer))
          (insert "\n"))
        (make-directory output t)
        (unless (zerop (call-process "tar" nil t nil
                                    "--sort=name" "--mtime=@0" "--owner=0" "--group=0"
                                    "--numeric-owner" "-cf" archive "-C" temporary name))
          (error "Release archive creation failed"))
        (message "Release archive: %s" archive))
    (delete-directory temporary t)))

;;; package.el ends here
