;;; repl-integration-tests.el --- Live Julia comint fixtures -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Real runtime checks without a server or external Julia packages.  Processes,
;; buffers and temporary environments are cleaned on every exit path.

;;; Code:

(require 'ert)
(require 'julia-workbench-repl)

(defconst workbench-repl-live-directory
  (file-name-directory (or load-file-name buffer-file-name)))
(defvar workbench-repl-live-timings nil
  "Elapsed startup and evaluation times recorded by live tests.")

(when-let* ((path (getenv "JULIA_WORKBENCH_GRAMMAR_PATH")))
  (add-to-list 'treesit-extra-load-path path)
  (unless (treesit-ready-p 'julia t) (error "Julia grammar unavailable: %s" path)))

(defmacro workbench-repl-live-fixture (&rest body)
  "Run BODY in disposable projects with real Julia and writable history."
  (declare (indent 0) (debug t))
  `(let* ((directory (make-temp-file "workbench-repl-live-" t))
          (fixture (expand-file-name "project α 🐈" directory))
          (julia-workbench--repl-sessions (make-hash-table :test #'equal))
          (julia-workbench-cache-directory (expand-file-name "cache" directory))
          (julia-workbench-julia-command (or (getenv "JULIA") "julia"))
          (julia-workbench-use-tree-sitter nil)
          (source (generate-new-buffer " *Julia live source*")))
     (unwind-protect
         (progn
           (make-directory fixture t)
           (with-temp-file (expand-file-name "Project.toml" fixture) (insert "[deps]\n"))
           (with-current-buffer source
             (setq default-directory (file-name-as-directory fixture))
             (julia-workbench-mode)
             ,@body))
       (let ((results (expand-file-name "results/repl" workbench-repl-live-directory)))
         (make-directory results t)
         (maphash
          (lambda (key buffer)
            (when (buffer-live-p buffer)
              (with-current-buffer buffer
                (write-region (point-min) (point-max)
                              (expand-file-name (concat (secure-hash 'sha256 (prin1-to-string key)) ".log")
                                                results) nil 'silent))
              (kill-buffer buffer)))
          (copy-hash-table julia-workbench--repl-sessions)))
       (when (buffer-live-p source) (kill-buffer source))
       (julia-workbench--doc-cleanup)
       (when-let* ((help (get-buffer "*Julia Documentation*"))) (kill-buffer help))
       (when-let* ((help (get-buffer "*Julia Runtime Documentation*"))) (kill-buffer help))
       (delete-directory directory t))))

(defun workbench-repl-live-wait (buffer &optional condition)
  "Wait for BUFFER to become idle, or for its optional CONDITION to succeed."
  (let ((deadline (+ (float-time) 45)))
    (while (not (with-current-buffer buffer
                  (if condition (funcall condition)
                    (and (eq julia-workbench--repl-state 'idle)
                         (null julia-workbench--repl-queue)))))
      (when (> (float-time) deadline)
        (ert-fail (with-current-buffer buffer (buffer-string))))
      (accept-process-output nil 0.03))
    ;; Let the basic frontend's trailing prompt reach comint as well.
    (accept-process-output (get-buffer-process buffer) 0.05)))

(defun workbench-repl-live-eval (buffer text &optional filename line)
  "Evaluate TEXT in BUFFER using optional FILENAME and LINE, awaiting completion."
  (let ((start (float-time)))
    (julia-workbench--repl-request buffer "eval" text (or filename "REPL") (or line 1))
    (workbench-repl-live-wait buffer)
    (push (cons "evaluation" (- (float-time) start)) workbench-repl-live-timings))
  (with-current-buffer buffer julia-workbench--repl-last-result))

(ert-deftest workbench-repl-live-evaluation-and-source-locations ()
  "Evaluate line/region/buffer/file and preserve filenames, line offsets and includes."
  (workbench-repl-live-fixture
    (insert "# first\n# second\nα = 40\nα + 2;\n")
    (setq buffer-file-name (expand-file-name "probe α 🐈.jl" fixture))
    (goto-char (point-min)) (forward-line 2)
    (let ((start (float-time)) (timer-fired nil))
      (run-at-time 0 nil (lambda () (setq timer-fired t)))
      (julia-workbench-send-line)
      (let ((buffer (julia-workbench--repl-buffer)))
        (should (process-live-p (get-buffer-process buffer)))
        (workbench-repl-live-wait buffer)
        (should timer-fired)
        (push (cons "startup-and-first-eval" (- (float-time) start)) workbench-repl-live-timings)
        (forward-line 1)
        (julia-workbench-send-region (line-beginning-position) (line-end-position))
        (workbench-repl-live-wait buffer)
        (julia-workbench-copy-last-eval-result)
        (should (equal (current-kill 0) "42"))
        (should (equal (workbench-repl-live-eval buffer "println(\"stdout 🐈\"); 43") "43"))
        (julia-workbench-copy-last-eval-result)
        (should (equal (current-kill 0) "43"))
        (should (equal (workbench-repl-live-eval buffer "@__LINE__" buffer-file-name 11) "11"))
        (workbench-repl-live-eval buffer "error(\"location probe\")" buffer-file-name 13)
        (with-current-buffer buffer
          (should (string-match-p "probe α 🐈.jl:13" (buffer-string)))
          (should (equal julia-workbench--repl-last-result "11"))
          (should-not (string-match-p "WorkbenchREPL.request\|\036\|\037" (buffer-string))))
        (should-error (julia-workbench-send-buffer-file) :type 'user-error)
        (erase-buffer) (insert "include(\"nested.jl\"); nested_value + 5\n")
        (with-temp-file (expand-file-name "nested.jl" fixture) (insert "nested_value = 20\n"))
        (write-region (point-min) (point-max) buffer-file-name nil 'silent)
        (set-buffer-modified-p nil)
        (julia-workbench-send-buffer-file) (workbench-repl-live-wait buffer)
        (should (equal (with-current-buffer buffer julia-workbench--repl-last-result) "25"))
        (insert "nested_value + 6\n")
        (julia-workbench-send-buffer) (workbench-repl-live-wait buffer)
        (should (equal (with-current-buffer buffer julia-workbench--repl-last-result) "26"))
        (erase-buffer) (insert "@__LINE__\n")
        (goto-char (point-min)) (push-mark (point-max) nil t)
        (let ((transient-mark-mode t)) (julia-workbench-send-dwim))
        (workbench-repl-live-wait buffer)
        (should (equal (with-current-buffer buffer julia-workbench--repl-last-result) "1"))
        (let ((file (expand-file-name "results/repl/timings.el" workbench-repl-live-directory)))
          (make-directory (file-name-directory file) t)
          (with-temp-file file (prin1 (reverse workbench-repl-live-timings) (current-buffer))))))))

(ert-deftest workbench-repl-live-environment-sharing-and-standalone ()
  "Share compatible sessions, isolate nested environments and keep standalone private."
  (workbench-repl-live-fixture
    (let ((first (julia-workbench--repl-buffer t))
          (nested (expand-file-name "nested" fixture)))
      (workbench-repl-live-wait first)
      (should (equal (workbench-repl-live-eval first "join(LOAD_PATH, \"|\")") "\"@|@stdlib\""))
      (should (eq first (julia-workbench--repl-buffer t)))
      (should (equal (workbench-repl-live-eval first "scoped_value = 17") "17"))
      (make-directory nested t)
      (with-temp-file (expand-file-name "Project.toml" nested) (insert "[deps]\n"))
      (let ((julia-workbench-environment nested))
        (let ((second (julia-workbench--repl-buffer t)))
          (should-not (eq first second))
          (should (equal (workbench-repl-live-eval second "isdefined(Main, :scoped_value)") "false"))
          (should (equal (workbench-repl-live-eval second "Base.active_project()")
                         (format "%S" (expand-file-name "Project.toml" nested))))))
      (workbench-repl-live-eval first "import Pkg; Pkg.activate(\"nested\")")
      (julia-workbench-repl-activate-project) (workbench-repl-live-wait first)
      (should (equal (workbench-repl-live-eval first "Base.active_project()")
                     (format "%S" (expand-file-name "Project.toml" fixture))))
      (delete-file (expand-file-name "Project.toml" fixture))
      (let ((standalone (julia-workbench--repl-buffer t)))
        (workbench-repl-live-wait standalone)
        (with-current-buffer standalone
          (should (plist-get julia-workbench--repl-context :standalone))
          (should (string-prefix-p julia-workbench-cache-directory
                                   (plist-get julia-workbench--repl-context :environment))))
        (should (equal (workbench-repl-live-eval standalone "isdefined(Main, :scoped_value)") "false"))))))

(ert-deftest workbench-repl-live-interrupt-restart-crash-and-history ()
  "Interrupt actual long evaluation, discard queued work and recover without leaks."
  (workbench-repl-live-fixture
    (let ((buffer (julia-workbench--repl-buffer t)))
      (workbench-repl-live-wait buffer)
      (with-current-buffer buffer
        (goto-char (point-max))
        (insert "typed_history = 21\ntyped_history * 2")
        (comint-send-input))
      (workbench-repl-live-wait buffer)
      (with-current-buffer buffer
        (should (equal julia-workbench--repl-last-result "42"))
        (should (equal (ring-ref comint-input-ring 0) "typed_history = 21\ntyped_history * 2")))
      (julia-workbench--repl-request buffer "eval" "println(\"SLEEP STARTED\"); flush(stdout); sleep(30); 99" "REPL" 1)
      (julia-workbench--repl-request buffer "eval" "queued_should_not_run = true" "REPL" 1)
      (workbench-repl-live-wait buffer (lambda () (string-match-p "SLEEP STARTED" (buffer-string))))
      (julia-workbench-repl-interrupt)
      (workbench-repl-live-wait buffer)
      (should (equal (workbench-repl-live-eval buffer "isdefined(Main, :queued_should_not_run)") "false"))
      (let ((old-process (get-buffer-process buffer)))
        (julia-workbench-repl-restart)
        (workbench-repl-live-wait buffer)
        (should-not (process-live-p old-process))
        (with-current-buffer buffer
          (should-not julia-workbench--repl-last-result)
          (should (equal (ring-ref comint-input-ring 0) "typed_history = 21\ntyped_history * 2")))
        (should (equal (workbench-repl-live-eval buffer "isdefined(Main, :typed_history)") "false")))
      (julia-workbench--repl-request buffer "eval" "exit(2)" "REPL" 1)
      (workbench-repl-live-wait buffer (lambda () (eq julia-workbench--repl-state 'stopped)))
      (with-current-buffer source
        (should (eq buffer (julia-workbench--repl-buffer t))))
      (should (equal (workbench-repl-live-eval buffer "6 * 7") "42"))
      (let ((process (get-buffer-process buffer)))
        (kill-buffer buffer)
        (should-not (process-live-p process))
        (should (= (hash-table-count julia-workbench--repl-sessions) 0))))))

(ert-deftest workbench-repl-live-documentation-and-unicode-completion ()
  "Query evaluated bindings and Unicode-indexed completion without sharing helper state."
  (workbench-repl-live-fixture
    (let ((buffer (julia-workbench--repl-buffer t)))
      (workbench-repl-live-eval buffer "\"\"\"Runtime quasar docs α 🐈.\"\"\"\nworkbench_runtime_nebula(x) = x + 1")
      (workbench-repl-live-eval buffer "42")
      (julia-workbench-repl-documentation "workbench_runtime_nebula")
      (workbench-repl-live-wait buffer)
      (with-current-buffer "*Julia Runtime Documentation*"
        (should (string-match-p "Runtime quasar docs α 🐈" (buffer-string))))
      (should (equal (workbench-repl-live-eval buffer "ans") "42"))
      (julia-workbench-documentation "workbench_runtime_nebula")
      (workbench-repl-live-wait buffer (lambda () (= (hash-table-count julia-workbench--doc-jobs) 0)))
      (with-current-buffer "*Julia Documentation*"
        (should (string-match-p "No documentation found" (buffer-string))))
      (erase-buffer) (insert "α = \"🐈\"; workbench_runtime_neb")
      (julia-workbench-repl-complete)
      (workbench-repl-live-wait buffer)
      (should (equal (buffer-string) "α = \"🐈\"; workbench_runtime_nebula"))
      (erase-buffer) (insert "workbench_runtime_neb")
      (julia-workbench-repl-complete) (insert "modified")
      (workbench-repl-live-wait buffer)
      (should (equal (buffer-string) "workbench_runtime_nebmodified"))
      (with-current-buffer buffer
        (goto-char (point-max)) (insert "workbench_runtime_neb")
        (julia-workbench-repl-complete))
      (workbench-repl-live-wait buffer)
      (with-current-buffer buffer
        (should (string-suffix-p "workbench_runtime_nebula" (buffer-string)))))))

(ert-deftest workbench-repl-live-structured-top-level ()
  "Send a nested structured form with the real grammar and runtime."
  (skip-unless (treesit-ready-p 'julia t))
  (workbench-repl-live-fixture
    (insert "module RuntimeModule\nadd_one(x) = x + 1\nend\n")
    (let ((julia-workbench-use-tree-sitter t)) (julia-workbench-mode))
    (goto-char (point-min)) (search-forward "x + 1")
    (julia-workbench-send-top-level-form)
    (let ((buffer (julia-workbench--repl-buffer)))
      (workbench-repl-live-wait buffer)
      (should (equal (workbench-repl-live-eval buffer "RuntimeModule.add_one(41)") "42")))))

(ert-deftest workbench-repl-live-plots-and-lifecycle ()
  "Capture rich results, explicit and asynchronous displays in an isolated session."
  (skip-unless (image-type-available-p 'svg))
  (workbench-repl-live-fixture
    (let* ((julia-workbench-plot-formats '(svg))
           (buffer (julia-workbench--repl-buffer t))
           (julia-workbench-plot-history-limit 4))
      (workbench-repl-live-eval
       buffer (concat "struct LiveFigure end; "
                      "Base.show(io::IO, ::MIME\"image/svg+xml\", ::LiveFigure) = "
                      "print(io, \"<svg xmlns=\\\"http://www.w3.org/2000/svg\\\" width=\\\"200\\\" height=\\\"100\\\"><text>α 🐈</text></svg>\"); "
                      "LiveFigure()"))
      (with-current-buffer buffer
        (should (= (length julia-workbench--plot-history) 1))
        (should (equal julia-workbench--repl-last-result "LiveFigure()")))
      (workbench-repl-live-eval buffer "LiveFigure();")
      (with-current-buffer buffer (should (= (length julia-workbench--plot-history) 1)))
      (workbench-repl-live-eval buffer "display(LiveFigure()); display(LiveFigure());")
      (with-current-buffer buffer (should (= (length julia-workbench--plot-history) 3)))
      (workbench-repl-live-eval buffer "@async begin sleep(0.2); display(LiveFigure()); end; nothing")
      (workbench-repl-live-wait buffer (lambda () (= (length julia-workbench--plot-history) 4)))
      (workbench-repl-live-eval
       buffer "display(\"image/svg+xml\", \"<svg xmlns=\\\"http://www.w3.org/2000/svg\\\">\" * \" \"^70000 * \"</svg>\");")
      (with-current-buffer buffer
        (should (= (length julia-workbench--plot-history) 4))
        (should (> (file-attribute-size (file-attributes
                                         (plist-get (car (last julia-workbench--plot-history)) :file))) 65536))
        (should (eq julia-workbench--repl-state 'idle))
        (should-not (string-match-p "\036\|\037\|<svg" (buffer-string))))
      (let ((julia-workbench-plot-enabled nil))
        (let ((other (julia-workbench--repl-buffer t)))
          (workbench-repl-live-wait other)
          (should-not (eq buffer other))
          (with-current-buffer other (should-not julia-workbench--plot-directory))))
      (let ((old-directory (with-current-buffer buffer julia-workbench--plot-directory)))
        (with-current-buffer buffer (julia-workbench-repl-restart))
        (workbench-repl-live-wait buffer)
        (should-not (file-exists-p old-directory))
        (with-current-buffer buffer
          (should-not julia-workbench--plot-history)
          (let ((new-directory julia-workbench--plot-directory))
            (kill-buffer buffer)
            (should-not (file-exists-p new-directory))))))))

(provide 'repl-integration-tests)
;;; repl-integration-tests.el ends here
