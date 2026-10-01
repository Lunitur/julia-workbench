# SPDX-License-Identifier: GPL-3.0-or-later
using Test
using Base64: base64decode
include("../julia/documentation.jl")
using .WorkbenchDocs

@testset "Julia documentation contract" begin
    context = Context()
    @test occursin("explicit packages: none", WorkbenchDocs.scope(context))
    for query in ("sin", "Base.sin", "@time", "Base.@time", "+", "Base.+", "π")
        result = lookup(context, query)
        @test result.found
        @test !isempty(result.markdown)
    end
    @test occursin("sine", lookup(context, "Base.sin").markdown)
    @test !lookup(context, "workbench_no_such_symbol").found
    @test !lookup(context, "UnloadedPackage.symbol").found
    @test isempty(search(context, "workbench_no_such_documentation_phrase").symbols)
    @test "Base.sin" in search(context, "sine").symbols
    @test isempty(search(context, "quasarotter").symbols)
    @test !lookup(context, "WorkbenchExample.greet").found
    @test_throws ArgumentError Context(["Dates; error(1)"])
    @test_throws ArgumentError lookup(context, "exit()")
    @test_throws ArgumentError lookup(context, "Base.sin(1)")
    @test_throws ArgumentError search(context, "")
    @test isempty(search(context, raw"\E.*").symbols)

    # Selecting a project dependency loads just that package in this helper.
    selected = Context(["WorkbenchExample", "Dates"])
    @test occursin("WorkbenchExample, Dates", WorkbenchDocs.scope(selected))
    result = lookup(selected, "WorkbenchExample.greet")
    @test result.found
    @test occursin("α and 🐈", result.markdown)
    @test "WorkbenchExample.greet" in search(selected, "quasarotter").symbols
    @test lookup(selected, "Dates.Date").found
    @test !lookup(selected, "WorkbenchExample.undocumented").found
    @test !isempty(lookup(selected, "WorkbenchExample.undocumented").markdown)
    @test length(search(selected, "the"; limit=3).symbols) == 3
    @test search(selected, "the"; limit=3).truncated
    output = IOBuffer()
    main(["lookup", "WorkbenchExample.greet", "WorkbenchExample"]; output)
    @test occursin("α and 🐈", String(take!(output)))
    main(["search", "workbench_no_such_documentation_phrase"]; output)
    @test occursin("No documentation matches", String(take!(output)))

    indexed = symbol_names(selected)
    @test "Base.sin" in indexed.symbols
    @test "Base.@time" in indexed.symbols
    @test "WorkbenchExample.greet" in indexed.symbols
    @test "Dates.Date" in indexed.symbols
    @test issorted(indexed.symbols)
    @test allunique(indexed.symbols)
    @test WorkbenchDocs.binding(selected, "REPL.REPLCompletions.completions") !== nothing
    for (command, query) in (("lookup", "WorkbenchExample.greet"),
                             ("search", "quasarotter"), ("names", ""))
        main(["--protocol", command, query, "WorkbenchExample"]; output)
        wire = String(take!(output))
        @test startswith(wire, "julia-workbench-doc-v1\t$VERSION\t$command\n")
        fields = [split(row, '\t'; limit=2) for row in split(chomp(wire), '\n')[2:end]]
        @test startswith(String(base64decode(first(fields)[2])), "Loaded Julia documentation")
        if command == "lookup"
            markdown = only(filter(row -> row[1] == "Markdown", fields))[2]
            @test occursin("α and 🐈", String(base64decode(markdown)))
        else
            @test any(row -> row[1] == "Name" &&
                             String(base64decode(row[2])) == "WorkbenchExample.greet", fields)
        end
    end
    @test_throws ArgumentError main(["--protocol", "invalid", "sin"]; output)
    @test_throws ArgumentError main(["--protocol", "lookup", "exit()"]; output)

    # Package initialization output cannot corrupt machine-readable responses.
    mktempdir() do directory
        write(joinpath(directory, "Project.toml"), "name = \"WorkbenchNoisy\"\nuuid = \"de98f260-d139-4962-a058-4d2fd3c25427\"\n")
        mkpath(joinpath(directory, "src"))
        write(joinpath(directory, "src", "WorkbenchNoisy.jl"),
              "module WorkbenchNoisy\n\"Noisy package documentation\"\nf() = 1\n__init__() = println(\"initialization output\")\nend\n")
        pushfirst!(LOAD_PATH, directory)
        try
            main(["--protocol", "lookup", "WorkbenchNoisy.f", "WorkbenchNoisy"]; output)
            @test startswith(String(take!(output)), "julia-workbench-doc-v1\t")
        finally
            popfirst!(LOAD_PATH)
        end
    end
end
