# SPDX-License-Identifier: GPL-3.0-or-later

"Standard-library documentation prototype; queries are names, never Julia code."
module WorkbenchDocs

using REPL
using Markdown
using InteractiveUtils: apropos

export Context, lookup, search, main

struct Context
    roots::Dict{String,Module}
    packages::Vector{String}
end

function Context(packages::Vector{String}=String[])
    roots = Dict("Base" => Base, "Core" => Core, "Main" => Main)
    for package in unique(packages)
        Base.isidentifier(package) || throw(ArgumentError("Expected a package name: $package"))
        # Explicit package selection is the only place package code is loaded.
        roots[package] = Base.require(Main, Symbol(package))
    end
    Context(roots, unique(packages))
end

scope(context::Context) = "Loaded Julia documentation (Base/Core and helper standard libraries); " *
    "explicit packages: " * (isempty(context.packages) ? "none" : join(context.packages, ", "))

valid_name(name) = Base.isidentifier(name) || Base.isoperator(Symbol(name)) ||
    (startswith(name, "@") && Base.isidentifier(chop(name; head=1, tail=0)))

function binding(context::Context, query::AbstractString)
    name = strip(query)
    isempty(name) && throw(ArgumentError("Expected a symbol name"))
    # A standalone operator may itself contain dots (e.g. `..`).
    parts = Base.isoperator(Symbol(name)) ? [name] : split(name, '.')
    valid_name(last(parts)) || throw(ArgumentError("Expected a symbol name, not an expression: $query"))
    all(Base.isidentifier, parts[1:end-1]) || throw(ArgumentError("Invalid module path: $query"))
    if length(parts) == 1
        symbol = Symbol(name)
        for mod in (Main, Base, Core)
            isdefined(mod, symbol) && return Base.Docs.Binding(mod, symbol)
        end
        return nothing
    end
    mod = get(context.roots, first(parts), nothing)
    mod === nothing && return nothing
    for part in parts[2:end-1]
        symbol = Symbol(part)
        isdefined(mod, symbol) || return nothing
        child = getfield(mod, symbol)
        child isa Module || return nothing
        mod = child
    end
    symbol = Symbol(last(parts))
    isdefined(mod, symbol) ? Base.Docs.Binding(mod, symbol) : nothing
end

# Isolate the Julia documentation adapter: loading REPL installs these methods
# into Base.Docs. Julia's generated summaries have no :results metadata.
function lookup(context::Context, query::AbstractString)
    target = binding(context, query)
    target === nothing && return (; symbol=String(query), found=false,
        markdown="No documentation found for $query in the selected scope.", scope=scope(context))
    doc = Base.Docs.doc(target)
    found = doc isa Markdown.MD && !isempty(get(doc.meta, :results, []))
    markdown = doc === nothing ? "No documentation found for $query." :
        sprint(show, MIME"text/markdown"(), doc)
    (; symbol=String(query), found, markdown, scope=scope(context))
end

function search(context::Context, query::AbstractString; limit::Int=100)
    isempty(strip(query)) && throw(ArgumentError("Expected nonempty documentation search text"))
    limit > 0 || throw(ArgumentError("Search limit must be positive"))
    output = IOBuffer()
    # `apropos(io, string)` quotes most text, but embedded \E can end its
    # regex quoting. Escape it explicitly so this interface is always literal.
    literal = replace(query, "\\E" => "\\E\\\\E\\Q")
    apropos(output, Regex("\\Q$literal\\E", "i"))
    symbols = sort!(unique(filter(!isempty, split(String(take!(output)), '\n'))))
    (; symbols=String.(first(symbols, min(limit, length(symbols)))),
       truncated=length(symbols) > limit, scope=scope(context))
end

function main(args=ARGS; output::IO=stdout)
    length(args) >= 2 || throw(ArgumentError("Usage: documentation.jl lookup|search QUERY [PACKAGE ...]"))
    command, query = args[1:2]
    command in ("lookup", "search") || throw(ArgumentError("Unknown command: $command"))
    context = Context(String.(args[3:end]))
    result = command == "lookup" ? lookup(context, query) : search(context, query)
    println(output, "Scope: ", result.scope)
    if command == "lookup"
        println(output, "Symbol: ", result.symbol)
        println(output, "Documented: ", result.found)
        println(output)
        println(output, result.markdown)
    else
        println(output, "Results: ", length(result.symbols), result.truncated ? " (truncated)" : "")
        isempty(result.symbols) && println(output, "No documentation matches $query in the selected scope.")
        foreach(symbol -> println(output, symbol), result.symbols)
    end
    result
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    WorkbenchDocs.main()
end
