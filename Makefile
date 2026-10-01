JULIA ?= julia
EMACS ?= emacs

.PHONY: setup-server test test-editing test-eglot test-eglot-integration test-docs test-server benchmark check check-editing check-eglot byte-compile checkdoc

ELISP = julia-workbench.el julia-workbench-eglot.el test/editing-tests.el test/eglot-tests.el test/eglot-integration-tests.el test/server-tests.el

setup-server:
	$(JULIA) --startup-file=no julia/setup-server.jl

test-docs:
	$(JULIA) --startup-file=no --project=test/fixtures/Example test/documentation-tests.jl

test-server:
	JULIA="$(JULIA)" $(EMACS) -Q --batch -l test/server-tests.el -f ert-run-tests-batch-and-exit

test-editing:
	$(EMACS) -Q --batch -L . --eval '(setq load-prefer-newer t)' -l julia-workbench.el -l test/editing-tests.el -f ert-run-tests-batch-and-exit

test-eglot:
	$(EMACS) -Q --batch -L . --eval '(setq load-prefer-newer t)' -l test/eglot-tests.el -f ert-run-tests-batch-and-exit

test-eglot-integration:
	JULIA="$(JULIA)" $(EMACS) -Q --batch -L . --eval '(setq load-prefer-newer t)' -l test/eglot-integration-tests.el -f ert-run-tests-batch-and-exit

test: test-editing test-eglot test-docs test-server test-eglot-integration

benchmark:
	$(JULIA) --startup-file=no --project=test/fixtures/Example test/documentation-benchmark.jl
	JULIA="$(JULIA)" EMACS="$(EMACS)" $(JULIA) --startup-file=no test/server-benchmark.jl

byte-compile:
	$(EMACS) -Q --batch -L . --eval '(setq load-prefer-newer t byte-compile-error-on-warn t)' -f batch-byte-compile $(ELISP)

checkdoc:
	$(EMACS) -Q --batch --eval '(progn (require (quote checkdoc)) (setq checkdoc-spellcheck-documentation-flag nil) (dolist (file (quote ($(foreach file,$(ELISP),"$(file)")))) (checkdoc-file file)))'

check-editing: test-editing byte-compile checkdoc

check-eglot: test-eglot test-eglot-integration byte-compile checkdoc

check: test byte-compile checkdoc
