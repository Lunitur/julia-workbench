# Julia Workbench

A Julia Emacs package under development. Editing, project-aware Eglot integration,
semantic/path/Unicode completion and asynchronous documentation lookup/search
are implemented. Project REPL integration follows in
[IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md).

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

## Completion

Run `M-x julia-workbench-setup-unicode` once to asynchronously export the selected
`julia-workbench-julia-command` runtime's LaTeX and emoji input table. This uses
Julia's REPL standard library, installs no packages and writes a validated cache
under `julia-workbench-cache-directory` (default
`${XDG_CACHE_HOME:-~/.cache}/julia-workbench/unicode/`). Export logs appear in a
setup buffer. Cancel with `M-x julia-workbench-cancel-unicode-setup`; failures,
timeouts and cancellation preserve any previous cache. Customize
`julia-workbench-unicode-setup-timeout` for a slower runtime.

Use `M-TAB` (`completion-at-point`) on `\alpha`, `\_2`, `\hat` or `\:smile:`
to insert `α`, `₂`, a combining circumflex or `😄`. Partial inputs offer candidates
with glyph annotations; accepting a candidate converts it to Unicode. Inputs
work in code, comments and strings, without Eglot. Corfu's documentation popup
shows the input name, Julia version and each character's Unicode name/code point.
The data comes from the installed Julia runtime, matching its
[Unicode input and REPL completion](https://docs.julialang.org/en/v1/stdlib/REPL/#Tab-completion)
tables rather than a separately maintained editor copy.

Caches are tied to the executable's resolved path, size and modification time;
the export records the full Julia version. Repeat setup after changing a runtime
behind an unchanged launcher script (for example a version-manager wrapper).
Missing/corrupt data leaves other completion providers available. Opening a
buffer and invoking completion never launch Julia. Helpers and caches work
locally; remote completion still needs a custom semantic server contact.

With Eglot connected, semantic candidates, annotations, ordering, documentation
and edit ranges come directly from its CAPF. Unicode and path providers run
before it and decline other contexts, preserving unrelated buffer-local CAPFs.
Paths complete in plain double-quoted strings, relative to `default-directory`,
including spaces and continuation into directories. Strings containing escapes
or interpolation are left to the semantic provider. No completion UI is required;
Corfu and its popupinfo extension consume the ordinary CAPF properties.

For optional Corfu use in vanilla Emacs, after installing it separately:

```elisp
(add-hook 'julia-workbench-mode-hook #'corfu-mode)
(with-eval-after-load 'corfu
  (require 'corfu-popupinfo)
  (corfu-popupinfo-mode 1))
```

Ordinary completions need no snippet package. Eglot advertises snippet support
according to its available expansion backend; Workbench preserves that behavior.
The tested server provides plain-text completion edits. Qualified names, named
imports, macros, dot triggers and incomplete expressions have live tests.
Package-name completion remains subject to the server: it did not offer the
fixture package for `using WorkbenchEx`, although `using Base: sin` offered `sinh`.
Argument signatures use Eglot's ElDoc provider.

```sh
make test-completion          # Unit tests; Julia and Corfu not required
make check-completion         # Also real Julia/Eglot, byte compilation and lint
# Optional actual child-frame checks in a separate graphical Emacs:
make test-corfu-ui CORFU_LOAD_PATH="/path/to/corfu /path/to/corfu/extensions /path/to/compat"
```

The GUI tests have also passed with this user's existing Doom/Corfu/Orderless
configuration loaded in a fresh process. They create actual completion and
documentation child frames and accept semantic, Unicode/emoji and file
candidates, including after BMP/astral text. Logs are retained in
`test/results/corfu/` and `test/results/corfu-doom/`. These are automated GUI
checks; a manual keyboard session and the later Doom migration remain separate.
To repeat the current Doom check without changing its configuration:

```sh
JULIA_WORKBENCH_CORFU_RESULTS=corfu-doom \
  emacs --init-directory "$HOME/.config/emacs" -L . -L test \
  --eval '(setq load-prefer-newer t)' -l test/completion-corfu-tests.el \
  --eval '(run-at-time 2 nil (function workbench-corfu-run))'
```

## Eglot and environments

In a Julia buffer, run `M-x julia-workbench-setup-server` once to explicitly
install the pinned tooling environment. Installation runs asynchronously in a
visible log buffer; opening files never installs packages. Repeat setup to
restore the supported dependency lock. Cancel with `M-x kill-process` in its
log buffer. Existing unrelated tooling environments are not overwritten.

Run `M-x julia-workbench-connect` to start Eglot. Semantic completion, ElDoc,
Xref definitions/references, Flymake diagnostics, `eglot-rename`,
`eglot-format-buffer` and code actions use Eglot's standard interfaces.
Inlay hints require an advertised provider and an available
`eglot-inlay-hints-mode`; the tested server advertises them. Type-definition
navigation is not advertised by this server. These observations do not claim
interactive validation of every optional feature.

For automatic connections, explicitly opt in:

```elisp
(require 'julia-workbench-eglot)
(add-hook 'julia-workbench-mode-hook #'eglot-ensure)
```

The ordinary project.el workspace root (for example a Git repository) stays
separate from the nearest Julia environment. The nearest directory containing
`JuliaProject.toml` or `Project.toml` supplies the analyzed environment;
`JuliaProject.toml` wins when both exist. Buffers share a connection only when
workspace, environment, executable and server settings agree. A nested `test/`
environment therefore gets a separate connection within the same repository.
Without a Julia project, standalone files use a private empty environment under
the Workbench cache, per workspace and Julia minor version. It is created only
on connection, and does not use or modify Julia's default global environment.

Set project options with directory-local variables, for example:

```elisp
((julia-workbench-mode
  . ((julia-workbench-julia-command . "/path/to/julia")
     (julia-workbench-environment . "test")
     (eglot-workspace-configuration
      . (:julia.symbolCacheDownload :json-false)))))
```

Relative environment paths use the workspace root. Explicit paths can name a
directory or a project file. Executable/contact settings use Emacs's ordinary
local-variable approval; they are not declared safe. The package registers only
its own mode with language ID `julia`, preserves existing Eglot mappings, and
does not set global workspace configuration. A user `eglot-server-programs`
entry takes precedence; otherwise `julia-workbench-server-command` can supply a
custom contact (including a function of INTERACTIVE and PROJECT) and bypass the
bundled launcher's Julia/tooling checks. The bundled launcher supports local
projects; remote use requires a custom contact and remains untested.

Use `M-x julia-workbench-reconnect` after changing environment/executable settings
or project/manifest files. This deliberately shuts down the shared old connection,
invalidates runtime probes, and resolves the new contact. Other buffers can
reconnect using their own settings. `eglot-reconnect` instead reuses Eglot's saved
contact. `M-x julia-workbench-shutdown` retains server logs;
`M-x julia-workbench-doctor` reports settings, missing tools, status and log names.
Use `eglot-events-buffer` / `eglot-stderr-buffer` for detailed logs. Eglot's own
`eglot-autoreconnect` setting controls automatic recovery after a crash.

Customize `julia-workbench-cache-directory`, `julia-workbench-server-project`,
and `julia-workbench-symbol-cache` for writable locations. The latter two also
honor the matching `JULIA_WORKBENCH_*` environment variables. Setup and connection
use the same versioned paths for the selected Julia executable. Neither command
installs dependencies into the analyzed project.

```sh
make test-eglot              # Environment/unit tests; Julia not required
make check-eglot             # Also exercise real Eglot/server buffers and lint
```

The integration fixture checks two environments, sibling connection sharing,
Flymake, Unicode rename edits, formatting, Xref, package hover, crashes and
reconnection with changed settings. Logs are retained under `test/results/eglot`.
Test fixtures explicitly use a POSIX shell for project.el file listing and start
Flymake directly because batch Emacs has no interactive command loop. The
generated fixture directory alone is trusted for the tests. If Flymake disables
its backend in your session, inspect `trusted-content`; the package leaves that
setting to Emacs. Completion GUI checks are described above; full Doom migration
validation remains a later milestone.

An environment override selects the server's active environment argument.
LanguageServer 6 still applies its own per-file workspace/package resolution;
the adapter preserves that upstream policy. Use Julia lint configuration for
lint rules, and Eglot's project-local workspace settings for supported server
options. Dotted configuration sections such as `:julia.symbolCacheDownload`
match the server's actual requests; a nested `:julia` plist does not.

## Reproducible checks

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

## Documentation

Julia buffers provide these commands:

| Command | Binding | Behavior |
| --- | --- | --- |
| `julia-workbench-documentation-at-point` | `C-c C-d` | Persistent Eglot hover when connected; otherwise project-aware helper lookup |
| `julia-workbench-documentation` | `C-c C-h` | Named-symbol lookup with ordinary `completing-read` completion |
| `julia-workbench-documentation-search` | `C-c C-s` | Literal search through docstring text |
| `julia-workbench-documentation-select-packages` | `M-x` | Explicitly select project packages or standard libraries for helper documentation |
| `julia-workbench-documentation-manual-search` | `M-x` | Optional official Julia manual search in your browser |

Named lookup asynchronously builds its name index before prompting on first
use. Subsequent prompts reuse the validated index. If another minibuffer is
active when indexing finishes, results appear in the help buffer; invoke named
lookup again to choose a symbol. Completion accepts arbitrary names as well as
indexed names, including `Base.sin`, `Base.@time`, `Base.+` and `π`.

The persistent `*Julia Documentation*` buffer shows environment, runtime and
loaded-documentation scope, with readable Markdown signatures/examples. Search
results are buttons: `n`/`p` navigate and `RET` opens a symbol in the same captured
scope. Use `l`/`r` for help history, `g` to refresh, `c` to cancel, and `q` to quit
the window. Refresh bypasses the cached response and resolves current source
settings. New requests supersede older ones; history stores rendered snapshots.

Helpers always use the source buffer's selected Julia environment. To include
a dependency's docs, run `M-x julia-workbench-documentation-select-packages` and
enter names such as `Dates, MyPackage`, or set buffer-local
`julia-workbench-documentation-packages`. Selection itself loads nothing.
The helper starts only for an explicit request and loads the selected packages
using Julia's ordinary loading API. Their initialization runs in that separate
process; their transitive loads also contribute documentation. It neither imports
every dependency nor shares your REPL's state. Standalone files use a private
empty environment under the cache; helpers exclude the default global environment
from Julia's load path. Installed packages suffice for offline local lookup/search.

Opening files and ElDoc never launch documentation workers. Connected buffers
retain Eglot's hover/signature providers; persistent help also uses the server
for local definitions that a fresh helper cannot know. Unconnected buffers offer
previously cached helper lookups through ElDoc. Named lookup and full-text search
always use helpers, independent of the language server.

Caches live under `julia-workbench-cache-directory` in `documentation/`. Keys
include resolved executable identity, environment, selected packages, helper
content and contents of project/manifest files, including versioned manifests.
Results record the Julia version and use validated data, never executable Lisp.
Refresh after editing package sources or changing a runtime behind an unchanged
wrapper. Failed/cancelled refreshes preserve prior cache files. Missing or corrupt
caches trigger a fresh helper only on an explicit request.

Workers run asynchronously with captured stdout/stderr, a 30-second default
timeout, an 8 MiB output bound and at most four concurrent jobs. Customize
`julia-workbench-documentation-timeout`, `julia-workbench-documentation-max-output`
and `julia-workbench-documentation-max-jobs` for larger projects. Source-setting
changes reject stale results; killing the help buffer or exiting Emacs terminates
its workers. Failures identify a retained stderr log buffer. Local helpers and
caches do not support remote projects; a custom Eglot contact can still supply
persistent hover without a local Julia executable.

```sh
make test-documentation             # ERT unit checks, no Julia needed
make test-documentation-integration # Actual Julia helpers, no server needed
make check-documentation            # Also Julia assertions, live Eglot and lint
```

These checks exercise real help/search buffers and asynchronous process APIs in
batch Emacs. Manual keyboard/Doom documentation validation is pending; no Doom
configuration changes are included. See [COMPATIBILITY.md](COMPATIBILITY.md) for
measured worker/cache latency and validation boundaries.

### Standalone helper CLI

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
returns structured results, while the default CLI emits human-readable UTF-8
text. The Emacs adapter passes `--protocol` to request versioned, base64-encoded
UTF-8 fields and uses `names ''` for its documented-symbol completion index.

## License

GPL-3.0-or-later; see [LICENSE](LICENSE). Runtime dependencies retain their own
licenses. No upstream editor package source has been copied into this checkout.
