# Feasibility baseline

Recorded 2026-10-01 on Linux/NixOS. Milestone 1 is complete; an installable
major mode, Eglot UI integration and Doom migration are still pending.

## Exercised combination

| Component | Version / evidence |
| --- | --- |
| Emacs | 31.1, clean `emacs -Q --batch`, built-in JSON-RPC and ERT |
| Julia | 1.13.1, `--startup-file=no` |
| LanguageServer.jl | 6.0.1, exact project compatibility pin |
| JuliaWorkspaces.jl | 13.4.3 |
| JSONRPC.jl | 3.1.0 |
| JuliaFormatter.jl / Runic.jl | 2.14.0 / 1.11.1 |
| Dependency graph | `julia/server-environment/Manifest.toml`, Julia manifest format 2.1 |

Emacs 30.1 and Julia 1.11 are proposed minimums, **not tested combinations**.
LanguageServer 6.0.1's Julia requirement is 1.11+, so the original proposed
Julia 1.10 baseline is unavailable with this server release. Julia 1.11/1.12,
their manifest handling and other operating systems remain to be exercised.

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
color providers are false. Snippet negotiation, cancellation, crash/reconnect,
multiple-project isolation and Eglot/Doom UI behavior belong to later milestones.

LanguageServer 6 uses project `JuliaLint.toml` configuration and disables
`missing_reference` in its default preset. The fixture therefore checks a
deterministic enabled rule. Missing-reference warnings can be selected explicitly
with a project lint configuration; they are also withheld during incomplete
environment indexing. Do not assume every unresolved name generates a default
diagnostic or copy older LanguageServer lint configuration into the new adapter.

## Documentation contract

The standard-library-only prototype uses `Base.Docs.Binding` / `Base.Docs.doc`
with REPL loaded, and `InteractiveUtils.apropos` for documentation-text search.
Version-sensitive documentation handling is isolated in `julia/documentation.jl`.

38 assertions exercise unqualified/qualified Base names, macros, operators,
`π`, signatures/doc text, literal search (including regex quoting), unknown and
undocumented symbols, invalid expressions, empty queries/results, result limits,
UTF-8 output, and selected package/standard-library docs. The fixture package has
a unique docstring needle `quasarotter`, found only after explicit package loading.

Queries are symbol names or literal search strings passed as arguments; query
text is never evaluated. Package selection uses Julia's ordinary loading API.
`apropos` searches all docs loaded in that helper process, including dependencies
loaded transitively. CLI invocations start fresh processes; they do not inherit
a running REPL or load every project dependency. Lookup returns Markdown and a
documented flag; a defined binding without a docstring gets Julia's summary and
`found=false`. Search returns bounded, sorted, unique names and a truncation flag.
The prototype CLI is human-readable; its Julia API supplies structured results
for the future asynchronous Emacs adapter.

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

`make check` passed 38 Julia assertions, two ERT tests (one is the full live-server
contract), byte compilation with warnings treated as errors, and `checkdoc`
without diagnostics. Whitespace checks passed for the new files. The benchmark
contract passed against both empty and reused symbol caches; servers exited
cleanly. Setup also succeeded on a repeat invocation; a separate temporary
environment check confirmed that an unrelated Project/Manifest is not replaced.
Raw reports and logs are local, ignored artifacts:

- `test/results/server-report.json`, `server-events.log`, `server-stderr.log`.
- `test/results/{empty-symbol-cache,reused-symbol-cache}/server-report.json`
  and the corresponding logs.
- `test/results/documentation-timings.toml`.

No interactive Emacs completion UI, tree-sitter editing, Eglot major-mode
connection, REPL integration, minimum-version check or Doom runtime validation
has occurred yet.

## Upstream API references

- [LanguageServer 6.0.1 launcher](https://github.com/julia-vscode/LanguageServer.jl/blob/v6.0.1/src/runserver.jl)
- [LanguageServer 6.0.1 capabilities and initialization](https://github.com/julia-vscode/LanguageServer.jl/blob/v6.0.1/src/requests/init.jl)
- [Julia documentation](https://docs.julialang.org/en/v1/manual/documentation/)
- [Julia documentation search utilities](https://docs.julialang.org/en/v1/stdlib/InteractiveUtils/)
