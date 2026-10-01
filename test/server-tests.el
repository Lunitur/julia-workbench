;;; server-tests.el --- Real Julia server compatibility fixture -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Exercise the actual wire contract using Emacs's built-in JSON-RPC client.
;; This deliberately precedes major-mode/Eglot UI implementation.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'jsonrpc)
(require 'url-util)

(defconst workbench-test-root
  (file-name-directory (directory-file-name
                        (file-name-directory (or load-file-name buffer-file-name)))))
(defvar workbench-test-report nil)
(defvar workbench-test-requests nil)

(defun workbench-test-julia ()
  "Return the Julia executable for this test run."
  (or (getenv "JULIA") (executable-find "julia")
      (error "Julia missing; set JULIA to its executable")))

(defun workbench-test-tooling ()
  "Return the isolated tooling environment selected by the Julia helper."
  (with-temp-buffer
    (unless (zerop (call-process
                   (workbench-test-julia) nil t nil "--startup-file=no" "-e"
                   "include(ARGS[1]); print(WorkbenchPaths.server_project())"
                   (expand-file-name "julia/paths.jl" workbench-test-root)))
      (error "Cannot resolve tooling environment: %s" (buffer-string)))
    (buffer-string)))

(defun workbench-test-uri (path)
  "Convert absolute file PATH to an LSP URI."
  (concat "file://" (url-hexify-string (expand-file-name path)
                                      url-path-allowed-chars)))

(defun workbench-test-position (text needle &optional end)
  "Find NEEDLE in TEXT and return its UTF-16 LSP position.
Use the end of NEEDLE when END is non-nil."
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (search-forward needle)
    (unless end (backward-char (length needle)))
    (let ((prefix (buffer-substring-no-properties (line-beginning-position) (point))))
      (list :line (1- (line-number-at-pos))
            :character (cl-loop for character across prefix
                                sum (if (> character #xffff) 2 1))))))

(defun workbench-test-offset (text position)
  "Return the character offset in TEXT at UTF-16 LSP POSITION."
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (unless (zerop (forward-line (plist-get position :line)))
      (error "LSP line is outside text: %s" position))
    (let ((remaining (plist-get position :character)))
      (while (> remaining 0)
        (when (eolp) (error "LSP column is outside line: %s" position))
        (cl-decf remaining (if (> (char-after) #xffff) 2 1))
        (forward-char))
      (unless (zerop remaining) (error "LSP column splits a surrogate pair: %s" position))
      (1- (point)))))

(defun workbench-test-apply-edits (text edits &optional expected)
  "Apply LSP EDITS to TEXT after validating their ranges.
When EXPECTED is non-nil, each replaced range must contain that string."
  (let ((ranges
         (mapcar (lambda (edit)
                   (let* ((range (plist-get edit :range))
                          (start (workbench-test-offset text (plist-get range :start)))
                          (end (workbench-test-offset text (plist-get range :end))))
                     (should (<= start end))
                     (when expected (should (equal (substring text start end) expected)))
                     (list start end (plist-get edit :newText))))
                 (append edits nil))))
    (setq ranges (sort ranges (lambda (a b) (> (car a) (car b)))))
    (with-temp-buffer
      (insert text)
      (let ((previous (length text)))
        (dolist (range ranges)
          (should (<= (nth 1 range) previous))
          (delete-region (1+ (car range)) (1+ (nth 1 range)))
          (goto-char (1+ (car range)))
          (insert (nth 2 range))
          (setq previous (car range))))
      (buffer-string))))

(ert-deftest workbench-utf16-positions ()
  "Check BMP and astral characters without a UTF-16 byte-order mark."
  (let ((text "α 🐈 twice(α)\nBase.sin\n"))
    (should (equal (workbench-test-position text "twice") '(:line 0 :character 5)))
    (should (= (workbench-test-offset text '(:line 0 :character 5)) 4))
    (should-error (workbench-test-offset text '(:line 0 :character 3)))
    (should (equal (workbench-test-position text "Base.sin" t) '(:line 1 :character 8)))))

(defun workbench-test-request (connection method params &optional timeout)
  "Send METHOD and PARAMS to CONNECTION, recording response and latency.
Use TIMEOUT seconds, defaulting to 180."
  (let* ((start (float-time))
         (result (jsonrpc-request connection method params :timeout (or timeout 180))))
    (message "%s: %.3fs" method (- (float-time) start))
    (push (list :method (symbol-name method) :seconds (- (float-time) start)
                :result result)
          workbench-test-requests)
    result))

(defun workbench-test-config (_connection method params)
  "Handle server METHOD with PARAMS using offline test configuration."
  (pcase method
    ('workspace/configuration
     (vconcat
      (mapcar (lambda (item)
                (pcase (plist-get item :section)
                  ("julia.symbolCacheDownload" :json-false)
                  (_ nil)))
              (append (plist-get params :items) nil))))
    ((or 'client/registerCapability 'client/unregisterCapability
         'window/workDoneProgress/create) nil)
    (_ (jsonrpc-error :code -32601 :message (format "Unhandled request: %s" method)))))

(defun workbench-test-wait (predicate process description &optional timeout)
  "Wait for PREDICATE while PROCESS runs, or fail with DESCRIPTION.
Use TIMEOUT seconds, defaulting to 180."
  (let ((deadline (+ (float-time) (or timeout 180))))
    (while (not (funcall predicate))
      (unless (process-live-p process)
        (error "Server exited while waiting for %s" description))
      (when (> (float-time) deadline)
        (error "Timed out waiting for %s" description))
      (accept-process-output nil 0.1))))

(defun workbench-test-save-report (connection)
  "Save compatibility report and CONNECTION logs, including on failure."
  (let ((directory (expand-file-name
                    (or (getenv "JULIA_WORKBENCH_TEST_RESULTS") "test/results")
                    workbench-test-root)))
    (make-directory directory t)
    (setq workbench-test-report
          (plist-put workbench-test-report :requests
                     (vconcat (reverse workbench-test-requests))))
    (when connection
      (dolist (entry `(("server-events.log" . ,(jsonrpc-events-buffer connection))
                       ("server-stderr.log" . ,(jsonrpc-stderr-buffer connection))))
        (when (buffer-live-p (cdr entry))
          (with-current-buffer (cdr entry)
            (let ((coding-system-for-write 'utf-8-emacs))
              (write-region (point-min) (point-max)
                            (expand-file-name (car entry) directory) nil 'silent))))))
    ;; `json-serialize' returns a unibyte UTF-8 string. Decode before inserting
    ;; into the multibyte file buffer, or non-ASCII text becomes raw byte chars.
    (with-temp-file (expand-file-name "server-report.json" directory)
      (let ((coding-system-for-write 'utf-8-unix))
        (insert (decode-coding-string
                 (json-serialize workbench-test-report :false-object :json-false)
                 'utf-8))
        (set-buffer-file-coding-system coding-system-for-write)))))

(ert-deftest workbench-server-contract ()
  "Prove completion, hover, diagnostics, definition, rename and formatting."
  (let* ((project (make-temp-file "julia-workbench-project-" t))
         (source (expand-file-name "probe.jl" project))
         (name (make-temp-name "workbench-server-"))
         (tooling (workbench-test-tooling))
         (connection nil)
         (process nil)
         (notifications nil)
         (workbench-test-requests nil)
         (workbench-test-report (list :emacs emacs-version :tooling tooling
                                     :status "running")))
    (unwind-protect
        (progn
          (copy-directory (expand-file-name "test/fixtures/Example" workbench-test-root)
                          project nil t t)
          (let* ((uri (workbench-test-uri source))
                 (project-uri (workbench-test-uri project))
                 (text (with-temp-buffer (insert-file-contents source) (buffer-string)))
                 (startup (float-time)))
            (setq connection
                  (jsonrpc-process-connection
                   :name name
                   :request-dispatcher #'workbench-test-config
                   :notification-dispatcher
                   (lambda (_connection method params)
                     (push (cons method params) notifications)
                     (when (eq method 'textDocument/publishDiagnostics)
                       (message "Diagnostics: %s" params)))
                   :process
                   (lambda ()
                     (setq process
                           (make-process
                            :name name :connection-type 'pipe :noquery t
                            :stderr (get-buffer-create (format "*%s stderr*" name))
                            :command (list (workbench-test-julia) "--startup-file=no"
                                           (concat "--project=" tooling)
                                           (expand-file-name "julia/launch-server.jl"
                                                             workbench-test-root)
                                           project))))))
            (let* ((initialized
                    (workbench-test-request
                     connection 'initialize
                     (list :processId (emacs-pid) :rootUri project-uri
                           :clientInfo (list :name "Julia Workbench fixture" :version "0.1")
                           :capabilities
                           (list :workspace (list :configuration t :workspaceFolders t)
                                 :textDocument
                                 (list :hover (list :contentFormat ["markdown" "plaintext"])
                                       :completion (list :completionItem
                                                         (list :snippetSupport :json-false))
                                       :rename (list :prepareSupport t)))
                           :workspaceFolders (vector (list :uri project-uri :name "Example")))))
                   (capabilities (plist-get initialized :capabilities)))
              (setq workbench-test-report
                    (append workbench-test-report
                            (list :initializeSeconds (- (float-time) startup)
                                  :capabilities capabilities)))
              (dolist (capability '(:completionProvider :hoverProvider :definitionProvider
                                   :renameProvider :documentFormattingProvider))
                (should (plist-get capabilities capability))))
            (jsonrpc-notify connection 'initialized (make-hash-table))
            (jsonrpc-notify connection 'textDocument/didOpen
                            (list :textDocument
                                  (list :uri uri :languageId "julia" :version 1 :text text)))
            (workbench-test-wait
             (lambda ()
               (cl-some (lambda (event)
                          (and (eq (car event) 'textDocument/publishDiagnostics)
                               (equal (plist-get (cdr event) :uri) uri)
                               (cl-find-if
                                (lambda (diagnostic)
                                  (equal (plist-get diagnostic :code)
                                         "unused_function_argument"))
                                (plist-get (cdr event) :diagnostics))))
                        notifications))
             process "fixture diagnostics" 30)
            (setq workbench-test-report
                  (plist-put workbench-test-report :firstDiagnosticsSeconds
                             (- (float-time) startup)))
            ;; Use a symbol that appears after an astral Unicode character.
            ;; UTF-8 bytes, Emacs characters and UTF-16 columns all differ here.
            (let* ((position (workbench-test-position text "twice(α)"))
                   (params (list :textDocument (list :uri uri) :position position))
                   (hover (workbench-test-request connection 'textDocument/hover params))
                   (definition (workbench-test-request connection 'textDocument/definition params))
                   (rename (workbench-test-request
                            connection 'textDocument/rename
                            (append params (list :newName "double_value")))))
              (should (string-match-p "twice" (format "%s" (plist-get hover :contents))))
              (should (> (length definition) 0))
              (let ((location (aref definition 0)))
                (should (equal (plist-get location :uri) uri))
                (should (= (plist-get (plist-get (plist-get location :range) :start) :line) 7)))
              ;; Validate all returned edit ranges against the original text.
              (let* ((change (aref (plist-get rename :documentChanges) 0))
                     (edits (plist-get change :edits)))
                (should (equal (plist-get (plist-get change :textDocument) :uri) uri))
                (should (= (length edits) 3))
                (dolist (edit (append edits nil))
                  (should (equal (plist-get edit :newText) "double_value")))
                (should (cl-find-if
                         (lambda (edit)
                           (let ((start (plist-get (plist-get edit :range) :start)))
                             (and (= (plist-get start :line) (plist-get position :line))
                                  (= (plist-get start :character)
                                     (plist-get position :character)))))
                         (append edits nil)))
                (setq text (workbench-test-apply-edits text edits "twice"))
                (should (string-match-p (regexp-quote "emoji = \"🐈\"") text))
                (jsonrpc-notify connection 'textDocument/didChange
                                (list :textDocument (list :uri uri :version 2)
                                      :contentChanges (vector (list :text text))))))
            (let* ((completion
                    (workbench-test-request
                     connection 'textDocument/completion
                     (list :textDocument (list :uri uri)
                           :position (workbench-test-position text "Base.sin" t))))
                   (items (if (vectorp completion) completion (plist-get completion :items))))
              (should (cl-find-if (lambda (item)
                                    (equal (plist-get item :label) "sin"))
                                  (append items nil)))
              ;; Repeat the identical request to separate first and warm costs.
              (workbench-test-request
               connection 'textDocument/completion
               (list :textDocument (list :uri uri)
                     :position (workbench-test-position text "Base.sin" t)))
              (let ((candidate (cl-find-if (lambda (item)
                                            (equal (plist-get item :label) "sinh"))
                                          (append items nil))))
                (should candidate)
                (should (string-match-p "hyperbolic"
                                        (plist-get (plist-get candidate :documentation) :value)))
                (should (= (plist-get candidate :insertTextFormat) 1))
                (setq text (workbench-test-apply-edits
                            text (vector (plist-get candidate :textEdit)) "sin"))
                (should (string-match-p (regexp-quote "Base.sinh") text))
                (jsonrpc-notify connection 'textDocument/didChange
                                (list :textDocument (list :uri uri :version 3)
                                      :contentChanges (vector (list :text text))))))
            (let ((edits (workbench-test-request
                          connection 'textDocument/formatting
                          (list :textDocument (list :uri uri)
                                :options (list :tabSize 4 :insertSpaces t)))))
              (should (> (length edits) 0))
              (should (cl-some (lambda (edit)
                                (string-match-p (regexp-quote "compact(x) = x+1")
                                                (plist-get edit :newText)))
                              (append edits nil)))
              (setq text (workbench-test-apply-edits text edits))
              (jsonrpc-notify connection 'textDocument/didChange
                              (list :textDocument (list :uri uri :version 4)
                                    :contentChanges (vector (list :text text)))))
            (let ((hover (workbench-test-request
                          connection 'textDocument/hover
                          (list :textDocument (list :uri uri)
                                :position (workbench-test-position text "double_value(α)")))))
              (should (string-match-p "double_value"
                                      (format "%s" (plist-get hover :contents)))))
            (workbench-test-request connection 'shutdown nil 10)
            (jsonrpc-notify connection 'exit nil)
            (workbench-test-wait (lambda () (not (process-live-p process)))
                                 process "clean shutdown" 10)
            (should (= (process-exit-status process) 0))
            (setq workbench-test-report (plist-put workbench-test-report :status "passed"))))
      (setq workbench-test-report
            (plist-put workbench-test-report :notifications
                       (vconcat (mapcar (lambda (event)
                                         (list :method (symbol-name (car event))
                                               :params (cdr event)))
                                       (reverse notifications)))))
      (unless (equal (plist-get workbench-test-report :status) "passed")
        (setq workbench-test-report (plist-put workbench-test-report :status "failed")))
      (unwind-protect (workbench-test-save-report connection)
        (when connection (jsonrpc-shutdown connection t))
        (delete-directory project t)))))

(provide 'server-tests)
;;; server-tests.el ends here
