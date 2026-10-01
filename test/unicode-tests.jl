# SPDX-License-Identifier: GPL-3.0-or-later
using Test, REPL
include(joinpath(@__DIR__, "..", "julia", "unicode.jl"))

@testset "Runtime Unicode export" begin
    rows = split(chomp(sprint(write_unicode_table)), '\n')
    @test popfirst!(rows) == "julia-workbench-unicode-v1\t$(VERSION)"
    pairs = [split(row, '\t') for row in rows]
    @test all(pair -> length(pair) == 2, pairs)
    names = first.(pairs)
    @test names == sort(unique(names))
    table = Dict(pair[1] => pair[2] for pair in pairs)
    expected = merge(REPL.REPLCompletions.latex_symbols,
                     REPL.REPLCompletions.emoji_symbols)
    @test table == expected
    @test table["\\alpha"] == "α"
    @test table["\\:smile:"] == "😄"
    @test table["\\hat"] == "̂"
    @test table["\\_2"] == "₂"
    @test table["\\1/2"] == "½"
end
