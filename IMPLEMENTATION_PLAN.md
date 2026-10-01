# Julia Workbench implementation plan

Status: milestones 1 through 3 completed on 2026-10-01. The isolated server
launcher, documentation prototype, real-server fixtures, editing major mode and
project-aware Eglot integration are implemented. Completion UI and Unicode CAPF
start at milestone 4; Doom migration remains pending until the replacement
passes its later milestones.

## Progress

- [x] 1. Server and documentation feasibility: LanguageServer 6.0.1 on Julia
  1.13.1; all six required protocol features exercised using Emacs 31.1.
  Completion, rename and formatting edits are applied and synchronized back
  to the server, including positions after BMP and astral Unicode characters.
  Documentation lookup/search covers Base, macros/operators, selected project
  packages, Unicode and missing docs. See [COMPATIBILITY.md](COMPATIBILITY.md)
  for the capability table, timings, limitations and exact reproduction commands.
- [x] 2. Dependable editing: `julia-workbench-mode`, `.jl`/shebang detection,
  tree-sitter font locking, indentation, Imenu, definition navigation and
  structural selection. Basic editing works without Julia, the grammar or a
  server; grammar installation is explicit. Fourteen ERT fixtures cover the
  installed Nix Julia grammar (0.25.0), Unicode, nested blocks/comments,
  literals/interpolation, incomplete code and both availability paths.
  See [README.md](README.md) for loading and reproduction commands.
- [x] 3. Eglot and project environments: nearest-project discovery with Julia
  filename precedence, explicit directory/file overrides and an isolated empty
  standalone fallback. Eglot workspace identities separate root, environment,
  executable and contact settings; user mappings and workspace configuration
  are preserved. Explicit asynchronous setup, reconnect, shutdown and doctor
  commands are available. Fifteen unit fixtures and a live two-project Eglot
  fixture cover isolation/sharing, package hover, Flymake, Xref, Unicode rename,
  formatting, process crashes and changed-environment reconnect. See
  [README.md](README.md) and [COMPATIBILITY.md](COMPATIBILITY.md).
- [ ] 4. Completion UI and Unicode CAPF (next).
- [ ] 5. Asynchronous documentation UI, search and caching.
- [ ] 6. Project REPL and evaluation.
- [ ] 7. Doom migration after validation.
- [ ] 8. Package and release validation.

## Goal and design

Build one independently usable Emacs package, tentatively named
`julia-workbench`, providing Julia editing, completion, documentation lookup and
search, standard LSP features, and a small REPL integration. Use a distinct
namespace so it cannot accidentally load the existing `julia-mode` package.

Use Emacs's built-in Eglot, CAPF, ElDoc, Xref, Imenu, project.el, process APIs,
and comint. Keep Doom-specific setup in an example configuration, outside the
package core. Corfu and Vertico should enhance the UI through standard Emacs
interfaces, without becoming package dependencies.

Full semantic support requires Julia and LanguageServer.jl, including its
upstream Julia dependencies. Full structural editing requires the Julia
tree-sitter grammar. Minimize dependencies by reusing these maintained
components rather than implementing a language server or another Julia parser.

Proposed baseline: Emacs 30.1+, Julia 1.11+, and LanguageServer.jl 6.0.1.
The selected server requires Julia 1.11, raising the original Julia 1.10 proposal.
Only Emacs 31.1 / Julia 1.13.1 has been exercised so far; test the minimum
versions before publishing. The checked-in tooling manifest records the exact
tested dependency graph.

## Current workspace and configuration

Verified on 2026-10-01:

- At plan creation this repository had no commits or implementation; preserve
  its `.gitignore`.
- Installed tools report Emacs 31.1 and Julia 1.13.1.
- `~/.config/doom` and `~/.doom.d` resolve to
  `/home/carjin/nixos/modules/features/editors/emacs/doom`.
- Doom enables `(corfu +icons +orderless)`, `(lsp +eglot)`, `lookup`, and
  `(julia +lsp +tree-sitter +snail)`; popup documentation is already enabled.
- The Julia module declares `julia-mode`, `julia-ts-mode`, `julia-repl`,
  `eglot-jl`, and `julia-snail`. `lsp-julia` is its alternative LSP backend.
- The user configuration contains custom Snail REPL/evaluation/documentation
  bindings, which need replacements during migration.
- Nix supplies `libtree-sitter-julia.so`. It loads successfully when Emacs uses
  `~/.config/emacs/.local/etc/tree-sitter`; a bare `emacs -Q` does not find it.
  Automatic grammar installation is disabled in the configuration.
- Julia reports a default v1.13 environment path, but its `Project.toml` is
  currently absent. Existing LanguageServer package sources do not establish
  that a compatible server can launch with the current executable.
- The Nix repository has unrelated dirty changes. Migration must preserve them.

## Package boundaries

Start with these files; split further only if the code warrants it:

| File | Responsibility |
| --- | --- |
| `julia-workbench.el` | Public configuration, major mode, syntax, tree-sitter editing, Unicode CAPF |
| `julia-workbench-eglot.el` | Project/environment resolution, server contact, lifecycle and setup diagnostics |
| `julia-workbench-doc.el` | Documentation lookup, search, results buffers and caching |
| `julia-workbench-repl.el` | Project-scoped comint sessions and evaluation commands |
| `julia/` | Minimal server launcher and standard-library-only documentation helpers, if needed |
| `test/` | ERT tests, Julia helper tests and small project fixtures |
| `examples/doom.el` | Doom completion, lookup, REPL, popup and keybinding integration |
| `README.md`, `LICENSE`, `Makefile` | Installation, compatibility, troubleshooting and reproducible checks |

Install-time assets must be included in the package recipe. Write caches and
server installations to configurable user-writable directories, never to the
package checkout or the Nix store.

## Implementation sequence

### 1. Prove server and documentation feasibility

- Launch the selected LanguageServer release with Julia 1.13.1 in an isolated
  tooling environment. Keep that environment separate from the project being
  analyzed, and pass the project environment explicitly.
- Use a tiny Julia project to inspect actual initialized capabilities and prove
  completion, hover, diagnostics, definitions, rename and formatting end to end.
- Prototype Julia's documentation lookup and `apropos` search using standard
  libraries. Check qualified names, macros, operators, loaded package docs,
  Unicode output and useful results when no documentation exists.
- Measure cold startup and warm requests. Establish the supported server/API
  contract before building UI around it.

Exit criterion: a reproducible compatibility fixture and capability table, with
any unsupported feature clearly identified.

### 2. Implement dependable editing

- Derive the mode from `prog-mode`; recognize `.jl` files and Julia scripts.
- Prefer built-in tree-sitter for font locking, indentation, Imenu, defun
  navigation and structural selection. Use the existing Nix grammar.
- Cover nested block comments, triple-quoted strings, interpolation, macros,
  Unicode identifiers, operators, transpose versus character literals, nested
  blocks and incomplete code with representative fixtures.
- Provide basic syntax/comment editing without a grammar, with an actionable
  explanation of how to enable full structural support. Avoid maintaining a
  second full Julia parser. Grammar setup is an explicit command.

Exit criterion: reliable editing fixtures and usable buffers even when Julia,
the grammar or the server is unavailable.

Implemented in `julia-workbench.el` and `test/editing-tests.el`. Editing checks
have their own `make check-editing` target; provide
`JULIA_WORKBENCH_GRAMMAR_PATH` to require structural tests with a system grammar.
Without one, those tests explicitly skip. The fallback preserves previous-line
indentation and provides lexical syntax, not structural parsing. Full
highlighting of interpolation containing nested string literals requires the
grammar. Incomplete-form indentation/navigation is best effort. Validation uses
Emacs 31.1; Emacs 30.1 and an interactive Doom session remain untested.

### 3. Integrate Eglot and project environments

- Resolve the nearest `JuliaProject.toml` or `Project.toml`, with Julia's
  filename precedence, explicit overrides and a defined standalone-file
  fallback. Keep project roots and active package environments distinct.
- Register the mode with language ID `julia`; avoid replacing unrelated server
  mappings or global Eglot workspace configuration.
- Respect user-configured server commands. Supply an asynchronous setup/update
  command for the isolated tooling environment, showing installation logs.
  Opening a source file should never silently install packages.
- Support project-local executable/environment settings, reconnect, shutdown,
  useful logs and a doctor command. Environment changes must invalidate the
  relevant caches and reconnect deliberately.
- Reuse Eglot's completion, ElDoc, Xref, diagnostics, formatting, rename and
  code-action paths. Advertise optional features such as inlay hints or type
  navigation only when both the selected server and client support them.

Exit criterion: two independent projects use the correct environments, share
connections appropriately, and recover cleanly from missing tools and crashes.

Implemented in `julia-workbench-eglot.el`, `test/eglot-tests.el` and
`test/eglot-integration-tests.el`. Run `make test-eglot` without Julia, or
`make check-eglot` with the explicitly installed server. The selected Julia
minor determines tooling/cache paths. Standalone environments are private,
empty and created only on connection; the default global environment is not
used. Reconnect invalidates runtime probes and invokes an environment-change
hook for later cache consumers. It resolves new settings rather than reusing
Eglot's saved arguments, and handles errors after forced server termination.

The live fixture runs in Emacs 31.1 / Julia 1.13.1 with LanguageServer 6.0.1;
its protocol/stderr logs are retained under `test/results/eglot`. A separate
noninteractive run verified actual asynchronous setup in a temporary tooling
directory, using already installed dependencies in offline mode. Setup stdout,
stderr, duplicate-job rejection and nonzero exits also have unit fixtures.
Batch fixtures trust only their generated directory, start Flymake explicitly,
and use a POSIX shell for project.el file listing. The doctor reports content
trust and shell settings without altering them. Interactive Doom validation,
remote custom contacts and minimum-version validation remain pending.

Environment overrides select the server's active environment argument;
LanguageServer 6 still applies its own per-file workspace/package environment
resolution. The adapter does not replace that upstream policy or set global
workspace options. Optional inlay hints and absent type-definition support are
reported as capabilities, not interactive feature validation.

### 4. Deliver first-class completion

- Use Eglot CAPF for semantic completions, including qualified names, imports,
  macros and available argument information/documentation.
- Add Julia's backslash Unicode/LaTeX and emoji input through a separate CAPF,
  using version-matched Julia data cached outside the checkout.
- Compose CAPFs so Unicode, semantic and path completion do not mask each
  other. Preserve server-provided edit ranges, ordering and annotations.
- Exercise completion insertion and documentation in the user's Corfu UI,
  including trigger characters, Unicode positions and incomplete expressions.
- Handle optional snippet completions according to the actual Eglot/UI
  capabilities; do not require a snippet package for ordinary completion.

Exit criterion: successful, correctly positioned insertions and readable popup
documentation in both standard Emacs completion and Doom/Corfu.

### 5. Deliver documentation lookup and search

- Offer documentation at point through ElDoc and a persistent help buffer.
- Add named-symbol lookup with completion and a separate documentation search
  command that searches docstring text, not just workspace symbol names.
- Display search results in a navigable buffer with symbol lookup buttons,
  readable signatures/examples, history and useful empty/error states.
- Use Julia documentation APIs and `apropos` in an asynchronous, project-aware
  helper when LSP cannot supply arbitrary-symbol or full-text search. Initially
  use bounded helper jobs with argument-vector inputs and captured output;
  avoid a custom persistent RPC service unless measured latency demands it.
- Cover Base, standard libraries and explicitly selected/loaded project
  packages. Show the search scope: docs for unimported packages are not
  automatically available. Never import every dependency on opening a file.
- Cache results by executable/version, environment, package selection and
  relevant project/manifest changes; provide refresh, cancellation and cleanup.
- Add an optional official Julia manual search using built-in browsing tools.
  Local documentation should work offline once packages are installed.

Exit criterion: name lookup and text search both work, a dependency's docs can
be included explicitly, and a slow helper does not block typing.

### 6. Replace the existing REPL workflow

- Provide a built-in comint REPL per project/environment, with history,
  interrupt, restart and clear process status.
- Support send line, region, current top-level form, buffer/file and DWIM;
  preserve filenames and line information where practical.
- Provide explicit project activation and copying the last evaluation result.
  Use structured syntax for top-level selection rather than regex guesses.
- Keep runtime evaluation separate from static LSP analysis. Documentation
  helper processes do not implicitly share user REPL state.
- Include basic runtime documentation/completion where feasible using Julia
  standard libraries. Snail's multimedia display and debugger integration are
  outside this initial release; document those limits explicitly.

Exit criterion: the user's existing core Snail keybindings have functioning
replacements before Snail is removed from the configuration.

### 7. Migrate Doom after the replacement passes

- Prepare the exact scoped diff for
  `/home/carjin/nixos/modules/features/editors/emacs/doom/{init,packages,config}.el`
  before applying the migration.
- Disable the built-in Julia module and remove the Snail-specific configuration.
  Remove/disable Julia editor package declarations if still selected elsewhere:
  `julia-mode`, `julia-ts-mode`, `julia-repl`, `eglot-jl`, `julia-snail`, and
  `lsp-julia` if present. Retain the Julia runtime and shared Emacs facilities.
- Declare the new package from this local checkout for development, with all
  helper assets included. Document a revision-pinned Git recipe for release.
- Wire Doom's lookup/documentation/REPL handlers, localleader mappings, format
  integration and popup rules to the new package.
- Inspect the actual syntax-checker backend before choosing the integration:
  plain Emacs uses Flymake; Doom should use its existing Eglot diagnostics path
  without duplicate diagnostic producers or global checker changes.
- Run targeted `doom sync`, inspect the resulting package graph and open Julia
  fixtures in a fresh Doom process. Preserve unrelated dirty package checkouts.
  Do not delete old repositories or Julia package depots merely to migrate.

Exit criterion: `.jl` files select the new mode, the previous Julia integrations
are inactive, and completion, lookup, diagnostics and evaluation work in Doom.

### 8. Package and validate for maintenance

- Provide package headers, lexical binding, autoloads, documented customization
  variables and a license compatible with any reused upstream code.
- Prefer public Emacs APIs. Isolate unavoidable version-sensitive Julia or
  Eglot calls in small adapters with explicit compatibility tests.
- Run ERT, Julia helper tests, byte compilation, `checkdoc`, and diff checks.
  Keep lint-only tooling optional; basic checks use built-in facilities.
- Add integration tests with the real selected server, including Unicode edit
  positions, project isolation, rename edits and restart/error recovery.
- Record cold/warm startup and completion/doc-search responsiveness separately.
  Verify cancellation, stale results, timeouts and process cleanup.
- Test the declared minimum Emacs version and the installed Emacs 31.1;
  document which Julia versions were actually exercised.

Deliverables: installable package, reproducible checks, compatibility/feature
table, vanilla Emacs and Doom examples, migration diff, and separate records of
automated checks and actual Doom runtime validation.

## Upstream references

- [Eglot manual](https://www.gnu.org/software/emacs/manual/html_node/eglot/)
- [LanguageServer.jl installation and launch](https://github.com/julia-vscode/LanguageServer.jl)
- [LanguageServer capability initialization](https://github.com/julia-vscode/LanguageServer.jl/blob/main/src/requests/init.jl)
- [Julia documentation system](https://docs.julialang.org/en/v1/manual/documentation/)
- [Julia REPL completion and help](https://docs.julialang.org/en/v1/stdlib/REPL/)
- [Julia documentation search utilities](https://docs.julialang.org/en/v1/stdlib/InteractiveUtils/)
