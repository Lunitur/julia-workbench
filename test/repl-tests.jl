# SPDX-License-Identifier: GPL-3.0-or-later
using Test
using Base64: base64encode, base64decode
include("../julia/repl.jl")

function response(kind, source; filename="/tmp/workbench-α 🐈.jl", line=1)
    path, io = mktemp()
    close(io)
    try
        value = open(path, "w") do output
            redirect_stdout(output) do
                WorkbenchREPL.request(1, kind, base64encode(source), base64encode(filename), line)
            end
        end
        text = read(path, String)
        frame = match(r"\x1e[^\x1f]*\x1f", text).match
        fields = split(chop(frame; head=1, tail=1), '\t')
        (; value, status=fields[4], payload=String(base64decode(fields[5])), visible=text)
    finally
        rm(path; force=true)
    end
end

@testset "REPL runtime adapter" begin
    WorkbenchREPL.token[] = "test-token"
    result = response("eval", "println(\"stdout α 🐈\"); 1 + 2")
    @test result.value == 3
    @test result.status == "ok"
    @test result.payload == "3"
    @test occursin("stdout α 🐈", result.visible)
    result = response("eval", "41 + 1;")
    @test result.value == 42
    @test result.payload == "42"
    @test !occursin("42", replace(result.visible, r"\x1e[^\x1f]*\x1f" => ""))
    @test response("eval", "nothing").payload == "nothing"
    @test response("eval", "@__LINE__", line=9).value == 9
    @test response("eval", "@__FILE__").value == "/tmp/workbench-α 🐈.jl"
    result = response("eval", "error(\"broken\")", line=7)
    @test result.status == "error"
    @test occursin("workbench-α 🐈.jl:7", result.payload)
    @test response("eval", "workbench_sum = 0; for n in 1:3; workbench_sum += n; end; workbench_sum").value == 6
    @test response("eval", "raw\"\$(`α 🐈`)\"").value == "\$(`α 🐈`)"
    @test response("eval", "\"\$literal\"", filename="/tmp/\"quotes\".jl").status == "error"
    @test response("eval", "\"\"\"Runtime nebula docs α 🐈.\"\"\"\nworkbench_nebula(x) = x + 1").status == "ok"
    @test occursin("Runtime nebula docs", response("documentation", "workbench_nebula").payload)
    @test response("documentation", "exit()").status == "error"
    @test response("eval", "struct WorkbenchShown end; Base.show(io::IO, ::MIME\"text/plain\", ::WorkbenchShown) = print(io, \"new show\"); WorkbenchShown()").payload == "new show"
    result = response("completion", "α = \"🐈\"; workbench_neb")
    @test result.status == "ok"
    lines = split(result.payload, '\n')
    start, stop = parse.(Int, split(first(lines), '\t'))
    @test start == length("α = \"🐈\"; ")
    @test stop == length("α = \"🐈\"; workbench_neb")
    @test "workbench_nebula" in String.(base64decode.(lines[2:end]))
    @test response("completion", "workbench_does_not_exist_").status == "error"
    @test response("unknown", "").status == "error"
    @test length(WorkbenchREPL.bounded("α"^70000)) < 70000
    mktempdir() do directory
        write(joinpath(directory, "nested.jl"), "nested_value = 20\n")
        file = joinpath(directory, "α 🐈.jl")
        write(file, "include(\"nested.jl\"); nested_value + 2\n")
        @test response("file", ""; filename=file).value == 22
        write(joinpath(directory, "Project.toml"), "[deps]\n")
        @test response("activate", directory).status == "ok"
        @test Base.active_project() == joinpath(directory, "Project.toml")
    end
end
