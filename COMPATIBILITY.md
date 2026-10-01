# Feasibility baseline

Recorded 2026-10-01 on Linux/NixOS. Milestones 1 through 6 are complete; editing,
project-aware Eglot, completion, documentation and REPL/evaluation can be loaded
from this checkout. Automated
completion GUI checks pass in vanilla Emacs and the current Doom configuration.
Manual keyboard validation and the complete Doom migration are still pending.

## Exercised combination

| Component | Version / evidence |
| --- | --- |
| Emacs | 31.1, clean `emacs -Q --batch`, built-in JSON-RPC and ERT |
| Julia | 1.13.1, `--startup-file=no` |
| LanguageServer.jl | 6.0.1, exact project compatibility pin |
| JuliaWorkspaces.jl | 13.4.3 |
| JSONRPC.jl | 3.1.0 |
| JuliaFormatter.jl / Runic.jl | 2.14.0 / 1.11.1 |
| Julia tree-sitter grammar | Nix `tree-sitter-julia-0.25.0`, existing system library |
| Dependency graph | `julia/server-environment/Manifest.toml`, Julia manifest format 2.1 |

Emacs 30.1 and Julia 1.11 are proposed minimums, **not tested combinations**.
LanguageServer 6.0.1's Julia requirement is 1.11+, so the original proposed
Julia 1.10 baseline is unavailable with this server release. Julia 1.11/1.12,
their manifest handling and other operating systems remain to be exercised.

## Editing validation

Fourteen ERT tests cover `.jl` and Julia shebang selection, basic editing with
no external executables or grammar, missing-grammar recovery guidance, nested
block/line comments, triple and prefixed strings, command/character literals,
escaped Unicode characters, adjoints, interpolation, macros/operators and
Unicode identifiers. With the Nix grammar, they check font-lock queries and
faces, exact nested indentation and custom offsets, preservation of multiline
text, Imenu (including qualified short-form methods), definition navigation,
selection expansion and continued editing of incomplete code. Structural tests
run with `exec-path` empty as well; editing has no Julia/server dependency.

Run the structural suite explicitly:

```sh
JULIA_WORKBENCH_GRAMMAR_PATH="$HOME/.config/emacs/.local/etc/tree-sitter" \
  make check-editing
```

Without a discoverable grammar, six basic tests run and eight structural tests
report skips. An invalid explicit grammar path fails before tests run. Grammar
installation is an explicit command and was not exercised: these checks reuse
the installed Nix library. Basic indentation copies the previous line; structural
selection requires the grammar. The lexical fallback does not parse nested
string literals inside interpolation. Incomplete-form indentation/navigation is
best effort. Interactive Doom validation and the declared Emacs minimum remain
pending.

## Completion validation

Thirteen ERT unit fixtures cover standard Emacs Unicode insertion, emoji,
combining marks, subscripts/fractions, annotations and code-point documentation,
code/comment/string contexts, escaped inputs, no runtime on open/completion,
malformed caches, executable replacement, file paths/spaces/directories,
provider ordering, actual asynchronous exports through fake runtimes, failures,
cancellation, duplicate jobs, timeouts and preservation of a good cache.
Nine Julia assertions compare the helper export to both complete runtime tables.
Julia 1.13.1 provides 2,550 LaTeX and 1,242 emoji inputs, 3,792 combined.

The live Eglot fixture runs the public asynchronous export with actual Julia,
checks the resulting cache, then accepts Unicode in a managed buffer. Standard
completion selection applies Eglot's server edits for `Base.sin` → `Base.sinh`
after BMP/astral text, a named import, `Base.@tim` → `Base.@time`, and `Base.`
with an empty identifier. It checks server-item properties, annotations,
ordering metadata and rendered `sinh` documentation. Eglot advertises no snippet
support in these clean tests; ordinary server edits use plain text. Package-name
completion returned no candidates for the fixture's `using WorkbenchEx`; named
imports work. No alternative package-name index has been added.

Three optional graphical fixtures run in a fresh Emacs -Q with the installed
Corfu 2.13/Compat, and in a fresh Emacs loading the user's existing Doom
configuration with Corfu/Orderless. They assert visible completion and
documentation child frames, readable Unicode/semantic popup contents, successful
Unicode/emoji and space-containing path insertion, correctly positioned Eglot
edits, synchronized hover and ElDoc argument signatures. The graphical checks
drive the actual Corfu UI functions and process event loop; they do not simulate
a human keyboard session or validate the future complete Doom migration.
Result logs and protocol logs live in `test/results/corfu/` and
`test/results/corfu-doom/`; see [README.md](README.md) for exact commands.

Unicode caches contain validated UTF-8 TSV, with the exporting Julia version
in the header. Their identity includes the resolved executable path, size and
modification time. Opening files and invoking CAPFs never run a version probe
or start Julia. A runtime changed behind an unchanged wrapper requires explicit
refresh. Unicode setup has bounded jobs with timeout/cancellation cleanup and
atomic cache replacement. Plain-string paths decline escapes/interpolation;
these local helper/cache/path adapters do not support remote buffers.

## Eglot and project validation

`make test-eglot` runs fifteen unit fixtures without Julia. They cover nearest
environment discovery and filename precedence, explicit relative project files,
VC roots distinct from nested environments, connection identity, standalone
resolution without process/filesystem side effects, custom contacts, existing
Eglot mappings, missing-tool guidance, executable/version/path overrides, old
Julia and remote-launch errors, doctor output, cache invalidation, asynchronous
setup logs/duplicate jobs/nonzero exits, and forced-shutdown error recovery.

`make test-eglot-integration` uses real Eglot-managed buffers and the installed
LanguageServer 6.0.1. Two temporary packages expose distinct documentation
needles. The fixture verifies independent connections, same-project sibling
sharing, package hover, Flymake diagnostics, Xref definitions, three applied
rename edits including a call after BMP/astral Unicode, formatting and subsequent
hover after synchronization. It kills one server, reconnects its unsaved buffer,
confirms the other server remains alive, then reconnects with an explicitly
changed environment argument and shuts down both connections. Event/stderr logs
are saved under `test/results/eglot`, including on failure.

A separate batch Emacs run exercised the public asynchronous setup command in
a temporary tooling directory with `JULIA_PKG_OFFLINE=true`. It completed with
exit 0 and installed the pinned Project/Manifest using existing Julia depot
dependencies; its logs are in `test/results/eglot/setup.log`. Initial download
and cold precompilation remain covered by the earlier setup measurements.

The test harness uses a POSIX shell for project.el file listing (the installed
default shell is Nushell), trusts only its generated fixture directory, and
starts Flymake directly rather than waiting for an interactive command loop.
The package reports shell/content-trust settings in its doctor and preserves
the user's choices. Eglot controls connection waiting via its own settings.
The small cached `julia --version` probe is synchronous and runs only during
explicit setup/connection/doctor, never while opening a file.

Environment overrides set the active environment argument. LanguageServer's
per-file workspace/package resolution still takes precedence where applicable;
the adapter does not alter upstream resolution policy. Inlay hints are
advertised and Emacs 31 provides the client command; type-definition is absent.
Code actions, inlay UI, Corfu insertion, automatic crash reconnection, remote
contacts and minimum-version combinations remain unvalidated here.

## Required protocol features

The test client launches an isolated tooling environment and explicitly passes
the temporary fixture project's environment. It opens a real `.jl` document,
sends requests over pipes, validates responses and applies returned edits. It
does not execute the fixture's intentionally unresolved variable.

| Feature | Advertised | Actual result |
| --- | --- | --- |
| Completion | Yes; `.`, `@`, `"`, `^` triggers, no resolve provider | `Base.sin` offers `sin` and `sinh`; `sinh` includes Markdown documentation and plain-text edits. Replaced the correct `sin` range and synchronized `Base.sinh`. |
| Hover | Yes | Local function signature/docstring at a UTF-16 position after `α` and `🐈`; renamed function still resolves after subsequent edits and formatting. |
| Diagnostics | Push notifications | Expected `unused_function_argument` finding; versioned diagnostics continue after document changes. |
| Definition | Yes | Returns the local function's real file URI and declaration line from its Unicode-line call site. |
| Rename | Yes; prepare provider also advertised | Three edits; every source range contains `twice`, including the Unicode-line occurrence. Applied them as `double_value` and synchronized the buffer. Prepare-rename itself was not exercised. |
| Formatting | Full and range advertised | Full-document edits normalize `compact(x)=x+1` to `compact(x) = x+1`. Applied edits, synchronized, and queried the updated document successfully. Range formatting was not exercised. |
| Shutdown | Standard LSP | `shutdown` / `exit` yields exit status 0 and cleans the test process and buffers. |

Initialization also advertises signature help, references, document/workspace
symbols, document highlights, code actions, selection ranges, document links,
workspace folders and inlay hints. These are capability observations, not runtime
validation. Declaration, type-definition, implementation, folding-range and
color providers are false. Crash/reconnect and multiple-project isolation now
have Eglot fixtures above. Snippet negotiation, cancellation and interactive
Eglot/Doom UI behavior remain for later milestones.

LanguageServer 6 uses project `JuliaLint.toml` configuration and disables
`missing_reference` in its default preset. The fixture therefore checks a
deterministic enabled rule. Missing-reference warnings can be selected explicitly
with a project lint configuration; they are also withheld during incomplete
environment indexing. Do not assume every unresolved name generates a default
diagnostic or copy older LanguageServer lint configuration into the new adapter.

## Documentation contract

The standard-library-only helper uses `Base.Docs.Binding` / `Base.Docs.doc`
with REPL loaded, and `InteractiveUtils.apropos` for documentation-text search.
Version-sensitive documentation handling is isolated in `julia/documentation.jl`.

57 assertions exercise unqualified/qualified Base names, macros, operators,
`π`, signatures/doc text, literal search (including regex quoting), unknown and
undocumented symbols, invalid expressions, empty queries/results, result limits,
UTF-8 output, selected package/standard-library docs, named-symbol indexing,
protocol validation and noisy package initialization. The fixture package has
a unique docstring needle `quasarotter`, found only after explicit package loading.

Queries are symbol names or literal search strings passed as arguments; query
text is never evaluated. Package selection uses Julia's ordinary loading API.
`apropos` searches all docs loaded in that helper process, including dependencies
loaded transitively. CLI invocations start fresh processes; they do not inherit
a running REPL or load every project dependency. Lookup returns Markdown and a
documented flag; a defined binding without a docstring gets Julia's summary and
`found=false`. Search returns bounded, sorted, unique names and a truncation flag.
The default CLI is human-readable; `--protocol` writes a versioned UTF-8/base64
data format consumed by the asynchronous Emacs adapter. Selected package stdout
is redirected to stderr during requests, keeping machine responses valid.

Fourteen ERT unit fixtures cover protocol/cache validation, executable and
project/manifest identity, literal argument vectors, Unicode results, cache-only
ElDoc, process-free opening, result buttons/history/refresh, asynchronous name
completion, empty/missing docs, captured failures, atomic cache preservation,
timeouts, cancellation, output/concurrency limits, stale results and killed-buffer
cleanup. Three real-helper fixtures cover Base/macros, selected Dates/project
documentation, named completion, search-result lookup, standalone empty
environments, missing packages, invalid expressions, environment separation and
project-file invalidation. A timer and buffer edits advance while Julia runs.
The live Eglot fixture additionally displays persistent help for a local function
after BMP/astral text, with no source window and a missing local Julia executable.

ElDoc keeps Eglot's existing connected providers and consumes cached helper docs
elsewhere, without launching workers while typing. Fresh helpers are bounded by
timeout, output size and concurrency. Successful jobs discard temporary output
and stderr buffers; failures retain stderr logs and preserve previous cache files.
Changing source settings rejects stale results. Result buttons retain captured
scope; refresh resolves current settings. Language-server requests use Eglot's
position and markup adapters in one isolated function, with JSON-RPC deadlines;
cancellation/supersession discards their callbacks rather than stopping the server.

Cache keys use executable path/size/mtime and helper/project/manifest contents,
including versioned manifests, plus environment and package selection. Exported
responses record the full Julia version. An unchanged wrapper that switches
runtimes, or changed package source docs, requires explicit refresh. Local helper
caches do not support remote projects. Rendering retains Markdown with basic
fontification rather than requiring a Markdown package. The optional official
manual search URL has an ERT construction check; browser interaction, manual
keyboard use and Doom documentation behavior remain unvalidated.

## Timings

One sequential `make benchmark` run, after explicit installation/precompilation.
These are local measurements for the tiny fixture, not release performance
guarantees. Initial dependency precompilation took approximately 147 seconds
with two precompile tasks; package download/registry time was additional.

Both server runs start fresh Julia processes and temporary project copies. The
first uses an empty symbol cache; the second reuses it. Existing Julia package
precompile caches remain available in both. First diagnostics measure elapsed
time from process creation, including initialization and workspace loading.

| Server measurement | Empty symbol cache | Reused symbol cache |
| --- | ---: | ---: |
| Initialize | 4.743 s | 4.845 s |
| First fixture diagnostics | 11.333 s | 11.477 s |
| First hover | 0.262 s | 0.244 s |
| Definition | 0.307 s | 0.268 s |
| Rename | 1.554 s | 1.486 s |
| First completion (after rename synchronization) | 1.543 s | 1.559 s |
| Repeated identical completion | 0.003 s | 0.003 s |
| First formatting | 1.658 s | 1.780 s |
| Hover after edits/formatting | 0.069 s | 0.107 s |

| Documentation measurement | Time |
| --- | ---: |
| Fresh helper process: selected package lookup | 0.947 s |
| Fresh helper process: selected package text search | 1.981 s |
| First lookup in already loaded helper | 0.198 s |
| Warm lookup, mean of five requests | 0.000059 s |
| First search in already loaded helper | 1.398 s |
| Warm search, mean of five requests | 0.100 s |

Fresh-worker measurements include process startup, standard-library/helper
loading and the request. Warm calls are direct Julia API calls in one process;
they do **not** establish latency for an unimplemented persistent service. These
results support proceeding with bounded asynchronous helper jobs and caching.

The milestone 5 live Emacs UI fixture measured these additional elapsed times,
including asynchronous worker completion with existing precompile caches:

| Documentation UI measurement | Time |
| --- | ---: |
| Fresh Base lookup | 1.626 s |
| Identical cached lookup, no helper | 0.0013 s |
| Fresh text search without selected packages | 2.599 s |
| Fresh search with selected project package and Dates | 3.137 s |
| Fresh name index followed by cached lookup | 1.490 s |

Raw UI measurements are retained in `test/results/documentation-ui-timings.el`.
Each fresh request has a separate process; these measurements do not establish
persistent-helper latency or first-ever Julia precompilation time.

## Reproduction and validation boundaries

```sh
make setup-server
make check
make benchmark
```

Without system Make: `nix shell nixpkgs#gnumake -c make check` (and similarly
for setup/benchmark). Setup is explicit and writes its Project/Manifest and
symbol caches to user-writable locations outside the checkout. Server launch
and tests do not install packages. See [README.md](README.md) for path overrides.

With the explicit Nix grammar path, `make check` passed 95 Julia assertions
(57 documentation, nine Unicode, 29 REPL) and 80 ERT tests (14 editing,
13 completion, 15 environment/setup, 14 documentation unit, three live
documentation, 13 REPL unit, five live REPL, two protocol and one live Eglot
fixture), byte compilation with warnings treated
as errors, and `checkdoc` without diagnostics. Whitespace checks passed. The earlier benchmark
contract passed against both empty and reused symbol caches; servers exited
cleanly. Setup also succeeded on a repeat invocation; a separate temporary
environment check confirmed that an unrelated Project/Manifest is not replaced.
Raw reports and logs are local, ignored artifacts:

- `test/results/server-report.json`, `server-events.log`, `server-stderr.log`.
- `test/results/{empty-symbol-cache,reused-symbol-cache}/server-report.json`
  and the corresponding logs.
- `test/results/documentation-timings.toml`.
- `test/results/documentation-ui-timings.el`.
- `test/results/eglot/{events,stderr}-N.log` and `setup.log`.

Completion has automated graphical validation in vanilla Emacs and the current
Doom runtime as described above. No manual keyboard session, minimum-version
check or complete Doom migration validation has occurred yet.
Tree-sitter editing and Eglot major-mode connections have automated fixtures.

## REPL validation

Thirteen ERT unit fixtures cover session scope independent of server settings,
no launch on opening source, empty-selection rejection, missing environments,
safe Unicode/source encoding, arbitrary output chunk splits, unrelated control
output, success/error/stale records, callback failures, bounded ordered queues,
absolute source lines under narrowing, unsaved buffer contents, structured and
incomplete forms, source completion staleness, interrupt cancellation and startup
deadline/buffer cleanup. Five real Julia comint fixtures check runtime isolation
and sharing, explicit activation, empty standalone environments, line/region/
DWIM/top-level/buffer/file evaluation, Unicode filenames and completion offsets,
relative includes, source backtraces, stdout versus result copying, asynchronous
startup, evaluated-symbol docs independent of helpers, preserved ans, actual
interruption, cancelled queued work, multiline history after restart, deliberate
process exit, session recreation and process cleanup. Twenty-nine Julia assertions
exercise the standard-library adapter, including soft scope and newly defined
display methods without world-age errors.

The REPL uses a Julia BasicREPL over pipes with comint-owned history/input.
Source evaluates in Main through include APIs; top-level selection needs the
grammar. Runtime named docs and insertable completion query the existing process
explicitly; method-only completion lists are not inserted. Plain-text renderings
are bounded to 65,536 characters. Multimedia, debugger, automatic module context,
terminal help/shell/Pkg modes and remote sessions are outside the initial scope.
Source-settings changes choose a different session; manual runtime activation
does not change Eglot/helper settings. No packages are installed by REPL startup
or activation. Manual keyboard and Doom REPL validation remain pending.

```sh
JULIA_WORKBENCH_GRAMMAR_PATH="$HOME/.config/emacs/.local/etc/tree-sitter" \
  make check-repl
```

Ignored transcripts and elapsed measurements are retained in `test/results/repl/`.
Startup plus first evaluation measured about one second with installed Julia
precompile caches; simple repeated evaluations measured about 0.06–0.07 seconds
including a 0.05-second fixture wait for the trailing prompt. These are batch
measurements, not first-ever precompilation or manual UI timings.

## Upstream API references

- [LanguageServer 6.0.1 launcher](https://github.com/julia-vscode/LanguageServer.jl/blob/v6.0.1/src/runserver.jl)
- [LanguageServer 6.0.1 capabilities and initialization](https://github.com/julia-vscode/LanguageServer.jl/blob/v6.0.1/src/requests/init.jl)
- [Julia documentation](https://docs.julialang.org/en/v1/manual/documentation/)
- [Julia documentation search utilities](https://docs.julialang.org/en/v1/stdlib/InteractiveUtils/)
- [Julia REPL](https://docs.julialang.org/en/v1/stdlib/REPL/)
- [Emacs comint process interaction](https://www.gnu.org/software/emacs/manual/html_node/emacs/Interactive-Shell.html)
