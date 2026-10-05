;;; plot-ui-tests.el --- Optional graphical plot fixtures -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Run in a disposable graphical Emacs -Q.  An optional existing project with
;; Plots.jl exercises GR-generated SVG/PNG; these tests never install packages.

;;; Code:

(require 'repl-integration-tests)

(ert-deftest workbench-plot-ui-native-history-zoom-and-focus ()
  "Render a real SVG image, preserve source focus, magnify, fit and navigate."
  (should (display-images-p))
  (workbench-repl-live-fixture
    (switch-to-buffer source)
    (let* ((julia-workbench-plot-formats '(svg))
           (buffer (julia-workbench--repl-buffer t))
           (source-window (selected-window)))
      (workbench-repl-live-eval
       buffer (concat "struct GUIFigure end; "
                      "Base.show(io::IO, ::MIME\"image/svg+xml\", ::GUIFigure) = "
                      "print(io, \"<svg xmlns=\\\"http://www.w3.org/2000/svg\\\" width=\\\"1200\\\" height=\\\"600\\\"><path d=\\\"M0 600 L1200 0\\\" stroke=\\\"blue\\\"/></svg>\"); "
                      "GUIFigure()"))
      (should (eq (selected-window) source-window))
      (should (eq (window-buffer source-window) source))
      (let* ((pane (with-current-buffer buffer julia-workbench--plot-buffer))
             (window (get-buffer-window pane)))
        (should (window-live-p window))
        (with-selected-window window
          (goto-char (point-min))
          (let* ((image (get-text-property (point) 'display))
                 (width (car (image-size image t))))
            (should (eq (car image) 'image))
            (should (<= width (window-body-width window t)))
            (image-increase-size)
            (accept-process-output nil 0.3)
            (should (> (car (image-size (get-text-property (point) 'display) t)) width))
            (julia-workbench-plot-fit)
            (should (= (car (image-size (get-text-property (point) 'display) t)) width))))
        (workbench-repl-live-eval buffer "GUIFigure()")
        (with-selected-window window
          (julia-workbench-plot-previous)
          (should (string-match-p "Plot 1/2" header-line-format))
          (julia-workbench-plot-next)
          (should (string-match-p "Plot 2/2" header-line-format)))))))

(ert-deftest workbench-plot-ui-plots-jl-svg-and-png ()
  "Display GR-generated figures through returned values and explicit MIME display."
  (skip-unless (getenv "JULIA_WORKBENCH_PLOT_PROJECT"))
  (should (display-images-p))
  (workbench-repl-live-fixture
    (switch-to-buffer source)
    (let* ((julia-workbench-environment (getenv "JULIA_WORKBENCH_PLOT_PROJECT"))
           (julia-workbench-plot-formats '(png svg))
           (process-environment (cons "GKSwstype=100" process-environment))
           (buffer (julia-workbench--repl-buffer t)))
      (workbench-repl-live-eval
       buffer "using Plots; gr(); p = plot(1:5, [1,4,2,5,3]; title=\"Workbench native plots\")")
      (with-current-buffer buffer
        (should (= (length julia-workbench--plot-history) 1))
        (should (eq (plist-get (car julia-workbench--plot-history) :type) 'png))
        (should (string-match-p "Plot{Plots.GRBackend" julia-workbench--repl-last-result)))
      (workbench-repl-live-eval buffer "display(\"image/svg+xml\", p); display(p);")
      (with-current-buffer buffer
        (should (equal (mapcar (lambda (entry) (plist-get entry :type)) julia-workbench--plot-history)
                       '(png svg png)))
        (should (equal julia-workbench--repl-last-result "nothing"))
        (let ((pane julia-workbench--plot-buffer))
          (should (window-live-p (get-buffer-window pane)))
          (with-current-buffer pane
            (should (eq (car (get-text-property (point-min) 'display)) 'image))
            (should (> (car (image-size (get-text-property (point-min) 'display) t)) 0))
            (julia-workbench-plot-previous)
            (should (string-match-p "SVG" header-line-format))
            (should (> (car (image-size (get-text-property (point-min) 'display) t)) 0))
            (when (fboundp 'x-export-frames)
              (let ((file (expand-file-name "results/plots/native-plots.png"
                                             workbench-repl-live-directory)))
                (make-directory (file-name-directory file) t)
                (redisplay t)
                (let ((coding-system-for-write 'no-conversion))
                  (with-temp-file file
                    (set-buffer-multibyte nil)
                    (insert (x-export-frames nil 'png))))))))))))

(defun workbench-plot-ui-run ()
  "Run optional graphical fixtures, retain their messages, and exit test Emacs."
  (let ((status 1)
        (directory (expand-file-name "results/plots" workbench-repl-live-directory))
        (coding-system-for-write 'utf-8-emacs))
    (unwind-protect
        (let ((stats (ert-run-tests-batch "\\`workbench-plot-ui-")))
          (setq status (if (zerop (ert-stats-completed-unexpected stats)) 0 1)))
      (make-directory directory t)
      (with-current-buffer "*Messages*"
        (write-region (point-min) (point-max) (expand-file-name "ui.log" directory) nil 'silent))
      (kill-emacs status))))

(provide 'plot-ui-tests)
;;; plot-ui-tests.el ends here
