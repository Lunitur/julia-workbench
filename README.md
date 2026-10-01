# Julia Workbench

A Julia Emacs package under development. The editing mode and the server/docs
feasibility checks are implemented. Eglot integration, completion, documentation
UI and REPL integration follow in [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md).

The namespace is `julia-workbench`; this checkout does not replace the
existing `julia-mode` package or change Doom configuration.

## Editing mode

Add the checkout to Emacs's load path and load the mode:

```elisp
(add-to-list 'load-path "/home/carjin/projects/julia-mode")
;; Use your installed grammar directory; omit this when Emacs already finds it.
(add-to-list 'treesit-extra-load-path
             (expand-file-name "~/.config/emacs/.local/etc/tree-sitter"))
(require 'julia-workbench)
```

New `.jl` buffers and scripts with a Julia shebang select
`julia-workbench-mode`. Use `M-x julia-workbench-mode` in an existing buffer.
The mode derives from `prog-mode` and needs no Julia executable or language
server for editing. It does not install packages or grammars on opening files.

With a Julia tree-sitter grammar, the mode provides syntax highlighting,
four-space indentation (customize `julia-workbench-indent-offset`), Imenu, and
`C-M-a` / `C-M-e` definition navigation, including short-form methods.
`C-c C-SPC` selects the containing top-level form; `C-c C-e` selects a syntax
node and expands an active selection to its parent. Multiline string and comment
contents retain their indentation. Parsing errors permit continued editing;
indentation and navigation around incomplete forms are best effort.

Without the grammar, basic highlighting, nested block comments, multiline
strings, character literals and ordinary comment commands work. Indentation
copies the previous line; structural selection requires the grammar. This
fallback is deliberately a small lexical aid, with no second Julia parser.
Interpolation with nested string literals needs the grammar for accurate
highlighting. Customize `julia-workbench-use-tree-sitter` to disable it explicitly.

On Nix, use the supplied `libtree-sitter-julia.so` through
`treesit-extra-load-path`. Elsewhere, `M-x julia-workbench-install-grammar`
explicitly downloads and compiles the grammar using Git and a C compiler;
customize `julia-workbench-grammar-source` to pin its revision. Reopen buffers
after installing or changing grammar availability. Emacs without tree-sitter
support can still use basic editing.

Editing checks are independent of Julia and the server:

```sh
make check-editing
# Require structural tests with the existing Nix grammar:
JULIA_WORKBENCH_GRAMMAR_PATH="$HOME/.config/emacs/.local/etc/tree-sitter" \
  make check-editing
```

Without a discoverable grammar, structural ERT tests report skips. An explicit
`JULIA_WORKBENCH_GRAMMAR_PATH` that cannot load the Julia grammar fails the run.
See below for the Nix command when Make is unavailable.

## Feasibility checks

Requires Julia 1.11+ and Emacs 30.1+ with built-in JSON-RPC and ERT. GNU Make is
optional; its recipes are ordinary shell commands. The exercised versions and
feature results are recorded in [COMPATIBILITY.md](COMPATIBILITY.md).
The proposed minimum versions have not yet been tested; the current validated
combination is Julia 1.13.1 with Emacs 31.1.

Explicitly install the pinned server, then run the checks:

```sh
make setup-server
make check
```

On NixOS without Make, use `nix shell nixpkgs#gnumake -c make setup-server`
and `nix shell nixpkgs#gnumake -c make check`, or run:

```sh
julia --startup-file=no julia/setup-server.jl
julia --startup-file=no --project=test/fixtures/Example test/documentation-tests.jl
emacs -Q --batch -l test/server-tests.el -f ert-run-tests-batch-and-exit
JULIA_WORKBENCH_GRAMMAR_PATH="$HOME/.config/emacs/.local/etc/tree-sitter" \
  emacs -Q --batch -L . -l julia-workbench.el -l test/editing-tests.el \
  -f ert-run-tests-batch-and-exit
```

The server test uses a temporary copy of a tiny project and the real
LanguageServer process. Results, timings, capabilities, request responses and
stderr logs go into the ignored `test/results/` directory. Package installation
does not run implicitly from tests or the launcher. A missing tooling environment
is an error; run the setup command first.

Run `make benchmark` for separate documentation-worker timings and server runs
with an empty, then reused, symbol cache. These runs retain Julia's package
precompile caches; installation/precompilation time is separate. Set `JULIA`
and `EMACS` to choose executables. Server artifacts can be redirected using
`JULIA_WORKBENCH_TEST_RESULTS` (default `test/results/`).

The server environment lives in
`${XDG_CACHE_HOME:-~/.cache}/julia-workbench/LanguageServer-6.0.1/julia-MAJOR.MINOR`.
Symbol caches live alongside it under `julia-workbench/symbols/`. Override them
with `JULIA_WORKBENCH_SERVER_PROJECT` and `JULIA_WORKBENCH_SYMBOL_CACHE`, using
user-writable directories outside the checkout and Nix store. Julia's normal
depot is reused for downloaded packages and compilation; the global Julia
**environment** is neither activated nor modified. Setup copies the checked-in
Project/Manifest into the writable tooling directory and instantiates that lock.
The recorded manifest is for Julia 1.13.1; other Julia minors still need testing.
Setup refuses to overwrite an existing environment with a different project.

The launcher keeps tooling dependencies separate from the analyzed project:

```sh
julia --startup-file=no --project=/absolute/path/to/tooling \
  julia/launch-server.jl /absolute/path/to/analyzed/project
```

Stdout is reserved for LSP; diagnostics go to stderr. The client must initialize
the server before requesting features. Project and server packages must already
be installed. The test client disables upstream symbol-cache downloads.

## Documentation prototype

This helper uses only Julia standard libraries. It accepts arguments as data;
lookup queries cannot evaluate Julia expressions. Package names are selected
explicitly, and loading a selected package executes its ordinary Julia loading
code in the helper process. Helpers do not share a REPL's state.

```sh
julia --startup-file=no julia/documentation.jl lookup Base.sin
julia --startup-file=no julia/documentation.jl lookup 'Base.@time'
julia --startup-file=no julia/documentation.jl lookup 'Base.+'
julia --startup-file=no julia/documentation.jl search 'sine'
julia --startup-file=no --project=test/fixtures/Example \
  julia/documentation.jl lookup WorkbenchExample.greet WorkbenchExample
julia --startup-file=no --project=test/fixtures/Example \
  julia/documentation.jl search quasarotter WorkbenchExample
```

Lookup produces Markdown with signatures and examples. Search uses Julia's
`apropos` to search documentation text, returning up to 100 sorted, unique symbol
names. Output identifies its scope, truncation, and empty results. Base/Core and
the helper's loaded standard-library documentation are included; docs from
project dependencies are available once explicitly selected or loaded by a
selected package. `apropos` searches Julia's process-wide documentation registry;
each CLI invocation starts a fresh helper process. The Julia API
returns structured results for the future Emacs adapter; the prototype CLI emits
human-readable UTF-8 text. Asynchronous Emacs jobs, cancellation, caching and a
results UI belong to the later documentation milestone.

## License

GPL-3.0-or-later; see [LICENSE](LICENSE). Runtime dependencies retain their own
licenses. No upstream editor package source has been copied into this checkout.
