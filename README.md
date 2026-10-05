# Julia Workbench

A Julia Emacs package under development. Editing, project-aware Eglot integration,
semantic/path/Unicode completion, asynchronous documentation lookup/search and
project REPL/evaluation with native SVG/PNG plotting are implemented.
A Doom integration example and scoped
migration patch are available; migration status is tracked in
[IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md).

The namespace is `julia-workbench`. The proposed Doom migration is separate
from installing the independently usable package.

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
Imenu labels include declared argument and return types, `where` constraints
and symbol kinds. This also works with Eglot's Imenu and frontends such as
Consult. Workspace symbol search (`M-x xref-find-apropos`) shows the same
declaration details and keeps Eglot's original jump locations. Source declarations
provide the types; untyped arguments have no inferred type added. Without the
grammar, connected symbol navigation still shows the server's symbol kinds.
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
and edit ranges come from its CAPF. A small adapter adds available signatures
to candidate documentation and echoes them after acceptance. With the grammar,
local declarations provide typed signatures even when a function has no
docstring. Unicode and path providers run before it and decline other contexts,
preserving unrelated buffer-local CAPFs.
Paths complete in plain double-quoted strings, relative to `default-directory`,
including spaces and continuation into directories. Strings containing escapes
or interpolation are left to the semantic provider. No completion UI is required;
Corfu and its popupinfo extension consume the ordinary CAPF properties.

When Corfu is installed, Julia buffers enable it automatically: completion opens
after two characters and a 0.2-second pause, with Eglot's dot and macro triggers
also supported. Installed `corfu-popupinfo` shows documentation and signatures
as you select a candidate. These settings apply only to Julia buffers. Set
`julia-workbench-automatic-completion` to nil before opening a buffer to keep
your own UI configuration. No completion UI is installed by the package.

For manual Corfu configuration instead:

```elisp
(setq julia-workbench-automatic-completion nil)
(add-hook 'julia-workbench-mode-hook
          (lambda () (setq-local corfu-auto t) (corfu-mode 1)))
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
While filling function arguments, Eglot's ElDoc provider displays method
signatures and highlights the active argument after `(` and `,`.

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
batch Emacs. Manual keyboard validation is pending; graphical Doom documentation
checks are recorded in the migration section below. See [COMPATIBILITY.md](COMPATIBILITY.md) for
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

## Project REPL and evaluation

In a Julia buffer, `C-c C-z` (`julia-workbench-repl`) starts or shows the project's
comint REPL. Calling it in the REPL switches back to the last source buffer.
Startup is asynchronous and installs nothing. Sessions share only when workspace,
selected environment, resolved Julia executable and
`julia-workbench-repl-arguments` agree. The environment uses the same nearest
project and `julia-workbench-environment` override as Eglot. Standalone files get
a private empty environment under the writable cache, with no global-environment
package fallback. A missing executable/project produces an actionable error.

The REPL header shows the Julia version, starting/idle/busy/stopped status,
queued evaluations and selected environment. `RET` evaluates complete input;
`C-j` adds a newline for a multiline form. `M-p` / `M-n` navigate comint history,
which persists under `repl-history/` in `julia-workbench-cache-directory` and
preserves multiline entries after restart. Startup files and Julia's terminal
history are disabled; comint owns input/history and uses a plain-text frontend.

| Source command | Default key | Behavior |
| --- | --- | --- |
| `julia-workbench-send-line` | `C-c C-l` | Current line |
| `julia-workbench-send-region` | `C-c C-r` | Selected source |
| `julia-workbench-send-dwim` | `C-c C-c` | Active region, otherwise structured top-level form |
| `julia-workbench-send-top-level-form` | — | Containing top-level syntax node, including a surrounding module |
| `julia-workbench-send-buffer` | `C-c C-b` | Whole buffer, including unsaved edits and narrowed-out text |
| `julia-workbench-send-buffer-file` | `C-c C-f` | Include the saved file; modified buffers require saving or send-buffer |
| `julia-workbench-copy-last-eval-result` | — | Copy the last successful value's plain-text rendering |
| `julia-workbench-repl-activate-project` | — | Restore the session's selected project through `Pkg.activate` |
| `julia-workbench-repl-interrupt` | REPL `C-c C-c` | Interrupt current work and cancel queued evaluations |
| `julia-workbench-repl-restart` | REPL `C-c C-r` | Start a fresh runtime, retaining transcript and history |

Source evaluation uses Julia's include APIs in `Main`, with REPL soft-scope
behavior. Filenames and source line offsets survive region/line evaluation;
saved-file and buffer evaluation support relative `include` and `@__DIR__`.
Requests encode source as UTF-8 data, so quotes, backslashes, dollar signs and
Unicode do not alter the transport. Ordinary printed output remains visible.
Result copying excludes stdout, errors and prompts, keeps semicolon-suppressed
values, and preserves the previous successful result after an error. Copied
renderings are bounded to 65,536 characters and may be marked truncated.

Top-level selection and DWIM without a region require the Julia tree-sitter
grammar and reject incomplete forms. Line, region and buffer/file commands work
without it. Evaluation is explicit and unrestricted Julia code. Long evaluations
have no automatic timeout; interrupt or restart them explicitly. The default
startup deadline is 30 seconds and at most 32 evaluations can be outstanding.
Customize `julia-workbench-repl-startup-timeout` and
`julia-workbench-repl-queue-limit` when needed. Killing a REPL buffer or exiting
Emacs saves history and stops its process; a crashed session can be started again.

`julia-workbench-repl-documentation` asynchronously looks up a named binding in
the live `Main` module, including evaluated definitions and loaded packages, and
shows a separate runtime help buffer. In the REPL use `C-c C-d`.
`julia-workbench-repl-complete` explicitly requests standard-library runtime
completion (`M-TAB` in the REPL), applying character-correct edits even after
Unicode. In source buffers it completes the current line prefix. Results are
inserted only while the source text and point are unchanged. Method-list-only
results are reported as having no insertable completions; candidates are bounded
to 1,000 and the response size limit. Neither command starts a missing REPL.
Queries preserve Julia's `ans` and do not replace Eglot's CAPF.

Runtime evaluation, LSP analysis and documentation helper processes have separate
state. A helper cannot see functions defined only in the REPL; use runtime lookup
for those. Changing source environment/options selects a different session;
restart deliberately after changing runtime wrappers or project dependencies.
Manual `Pkg.activate` affects the runtime alone; explicit activation restores
the selected session environment and does not reconnect Eglot or install packages.

The REPL evaluates in `Main` and supports native SVG/PNG plots as described below.
Debugger, automatic module-context tracking and terminal help/shell/Pkg modes
are outside its scope.
Use runtime lookup, ordinary Julia calls and `import Pkg; Pkg.add(...)` explicitly.
Remote REPLs are not supported. The Doom migration preserves the core
evaluation/activation/result-copy workflow using the new commands.
Runtime completion reads current bindings, requiring no
Snail-style module-cache refresh.

```sh
make test-repl             # Unit fixtures; no Julia required
make test-repl-helper      # Julia standard-library adapter assertions
make test-repl-integration # Real asynchronous comint sessions, no server needed
JULIA_WORKBENCH_GRAMMAR_PATH="$HOME/.config/emacs/.local/etc/tree-sitter" \
  make check-repl          # Also structured evaluation, byte compilation and lint
```

Logs and elapsed measurements are retained in `test/results/repl/`. These are
automated batch interactions with real Julia processes. Doom REPL/evaluation
dispatch also passes the graphical migration fixtures below; manual keyboard
validation remains pending.

## Native plot pane

New REPL sessions capture SVG/PNG-capable Julia values in a dedicated Emacs pane.
Plots use the same runtime and loaded packages as source/REPL evaluation, with no
Jupyter dependency. Workbench installs no plotting libraries. For example, in a
project where Plots.jl is already available:

```julia
using Plots
p = plot(1:5, [1, 4, 2, 5, 3])  # Returning a plot displays it automatically.
p;                             # A trailing semicolon suppresses automatic display.
display(p)                     # Explicit display works, including inside loops.
display("image/png", p)        # Request a particular supported format.
```

CairoMakie and other libraries implementing Julia's `image/svg+xml` or
`image/png` MIME output can use the same display bridge. Browser widgets,
interactive axes and 3D rotation are not provided by this static image pane.
Image zoom changes magnification, not the plot's coordinate limits.

The pane appears to the right without selecting it. `C-c C-p` in source or the
REPL (`julia-workbench-show-plots`) selects the existing history without starting
Julia. In the pane, use `n`/`p` for next/previous, `+`/`-` for image zoom, `f` to
fit to the current window, `s` to save the original image bytes, and `q` to close
the window. The Doom integration keeps Evil normal state active, with `h/j/k/l`
scrolling the image viewport, `C-d`/`C-u` scrolling half pages and `C-f`/`C-b`
scrolling full pages. Zoom in first if the fitted image fills the pane.
Use the usual `C-w h/j/k/l` or Doom `SPC w` commands to switch windows.
The viewer keys above have explicit normal-state bindings in this pane.
Saving preserves the original SVG/PNG format; it does not convert
formats based on the destination's extension. Closing or killing the pane
preserves history; use `C-c C-p` to reopen it.

Configure these variables before starting a session:

- `julia-workbench-plot-enabled` (default `t`): disable for text-only evaluation.
- `julia-workbench-plot-formats` (default `(svg png)`): MIME preference, filtered
  by this Emacs build's image support. Use `(png svg)` for raster-heavy figures.
- `julia-workbench-plot-max-bytes` (default 16 MiB): largest accepted plot file.
- `julia-workbench-plot-history-limit` (default 20): retained plots per session;
  older files are deleted. At least one plot is retained.

The enabled formats and byte limit form part of the REPL identity. Changed
preferences select a different session; the history limit applies as new plots
arrive. Images live in private session directories under the writable Workbench
cache, separate from bounded text result records. Plot notifications do not
finish an evaluation or replace the copyable plain-text result. Returned-value
render failures print a diagnostic and fall back to text. Explicit `display`
errors follow ordinary Julia evaluation error handling.

A terminal Emacs client retains plot files when its build supports the formats;
`C-c C-p` shows their paths and supports export. A graphical client is required
for images. Restarting or killing a REPL removes its pane and cached figures.
A stopped/crashed process retains its history until restart or buffer cleanup.
Native plot sessions default GR to its null workstation (`GKSwstype=100`) before
loading plotting packages. This prevents GR from launching its Qt viewer even
while rendering SVG/PNG. Explicit `GKSwstype`/`GKS_WSTYPE` environment settings
are respected. For GR's external GUI workflow, disable native plotting before
starting a separate session, or explicitly configure its workstation.

```sh
make check-plots    # Protocol/history tests, Julia helper, live REPL and lint
make test-plot-ui   # Separate graphical Emacs: actual SVG rendering and zoom
# Optional real Plots.jl/GR validation, using an existing project:
JULIA_WORKBENCH_PLOT_PROJECT=/path/to/project make test-plot-ui
# Check actual pane keys under the installed Doom configuration:
JULIA_WORKBENCH_PLOT_PROJECT=/path/to/project make test-doom-plot-ui
```

The optional UI tests install nothing. Logs and an optional frame image are
retained under `test/results/plots/`. Plots.jl/GR is exercised in that optional
fixture, including detection of attempted Qt viewer launches; CairoMakie and
other plotting backends are not separately validated.

## Doom migration

The exact applied change to this user's Nix-managed Doom configuration is in
[examples/doom-migration.patch](examples/doom-migration.patch). It disables
`:lang julia`, replaces the Snail configuration with
[examples/doom.el](examples/doom.el), and declares this checkout in `packages.el`:

```elisp
(package! julia-workbench
  :recipe (:type nil :local-repo "/home/carjin/projects/julia-mode"
           :files ("julia-workbench*.el" "julia")))
```

The `julia` directory includes all helpers and the tooling Project/Manifest.
Caches, installed servers and history remain in writable user directories.
After release, replace the local recipe with a Git recipe pinned to a full
release commit. These placeholders must be filled with the published repository
and revision; no release repository exists yet:

```elisp
(package! julia-workbench
  :recipe (:type git :repo "https://github.com/OWNER/REPOSITORY.git"
           :files ("julia-workbench*.el" "julia"))
  :pin "FULL_RELEASE_COMMIT")
```

The example preserves the existing localleader evaluation keys and registers
Doom's REPL and evaluation handlers. `SPC m d` and Doom's documentation lookup
use persistent, asynchronous help, including after Eglot connects. `SPC m D`
selects a named binding; `SPC m s` searches documentation text. `SPC m u` now
requests live runtime completion: this REPL has no Snail module cache to update.
`SPC m c` explicitly connects Eglot and `SPC m C` reconnects it. Opening a file
does not start Julia. Doom's existing LSP formatter handles formatting after
connection, including its configured format-on-save behavior.

This user's `:checkers syntax` module selects Flycheck. Doom's existing
`flycheck-eglot` bridge consumes Eglot diagnostics, with Flymake disabled in
managed buffers. The example adds no checker or global diagnostic setting.
ESS also claims Julia extensions after `:lang julia` is disabled; the example
registers an explicit case-insensitive Julia mode mapping after module config.
R/ESS and shared Eglot configuration are retained.

Preview the patch before applying it, using a copied configuration and copied
Doom package data. A graphical display and this user's already installed Doom,
Julia, server and grammar are required:

```sh
make preview-doom
```

[examples/preview-doom.sh](examples/preview-doom.sh) applies the patch to a new
directory under `test/results/doom-migration/`, runs `doom sync -U -B`, then
opens fresh graphical Doom processes for the integration and Corfu fixtures.
It sets `DOOMDIR`, `DOOMLOCALDIR` and
`DOOMPROFILELOADFILE` to preview paths; the active configuration, package
checkouts and daemon are preserved. Preview data is retained for inspection.
Reflinks reduce the copy size when the filesystem supports them. A config
that already contains the exact migration is previewed without reapplying it;
other divergence must be reviewed before retrying.

To apply the patch to an unmigrated configuration and sync without updating
unrelated packages:

```sh
git -C /home/carjin/nixos apply --check /home/carjin/projects/julia-mode/examples/doom-migration.patch
git -C /home/carjin/nixos apply /home/carjin/projects/julia-mode/examples/doom-migration.patch
doom sync -U
make test-doom-ui
make test-doom-corfu-ui
```

`test-doom-ui` deliberately uses the installed package without adding this
checkout to `load-path`. Its fixtures check the package graph, helper assets,
extension/shebang selection, parsing, localleader keys, Doom REPL/evaluation
dispatch, Flycheck diagnostics, documentation popup, formatting and semantic
completion after Unicode. Logs are in `test/results/doom-migration/ui.log`.
`test-doom-corfu-ui` also uses the installed package and tests actual completion
and documentation child frames; logs are in `test/results/corfu-doom-migration/`.
All four installed-package Doom fixtures and all three Corfu GUI fixtures passed
in the isolated migration preview on 2026-10-02 with Emacs 31.1 / Julia 1.13.1.
The preview also caught and
fixed a documentation bug when Doom selects the help popup before hover request
parameters are built; the request now retains its source buffer. Event logs use
an explicit encoding to preserve raw bytes without opening a coding prompt.
After explicit approval on 2026-10-02, the patch was applied to the active
configuration and `doom sync -U` succeeded. Both suites passed again against
the installed active package. The running daemon was preserved; restart Emacs
to load the migrated configuration there. Manual keyboard validation and
minimum-version checks remain separate.

## License

GPL-3.0-or-later; see [LICENSE](LICENSE). Runtime dependencies retain their own
licenses. No upstream editor package source has been copied into this checkout.
