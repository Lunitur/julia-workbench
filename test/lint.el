;;; lint.el --- Built-in source checks with failing diagnostics -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Run from a batch Emacs with source paths after this file's -l argument.
;; Checkdoc normally reports warnings without failing a batch process.

;;; Code:

(require 'checkdoc)

(let ((checkdoc-spellcheck-documentation-flag nil)
      (warnings 0))
  (dolist (file command-line-args-left)
    (with-current-buffer (find-file-noselect file)
      (check-parens))
    (let* ((original checkdoc-create-error-function)
           (checkdoc-create-error-function
            (lambda (&rest arguments)
              (setq warnings (1+ warnings))
              (apply original arguments))))
      (checkdoc-file file)))
  (setq command-line-args-left nil)
  (when (> warnings 0)
    (error "Checkdoc reported %d documentation warnings" warnings)))

;;; lint.el ends here
