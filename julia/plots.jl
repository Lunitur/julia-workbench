# SPDX-License-Identifier: GPL-3.0-or-later

"Standard-library-only SVG/PNG display for a local editor session."
module WorkbenchPlots

mutable struct EditorDisplay <: AbstractDisplay
    directory::String
    formats::Vector{String}
    limit::Int
    serial::Int
    notify::Function
end

const supported = Dict("svg" => MIME"image/svg+xml"(), "png" => MIME"image/png"())

function EditorDisplay(directory, formats, limit, notify)
    isdir(directory) || throw(ArgumentError("Plot directory must already exist"))
    limit > 0 || throw(ArgumentError("Plot byte limit must be positive"))
    all(format -> haskey(supported, format), formats) ||
        throw(ArgumentError("Unsupported plot format"))
    EditorDisplay(abspath(directory), unique(formats), limit, 0, notify)
end

Base.displayable(d::EditorDisplay, mime::MIME) = any(f -> supported[f] == mime, d.formats)

function Base.display(d::EditorDisplay, mime::MIME, value)
    displayable(d, mime) || throw(MethodError(display, (d, mime, value)))
    # invokelatest permits MIME methods defined or loaded by the current evaluation.
    raw = value isa AbstractString && mime == MIME"image/svg+xml"() ||
          value isa Vector{UInt8} && mime == MIME"image/png"()
    raw || Base.invokelatest(showable, mime, value) ||
        throw(MethodError(display, (d, mime, value)))
    format = only(filter(f -> supported[f] == mime, d.formats))
    d.serial += 1
    name = string("plot-", d.serial, '.', format)
    path = joinpath(d.directory, name)
    partial = path * ".part"
    published = false
    try
        # Write directly to disk instead of base64-encoding a large image in stdout.
        open(partial, "w") do io
            raw ? write(io, value) : Base.invokelatest(show, io, mime, value)
        end
        size = filesize(partial)
        0 < size <= d.limit || throw(ArgumentError("Plot exceeds byte limit or is empty"))
        mv(partial, path)
        published = true
        d.notify(string(mime), name, size)
    catch
        rm(partial; force=true)
        published && rm(path; force=true)
        rethrow()
    end
    nothing
end

function Base.display(d::EditorDisplay, value)
    for format in d.formats
        mime = supported[format]
        if Base.invokelatest(showable, mime, value)
            display(d, mime, value)
            return nothing
        end
    end
    throw(MethodError(display, (d, value)))
end

"Display a returned rich value, retaining text-only behavior for ordinary values."
function display_result(d::EditorDisplay, value)
    any(f -> Base.invokelatest(showable, supported[f], value), d.formats) || return false
    display(d, value)
    true
end

end
