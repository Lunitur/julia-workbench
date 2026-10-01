# SPDX-License-Identifier: GPL-3.0-or-later
using TOML
using Dates

helper = abspath(joinpath(@__DIR__, "..", "julia", "documentation.jl"))
fixture = abspath(joinpath(@__DIR__, "fixtures", "Example"))
executable = joinpath(Sys.BINDIR, Base.julia_exename())
report = Dict{String,Any}("julia" => string(VERSION), "date" => string(today()))

# Fresh worker costs include Julia startup, loading stdlibs, helper compilation
# and the request. Existing on-disk Julia precompile caches are retained.
for (label, args) in (
    ("lookup", ["lookup", "WorkbenchExample.greet", "WorkbenchExample"]),
    ("search", ["search", "quasarotter", "WorkbenchExample"]))
    command = Cmd([executable, "--startup-file=no", "--project=$fixture", helper, args...])
    report["fresh_worker_$(label)_seconds"] = @elapsed run(pipeline(command; stdout=devnull))
end

report["module_load_seconds"] = @elapsed include(helper)
report["context_load_seconds"] = @elapsed context = WorkbenchDocs.Context(["WorkbenchExample"])
for (label, request) in (
    ("lookup", () -> WorkbenchDocs.lookup(context, "WorkbenchExample.greet")),
    ("search", () -> WorkbenchDocs.search(context, "quasarotter")))
    report["first_$(label)_seconds"] = @elapsed request()
    times = [@elapsed request() for _ in 1:5]
    report["warm_$(label)_mean_seconds"] = sum(times) / length(times)
    report["warm_$(label)_samples_seconds"] = times
end

directory = joinpath(@__DIR__, "results")
mkpath(directory)
open(joinpath(directory, "documentation-timings.toml"), "w") do output
    TOML.print(output, report; sorted=true)
end
TOML.print(stdout, report; sorted=true)
