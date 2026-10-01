# SPDX-License-Identifier: GPL-3.0-or-later
# Run exactly the same wire contract against an empty and then reused symbol
# cache. Keep existing Julia package precompile caches: setup is separate.
test_root = abspath(@__DIR__)
root = dirname(test_root)
emacs = get(ENV, "EMACS", "emacs")
command = Cmd(Cmd([emacs, "-Q", "--batch", "-l", joinpath(test_root, "server-tests.el"),
                   "-f", "ert-run-tests-batch-and-exit"]); dir=root)

mktempdir(; prefix="julia-workbench-symbols-") do symbols
    for label in ("empty-symbol-cache", "reused-symbol-cache")
        println("Benchmark: $label (Julia precompile caches retained)")
        withenv("JULIA_WORKBENCH_SYMBOL_CACHE" => symbols,
                "JULIA_WORKBENCH_TEST_RESULTS" => joinpath(test_root, "results", label)) do
            run(command)
        end
    end
end
