# SPDX-License-Identifier: GPL-3.0-or-later

"Plain-text comint REPL with encoded editor requests; no package dependencies."
module WorkbenchREPL

using REPL
using Base64: base64encode, base64decode
include("documentation.jl")

const token = Ref("")
const text_limit = 65536

decode(text) = String(base64decode(text))
bounded(text) = length(text) > text_limit ? first(text, text_limit) * "\n[truncated]" : text

function record(id, kind, status, text)
    write(stdout, string('\x1e', token[], '\t', id, '\t', kind, '\t', status, '\t',
                         base64encode(bounded(text)), '\x1f'))
    flush(stdout)
end

"Adapt Julia's byte-indexed completion range to zero-based character offsets."
function complete(input)
    candidates, range, insertable = REPL.REPLCompletions.completions(input, lastindex(input), Main)
    insertable && !isempty(candidates) && !isempty(range) ||
        throw(ArgumentError("No insertable runtime completions"))
    start = length(SubString(input, 1, prevind(input, first(range))))
    stop = length(SubString(input, 1, last(range)))
    names = unique(REPL.REPLCompletions.completion_text.(candidates))
    header = string(start, '\t', stop, '\n')
    rows = String[]
    size = length(header)
    for name in first(names, min(1000, length(names)))
        row = base64encode(name)
        size + length(row) + 1 <= text_limit || break
        push!(rows, row)
        size += length(row) + 1
    end
    isempty(rows) && throw(ArgumentError("Runtime completion candidate exceeds output limit"))
    header * join(rows, '\n')
end

"Run one editor request in the live Main module, keeping ordinary output visible."
function request(id, kind, source64, filename64, line)
    source, filename = decode(source64), decode(filename64)
    value = isdefined(Main, :ans) ? Main.ans : nothing
    try
        if kind == "eval"
            line >= 1 || throw(ArgumentError("Invalid source line"))
            value = Base.include_string(REPL.softscope, Main, "\n"^(line - 1) * source, filename)
            text = bounded(Base.invokelatest(sprint, show, MIME"text/plain"(), value; context=:limit => true))
            # Keep a semicolon-suppressed result available for copying as well.
            if value !== nothing && !REPL.ends_with_semicolon(source)
                println(stdout, text)
            end
            record(id, kind, "ok", text)
        elseif kind == "file"
            value = Base.include(REPL.softscope, Main, filename)
            text = bounded(Base.invokelatest(sprint, show, MIME"text/plain"(), value; context=:limit => true))
            value === nothing || println(stdout, text)
            record(id, kind, "ok", text)
        elseif kind == "activate"
            # Explicit activation loads Pkg, but never resolves or installs packages.
            pkg = Base.require(Main, :Pkg)
            Base.invokelatest(pkg.activate, source)
            record(id, kind, "ok", something(Base.active_project(), ""))
        elseif kind == "documentation"
            result = WorkbenchDocs.lookup(WorkbenchDocs.Context(), source)
            record(id, kind, "ok", result.markdown)
        elseif kind == "completion"
            record(id, kind, "ok", complete(source))
        else
            throw(ArgumentError("Unknown REPL request: $kind"))
        end
    catch error
        text = bounded(sprint(showerror, error, catch_backtrace()))
        println(stdout, "ERROR: ", text)
        record(id, kind, "error", text)
    end
    value
end

function run(session_token)
    token[] = session_token
    terminal = REPL.Terminals.TTYTerminal("dumb", stdin, stdout, stderr)
    repl = REPL.BasicREPL(terminal)
    # The basic frontend avoids terminal escape sequences and works over pipes.
    record(0, "ready", "ok", string(VERSION))
    REPL.run_repl(repl)
end

end
