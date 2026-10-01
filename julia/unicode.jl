# SPDX-License-Identifier: GPL-3.0-or-later
# Version-sensitive Julia completion data adapter.  No package installation,
# project loading or user startup code.  Emacs validates the UTF-8 TSV output.
using REPL

function write_unicode_table(io::IO)
    println(io, "julia-workbench-unicode-v1\t", VERSION)
    symbols = merge(REPL.REPLCompletions.latex_symbols,
                    REPL.REPLCompletions.emoji_symbols)
    for name in sort!(collect(keys(symbols)))
        value = symbols[name]
        startswith(name, "\\") || error("Unexpected Unicode input name")
        any(c -> c in ('\t', '\n', '\r'), name * value) &&
            error("Unicode table contains TSV delimiters")
        println(io, name, '\t', value)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    write_unicode_table(stdout)
end
