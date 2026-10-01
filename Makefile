JULIA ?= julia
EMACS ?= emacs

.PHONY: setup-server test test-editing test-docs test-server benchmark check check-editing byte-compile checkdoc

setup-server:
	$(JULIA) --startup-file=no julia/setup-server.jl

test-docs:
	$(JULIA) --startup-file=no --project=test/fixtures/Example test/documentation-tests.jl

test-server:
	JULIA="$(JULIA)" $(EMACS) -Q --batch -l test/server-tests.el -f ert-run-tests-batch-and-exit

test-editing:
	$(EMACS) -Q --batch -L . -l julia-workbench.el -l test/editing-tests.el -f ert-run-tests-batch-and-exit

test: test-editing test-docs test-server

benchmark:
	$(JULIA) --startup-file=no --project=test/fixtures/Example test/documentation-benchmark.jl
	JULIA="$(JULIA)" EMACS="$(EMACS)" $(JULIA) --startup-file=no test/server-benchmark.jl

byte-compile:
	$(EMACS) -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile julia-workbench.el test/editing-tests.el test/server-tests.el

checkdoc:
	$(EMACS) -Q --batch --eval '(progn (require (quote checkdoc)) (setq checkdoc-spellcheck-documentation-flag nil) (dolist (file (quote ("julia-workbench.el" "test/editing-tests.el" "test/server-tests.el"))) (checkdoc-file file)))'

check-editing: test-editing byte-compile checkdoc

check: test byte-compile checkdoc
