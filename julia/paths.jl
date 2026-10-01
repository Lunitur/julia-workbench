# SPDX-License-Identifier: GPL-3.0-or-later

"User-writable locations shared by setup and the launcher."
module WorkbenchPaths

const SERVER_VERSION = v"6.0.1"

cache_root() = joinpath(get(ENV, "XDG_CACHE_HOME", joinpath(homedir(), ".cache")),
                        "julia-workbench")
server_project() = abspath(get(ENV, "JULIA_WORKBENCH_SERVER_PROJECT",
    joinpath(cache_root(), "LanguageServer-$SERVER_VERSION", "julia-$(VERSION.major).$(VERSION.minor)")))
symbol_cache() = abspath(get(ENV, "JULIA_WORKBENCH_SYMBOL_CACHE",
    joinpath(cache_root(), "symbols", "LanguageServer-$SERVER_VERSION", "julia-$(VERSION.major).$(VERSION.minor)")))

end
