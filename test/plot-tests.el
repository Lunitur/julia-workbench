;;; plot-tests.el --- Native plot protocol and history fixtures -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Check independent plot events, bounded file ownership, history and export.
;; Image rendering is verified separately in a graphical Emacs process.

;;; Code:

(require 'ert)
(require 'julia-workbench-repl)

(defconst workbench-plot-svg
  "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"200\" height=\"100\"><path d=\"M0 100 L200 0\" stroke=\"blue\"/></svg>")

(defmacro workbench-plot-fixture (&rest body)
  "Run BODY in a disposable REPL with private plot files."
  (declare (indent 0) (debug t))
  `(let ((directory (make-temp-file "workbench-plot-" t)))
     (unwind-protect
         (with-temp-buffer
           (julia-workbench-repl-mode)
           (setq julia-workbench--repl-token "plot-test"
                 julia-workbench--repl-state 'busy
                 julia-workbench--repl-context '(:plot-formats (svg png) :plot-max-bytes 200000)
                 julia-workbench--plot-directory directory)
           ,@body)
       (when (file-directory-p directory) (delete-directory directory t)))))

(defun workbench-plot-record (directory number &optional contents)
  "Write plot NUMBER with CONTENTS into DIRECTORY, returning its metadata."
  (let* ((name (format "plot-%d.svg" number))
         (file (expand-file-name name directory)))
    (with-temp-file file (insert (or contents workbench-plot-svg)))
    (format "image/svg+xml\t%s\t%d" name (file-attribute-size (file-attributes file)))))

(defun workbench-plot-frame (text)
  "Wrap plot metadata TEXT in a session event."
  (concat "\036plot-test\t0\tplot\tok\t" (julia-workbench--repl-encode text) "\037"))

(ert-deftest workbench-plot-events-preserve-evaluation-state ()
  "Plot events split at every boundary must leave the pending evaluation intact."
  (let ((frame (workbench-plot-frame "image/svg+xml\tplot-1.svg\t123")))
    (dotimes (boundary (1+ (length frame)))
      (with-temp-buffer
        (julia-workbench-repl-mode)
        (setq julia-workbench--repl-token "plot-test" julia-workbench--repl-state 'busy
              julia-workbench--repl-pending '(:id 7 :kind "eval")
              julia-workbench--repl-last-result "previous")
        (let (received)
          (cl-letf (((symbol-function 'julia-workbench--plot-receive)
                     (lambda (text) (push text received))))
            (should (equal (concat (julia-workbench--repl-filter (substring frame 0 boundary))
                                   (julia-workbench--repl-filter (substring frame boundary))) ""))
            (should (equal received '("image/svg+xml\tplot-1.svg\t123")))
            (should (eq julia-workbench--repl-state 'busy))
            (should (= (plist-get julia-workbench--repl-pending :id) 7))
            (should (equal julia-workbench--repl-last-result "previous"))))))))

(ert-deftest workbench-plot-invalid-record-does-not-stall ()
  "Reject invalid metadata without losing subsequent evaluation completion."
  (workbench-plot-fixture
    (setq julia-workbench--repl-pending '(:id 7 :kind "eval"))
    (let ((frame (concat (workbench-plot-frame "bad")
                         "\036plot-test\t7\teval\tok\t" (julia-workbench--repl-encode "42") "\037")))
      (should (equal (julia-workbench--repl-filter frame) ""))
      (should-not julia-workbench--plot-history)
      (should (eq julia-workbench--repl-state 'idle))
      (should (equal julia-workbench--repl-last-result "42")))))

(ert-deftest workbench-plot-validation-and-file-ownership ()
  "Accept only supported, size-checked session files, excluding links and traversal."
  (workbench-plot-fixture
    (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) nil)))
      (let ((text (workbench-plot-record directory 1)))
        (julia-workbench--plot-receive text)
        (should-error (julia-workbench--plot-receive text))
        (should-error (julia-workbench--plot-receive "image/svg+xml\t../plot-1.svg\t123"))
        (should-error (julia-workbench--plot-receive "image/svg+xml\tplot-1.svg\t1"))
        (should-error (julia-workbench--plot-receive "image/png\tplot-1.svg\t123"))
        (should-error (julia-workbench--plot-receive "text/html\tplot-1.svg\t123"))
        (let ((julia-workbench--repl-context '(:plot-formats (png) :plot-max-bytes 200000)))
          (should-error (julia-workbench--plot-receive (workbench-plot-record directory 2))))
        (let ((julia-workbench--repl-context '(:plot-formats (svg) :plot-max-bytes 1)))
          (should-error (julia-workbench--plot-receive (workbench-plot-record directory 3))))
        (make-symbolic-link (expand-file-name "plot-1.svg" directory)
                            (expand-file-name "plot-4.svg" directory))
        (should-error (julia-workbench--plot-receive
                       (replace-regexp-in-string "plot-1" "plot-4" text)))
        (should (= (length julia-workbench--plot-history) 1))))))

(ert-deftest workbench-plot-history-export-and-pane-recreation ()
  "Bound disk history, navigate both ways, export exact bytes and reopen the pane."
  (workbench-plot-fixture
    (let ((julia-workbench-plot-history-limit 2)
          (session (current-buffer))
          (export (make-temp-file "workbench-export-")))
      (unwind-protect
          (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) nil)))
            (dotimes (n 3) (julia-workbench--plot-receive (workbench-plot-record directory (1+ n))))
            (should (= (length julia-workbench--plot-history) 2))
            (should-not (file-exists-p (expand-file-name "plot-1.svg" directory)))
            (should (= julia-workbench--plot-index 1))
            (julia-workbench--plot-render session)
            (with-current-buffer julia-workbench--plot-buffer
              (julia-workbench-plot-previous)
              (should (string-match-p "Plot 1/2" header-line-format))
              (julia-workbench-plot-next)
              (should (string-match-p "Plot 2/2" header-line-format))
              (should-error (julia-workbench-plot-save export) :type 'file-already-exists)
              (delete-file export)
              (julia-workbench-plot-save export)
              (should (equal (with-temp-buffer (insert-file-contents export) (buffer-string))
                             workbench-plot-svg)))
            (kill-buffer julia-workbench--plot-buffer)
            (should (= (length julia-workbench--plot-history) 2))
            (should (buffer-live-p (julia-workbench--plot-render session)))
            (julia-workbench--plot-cleanup)
            (should-not (file-exists-p directory))
            (should-not julia-workbench--plot-history))
        (when (file-exists-p export) (delete-file export))))))

(ert-deftest workbench-plot-settings-select-distinct-sessions ()
  "Capture capability/preferences in session identity and allow text-only sessions."
  (cl-letf (((symbol-function 'image-type-available-p) (lambda (type) (eq type 'png)))
            ((symbol-function 'julia-workbench--executable) (lambda (_) "/bin/sh")))
    (with-temp-buffer
      (let* ((julia-workbench-plot-enabled t)
             (first (julia-workbench--repl-settings)))
        (should (equal (plist-get first :plot-formats) '(png)))
        (let ((julia-workbench-plot-enabled nil))
          (should-not (plist-get (julia-workbench--repl-settings) :plot-formats))
          (should-not (equal (plist-get first :key) (plist-get (julia-workbench--repl-settings) :key))))))))

(ert-deftest workbench-plot-source-access-to-stopped-session ()
  "Keep cached plots accessible from source after a crash, without launching Julia."
  (let ((session (generate-new-buffer " *stopped Julia*"))
        (julia-workbench--repl-sessions (make-hash-table :test #'equal)))
    (unwind-protect
        (with-temp-buffer
          (puthash '(cached) session julia-workbench--repl-sessions)
          (cl-letf (((symbol-function 'julia-workbench--repl-settings)
                     (lambda () '(:key (cached))))
                    ((symbol-function 'make-process)
                     (lambda (&rest _) (ert-fail "Unexpected Julia startup"))))
            (should (eq (julia-workbench--plot-owner) session))
            (remhash '(cached) julia-workbench--repl-sessions)
            (should-error (julia-workbench--plot-owner) :type 'user-error)))
      (kill-buffer session))))

(provide 'plot-tests)
;;; plot-tests.el ends here
