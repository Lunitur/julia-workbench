# SPDX-License-Identifier: GPL-3.0-or-later
# Explicit installation only; opening files and launching the server do not install.
using Pkg
include("paths.jl")
using .WorkbenchPaths

isempty(ARGS) || error("Usage: julia --startup-file=no julia/setup-server.jl")
VERSION >= v"1.11" || error("LanguageServer 6.0.1 requires Julia 1.11 or newer")
target = WorkbenchPaths.server_project()
template = joinpath(@__DIR__, "server-environment")
project = joinpath(target, "Project.toml")
if isfile(joinpath(target, "JuliaProject.toml")) ||
   (isfile(project) && read(project, String) != read(joinpath(template, "Project.toml"), String)) ||
   (!isfile(project) && isfile(joinpath(target, "Manifest.toml")))
    error("Refusing to overwrite an unrelated environment at $target; select a dedicated tooling directory")
end
mkpath(target)
for filename in ("Project.toml", "Manifest.toml")
    source = joinpath(template, filename)
    isfile(source) && cp(source, joinpath(target, filename); force=true)
end
Pkg.activate(target)
Pkg.instantiate()
Pkg.precompile()
println("Server tooling environment: ", target)
