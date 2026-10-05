# SPDX-License-Identifier: GPL-3.0-or-later
using Test
using Base64
include("../julia/repl.jl")
using .WorkbenchREPL.WorkbenchPlots

struct SVGProbe end
Base.show(io::IO, ::MIME"image/svg+xml", ::SVGProbe) =
    print(io, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\"><text>α 🐈</text></svg>")
struct PNGProbe end
Base.show(io::IO, ::MIME"image/png", ::PNGProbe) = write(io, UInt8[0x89, 0x50, 0x4e, 0x47, 0xff, 0x00])
struct BrokenProbe end
Base.show(io::IO, ::MIME"image/svg+xml", ::BrokenProbe) = (print(io, "partial"); error("render failed"))

function plot_response(source; kind="eval", filename="plot-probe.jl")
    mktemp() do _, output
        redirect_stdout(output) do
            WorkbenchREPL.request(1, kind, base64encode(source), base64encode(filename), 1)
        end
        flush(output)
        seekstart(output)
        read(output, String)
    end
end

@testset "Native plot display" begin
    mktempdir() do directory
        events = Tuple{String,String,Int}[]
        notify = (mime, name, size) -> push!(events, (mime, name, size))
        d = WorkbenchPlots.EditorDisplay(directory, ["svg", "png"], 200000, notify)
        @test displayable(d, MIME"image/svg+xml"())
        @test displayable(d, MIME"image/png"())
        @test !displayable(d, MIME"text/html"())
        @test_throws ArgumentError WorkbenchPlots.EditorDisplay(directory, ["html"], 20, notify)
        @test_throws ArgumentError WorkbenchPlots.EditorDisplay(directory, ["svg"], 0, notify)
        @test_throws MethodError display(d, 42)
        @test !WorkbenchPlots.display_result(d, 42)
        display(d, SVGProbe())
        @test events[1][1] == "image/svg+xml"
        @test occursin("α 🐈", read(joinpath(directory, events[1][2]), String))
        @test filesize(joinpath(directory, events[1][2])) == events[1][3]
        display(d, PNGProbe())
        @test read(joinpath(directory, events[2][2])) == UInt8[0x89, 0x50, 0x4e, 0x47, 0xff, 0x00]
        display(d, "image/svg+xml", "<svg>" * " "^70000 * "</svg>")
        @test events[3][3] > WorkbenchREPL.text_limit
        display(d, "image/png", UInt8[0xff, 0x00])
        @test read(joinpath(directory, events[4][2])) == UInt8[0xff, 0x00]
        @test_throws MethodError display(d, "text/html", "<html></html>")
        before = readdir(directory)
        @test_throws ErrorException display(d, BrokenProbe())
        @test readdir(directory) == before
        small = WorkbenchPlots.EditorDisplay(directory, ["svg"], 10, notify)
        @test_throws ArgumentError display(small, SVGProbe())
        @test readdir(directory) == before
        @test length(events) == 4

        WorkbenchREPL.plot_display[] = d
        WorkbenchREPL.install_plot_display()
        try
            # Define methods during the very request which needs to use them.
            source = "struct NewPlot end; Base.show(io::IO, ::MIME\"image/svg+xml\", ::NewPlot) = print(io, \"<svg/>\"); NewPlot()"
            output = plot_response(source)
            @test length(events) == 5
            @test occursin("\teval\tok\t", output)
            @test !occursin("NewPlot()\n", output)
            output = plot_response("NewPlot();")
            @test length(events) == 5
            @test occursin("\teval\tok\t", output)
            plot_response("display(NewPlot()); display(SVGProbe());")
            @test length(events) == 7
            plot_response("42")
            @test length(events) == 7
            file = joinpath(directory, "probe.jl")
            write(file, "NewPlot()")
            plot_response(""; kind="file", filename=file)
            @test length(events) == 8
            output = plot_response("BrokenProbe()")
            @test occursin("\teval\tok\t", output)
            @test occursin("BrokenProbe()\n", output)
            @test length(events) == 8
        finally
            popdisplay(d)
            WorkbenchREPL.plot_display[] = nothing
        end
        plot_response("SVGProbe()")
        @test length(events) == 8
    end
end
