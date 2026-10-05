;;; doom.el --- Julia Workbench Doom integration -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Copy this block into Doom's config.el after disabling :lang julia and
;; declaring the package with its Julia helper assets in packages.el.
;; Connection, installation and runtime evaluation remain explicit commands.
;; Doom's existing Eglot/Flycheck bridge and LSP formatter handle diagnostics
;; and formatting; no additional checker or formatter is installed here.

;;; Code:

(use-package! julia-workbench
  ;; ESS also claims Julia files when :lang julia is disabled.  Register its
  ;; case-insensitive extension here, after module config, to retain priority.
  :mode ("\\.[jJ][lL]\\'" . julia-workbench-mode)
  :interpreter ("julia" . julia-workbench-mode)
  :config
  (require 'julia-workbench-repl)
  (when (modulep! :editor evil)
    (evil-set-initial-state 'julia-workbench-plot-mode 'normal)
    ;; Images need viewport scrolling rather than buffer-line motions.
    (evil-define-key 'normal julia-workbench-plot-mode-map
      "h" #'image-backward-hscroll
      "j" #'image-next-line
      "k" #'image-previous-line
      "l" #'image-forward-hscroll
      (kbd "C-d") #'julia-workbench-plot-scroll-down
      (kbd "C-u") #'julia-workbench-plot-scroll-up
      (kbd "C-f") #'image-scroll-up
      (kbd "C-b") #'image-scroll-down
      "n" #'julia-workbench-plot-next
      "p" #'julia-workbench-plot-previous
      "+" #'image-increase-size
      "=" #'image-increase-size
      "-" #'image-decrease-size
      "f" #'julia-workbench-plot-fit
      "s" #'julia-workbench-plot-save
      "q" #'quit-window)
    ;; Keep pane controls ahead of extensions such as evil-snipe.
    (evil-make-intercept-map julia-workbench-plot-mode-map 'normal t))

  (defun +julia-workbench-open-repl ()
    "Open the project REPL and return its buffer for Doom's eval commands."
    (interactive)
    (julia-workbench-repl)
    (current-buffer))

  (defun +julia-workbench-lookup-h ()
    "Keep persistent Julia documentation first after Eglot connects."
    (when (derived-mode-p 'julia-workbench-mode)
      ;; `add-hook' leaves an existing entry in place, so move it explicitly.
      (remove-hook '+lookup-documentation-functions
                   #'julia-workbench-documentation-at-point t)
      (add-hook '+lookup-documentation-functions
                #'julia-workbench-documentation-at-point nil t)))

  (when (modulep! :tools lookup)
    (set-lookup-handlers! 'julia-workbench-mode
      :documentation '(julia-workbench-documentation-at-point :async t))
    ;; Eglot adds its own minor-mode handler after the major-mode hook.
    (add-hook 'eglot-managed-mode-hook #'+julia-workbench-lookup-h t))

  (when (modulep! :tools eval)
    (set-repl-handler! 'julia-workbench-mode #'+julia-workbench-open-repl
      :persist t
      :send-region #'julia-workbench-send-region
      :send-buffer #'julia-workbench-send-buffer)
    (set-eval-handler! 'julia-workbench-mode #'julia-workbench-send-region))

  (set-popup-rule! "^\\*Julia \\(?:Runtime \\)?Documentation\\*$"
    :size 0.35 :select t :quit t :ttl nil)
  (set-popup-rule! "^\\*Julia REPL "
    :size 0.35 :select t :quit nil :ttl nil)
  (set-popup-rule! "^\\*Julia Plots "
    :side 'right :size 0.45 :select nil :quit t :ttl nil)

  (map! :localleader
        :map julia-workbench-mode-map
        :desc "Start REPL / flip to REPL" "'" #'julia-workbench-repl
        :desc "Activate project"          "p" #'julia-workbench-repl-activate-project
        :desc "Doc lookup at point"        "d" #'julia-workbench-documentation-at-point
        :desc "Named documentation"        "D" #'julia-workbench-documentation
        :desc "Search documentation"       "s" #'julia-workbench-documentation-search
        :desc "Select documentation scope" "P" #'julia-workbench-documentation-select-packages
        :desc "Copy last eval result"      "y" #'julia-workbench-copy-last-eval-result
        :desc "Show plot history"          "v" #'julia-workbench-show-plots
        :desc "Send line"                  "l" #'julia-workbench-send-line
        :desc "Send region"                "r" #'julia-workbench-send-region
        :desc "Send DWIM"                  "e" #'julia-workbench-send-dwim
        :desc "Send top-level block"       "b" #'julia-workbench-send-top-level-form
        :desc "Send top-level block"       "x" #'julia-workbench-send-top-level-form
        :desc "Send buffer file"           "f" #'julia-workbench-send-buffer-file
        :desc "Send buffer"                "F" #'julia-workbench-send-buffer
        :desc "Runtime completion"         "u" #'julia-workbench-repl-complete
        :desc "Runtime documentation"      "R" #'julia-workbench-repl-documentation
        :desc "Connect language server"    "c" #'julia-workbench-connect
        :desc "Reconnect language server"  "C" #'julia-workbench-reconnect
        :desc "Shutdown language server"   "k" #'julia-workbench-shutdown
        :desc "Julia doctor"               "h" #'julia-workbench-doctor)
  (map! :localleader
        :map julia-workbench-repl-mode-map
        :desc "Back to source"  "'" #'julia-workbench-repl
        :desc "Interrupt"       "i" #'julia-workbench-repl-interrupt
        :desc "Restart"         "r" #'julia-workbench-repl-restart
        :desc "Activate project" "p" #'julia-workbench-repl-activate-project
        :desc "Documentation"   "d" #'julia-workbench-repl-documentation
        :desc "Show plot history" "v" #'julia-workbench-show-plots
        :desc "Copy last result" "y" #'julia-workbench-copy-last-eval-result))

;;; doom.el ends here
