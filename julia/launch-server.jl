# SPDX-License-Identifier: GPL-3.0-or-later
# Invoke with --project=<tooling environment>, never --project=<user project>.
include("paths.jl")
using .WorkbenchPaths

length(ARGS) in (1, 2) || error("Usage: julia --startup-file=no --project=TOOLING julia/launch-server.jl PROJECT [SYMBOL_CACHE]")
environment = abspath(ARGS[1])
isfile(environment) && (environment = dirname(environment))
any(isfile(joinpath(environment, name)) for name in ("JuliaProject.toml", "Project.toml")) ||
    error("No JuliaProject.toml or Project.toml in $environment")

# Do not inherit packages from the user's global environment.
empty!(LOAD_PATH)
append!(LOAD_PATH, ["@", "@stdlib"])
using LanguageServer
pkgversion(LanguageServer) == WorkbenchPaths.SERVER_VERSION ||
    error("Expected LanguageServer $(WorkbenchPaths.SERVER_VERSION); run julia/setup-server.jl")
cache = length(ARGS) == 2 ? abspath(ARGS[2]) : WorkbenchPaths.symbol_cache()
mkpath(cache)
println(stderr, "Julia Workbench: Julia $VERSION, LanguageServer $(pkgversion(LanguageServer))")
println(stderr, "Analyzed environment: $environment; symbol cache: $cache")
LanguageServer.runserver(stdin, stdout, environment, nothing, cache)
