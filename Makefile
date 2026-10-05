JULIA ?= julia
EMACS ?= emacs

.PHONY: setup-server test test-editing test-completion test-corfu-ui test-doom-ui test-doom-corfu-ui preview-doom test-unicode test-eglot test-eglot-integration test-docs test-documentation test-documentation-integration test-repl test-repl-helper test-repl-integration test-server benchmark check check-editing check-completion check-documentation check-repl check-eglot byte-compile checkdoc

ELISP = julia-workbench.el julia-workbench-completion.el julia-workbench-eglot.el julia-workbench-doc.el julia-workbench-plot.el julia-workbench-repl.el test/editing-tests.el test/completion-tests.el test/eglot-tests.el test/eglot-integration-tests.el test/documentation-ui-tests.el test/documentation-integration-tests.el test/repl-tests.el test/plot-tests.el test/repl-integration-tests.el test/plot-ui-tests.el test/server-tests.el

setup-server:
	$(JULIA) --startup-file=no julia/setup-server.jl

test-docs:
	$(JULIA) --startup-file=no --project=test/fixtures/Example test/documentation-tests.jl

test-documentation:
	$(EMACS) -Q --batch -L . --eval '(setq load-prefer-newer t)' -l test/documentation-ui-tests.el -f ert-run-tests-batch-and-exit

test-documentation-integration:
	JULIA="$(JULIA)" $(EMACS) -Q --batch -L . --eval '(setq load-prefer-newer t)' -l test/documentation-integration-tests.el -f ert-run-tests-batch-and-exit

test-server:
	JULIA="$(JULIA)" $(EMACS) -Q --batch -l test/server-tests.el -f ert-run-tests-batch-and-exit

test-editing:
	$(EMACS) -Q --batch -L . --eval '(setq load-prefer-newer t)' -l julia-workbench.el -l test/editing-tests.el -f ert-run-tests-batch-and-exit

test-eglot:
	$(EMACS) -Q --batch -L . --eval '(setq load-prefer-newer t)' -l test/eglot-tests.el -f ert-run-tests-batch-and-exit

test-completion:
	$(EMACS) -Q --batch -L . --eval '(setq load-prefer-newer t)' -l test/completion-tests.el -f ert-run-tests-batch-and-exit

test-unicode:
	$(JULIA) --startup-file=no test/unicode-tests.jl

# Optional: pass space-separated installed Corfu/extension/Compat directories.
test-corfu-ui:
	JULIA="$(JULIA)" $(EMACS) -Q -L . -L test $(foreach directory,$(CORFU_LOAD_PATH),-L "$(directory)") --eval '(setq load-prefer-newer t)' -l test/completion-corfu-tests.el --eval '(run-at-time 1 nil (function workbench-corfu-run))'

# Optional: use the installed package, without adding this checkout to load-path.
DOOM_EMACS_DIR ?= $(HOME)/.config/emacs
test-doom-ui:
	JULIA="$(JULIA)" $(EMACS) --init-directory "$(DOOM_EMACS_DIR)" -l "$(CURDIR)/test/doom-integration-tests.el" --eval '(run-at-time 2 nil (function workbench-doom-run))'

test-doom-corfu-ui:
	JULIA="$(JULIA)" JULIA_WORKBENCH_CORFU_RESULTS=corfu-doom-migration $(EMACS) --init-directory "$(DOOM_EMACS_DIR)" -L test --eval '(setq load-prefer-newer t)' -l test/completion-corfu-tests.el --eval '(run-at-time 2 nil (function workbench-corfu-run))'

preview-doom:
	JULIA="$(JULIA)" EMACS="$(EMACS)" EMACSDIR="$(DOOM_EMACS_DIR)" bash examples/preview-doom.sh

test-eglot-integration:
	JULIA="$(JULIA)" $(EMACS) -Q --batch -L . --eval '(setq load-prefer-newer t)' -l test/eglot-integration-tests.el -f ert-run-tests-batch-and-exit

test-repl:
	$(EMACS) -Q --batch -L . --eval '(setq load-prefer-newer t)' -l test/repl-tests.el -f ert-run-tests-batch-and-exit

test-repl-helper:
	$(JULIA) --startup-file=no test/repl-tests.jl

.PHONY: test-plots test-plot-helper test-plot-ui test-doom-plot-ui check-plots
test-plots:
	$(EMACS) -Q --batch -L . --eval '(setq load-prefer-newer t)' -l test/plot-tests.el -f ert-run-tests-batch-and-exit

test-plot-helper:
	$(JULIA) --startup-file=no test/plot-tests.jl

# Optional: JULIA_WORKBENCH_PLOT_PROJECT points to an existing Plots.jl project.
test-plot-ui:
	JULIA="$(JULIA)" $(EMACS) -Q -L . -L test --eval '(setq load-prefer-newer t)' -l test/plot-ui-tests.el --eval '(run-at-time 1 nil (function workbench-plot-ui-run))'

test-doom-plot-ui:
	JULIA="$(JULIA)" $(EMACS) --init-directory "$(DOOM_EMACS_DIR)" -L test --eval '(setq load-prefer-newer t)' -l test/plot-ui-tests.el --eval '(run-at-time 2 nil (function workbench-plot-ui-run))'

test-repl-integration:
	JULIA="$(JULIA)" $(EMACS) -Q --batch -L . --eval '(setq load-prefer-newer t)' -l test/repl-integration-tests.el -f ert-run-tests-batch-and-exit

test: test-editing test-completion test-unicode test-eglot test-docs test-documentation test-documentation-integration test-repl test-repl-helper test-plots test-plot-helper test-repl-integration test-server test-eglot-integration

benchmark:
	$(JULIA) --startup-file=no --project=test/fixtures/Example test/documentation-benchmark.jl
	JULIA="$(JULIA)" EMACS="$(EMACS)" $(JULIA) --startup-file=no test/server-benchmark.jl

byte-compile:
	$(EMACS) -Q --batch -L . -L test --eval '(setq load-prefer-newer t byte-compile-error-on-warn t)' -f batch-byte-compile $(ELISP)

checkdoc:
	$(EMACS) -Q --batch --eval '(progn (require (quote checkdoc)) (setq checkdoc-spellcheck-documentation-flag nil) (dolist (file (quote ($(foreach file,$(ELISP),"$(file)")))) (checkdoc-file file)))'

check-editing: test-editing byte-compile checkdoc

check-completion: test-completion test-unicode test-eglot-integration byte-compile checkdoc

check-documentation: test-documentation test-docs test-documentation-integration test-eglot-integration byte-compile checkdoc

check-repl: test-repl test-repl-helper test-repl-integration byte-compile checkdoc

check-plots: test-plots test-plot-helper test-repl-integration byte-compile checkdoc

check-eglot: test-eglot test-eglot-integration byte-compile checkdoc

check: test byte-compile checkdoc
