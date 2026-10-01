# SPDX-License-Identifier: GPL-3.0-or-later
using Test
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
end
