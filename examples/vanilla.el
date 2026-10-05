;;; vanilla.el --- Julia Workbench in plain Emacs -*- lexical-binding: t; no-byte-compile: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Install the archive with M-x package-install-file, then copy this into init.el.
;; For checkout development, add its directory to load-path before this block.
;; Opening Julia files needs neither Julia nor a server.  Existing Corfu users
;; get buffer-local completion popups through the package's ordinary CAPFs.

;;; Code:

(require 'julia-workbench)

;; Optional: use an existing grammar (replace this path with your directory).
;; (add-to-list 'treesit-extra-load-path "/path/to/tree-sitter")

;; M-x julia-workbench-setup-server explicitly installs the bundled server lock.
;; M-x julia-workbench-connect starts Eglot for the selected project.
;; M-x julia-workbench-setup-unicode exports this Julia runtime's Unicode table.
;; M-x julia-workbench-repl starts the project's comint session.
;; C-c C-c evaluates a region or top-level form; C-c C-d opens documentation.

;;; vanilla.el ends here
