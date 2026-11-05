module ContentWarnings

export @content_warn, with_content_warnings

using OrderedCollections: OrderedDict

# Warnings about the content of a file: an element without a field, a value that does not
# convert, an element that the writer leaves out. Each has a kind, such as
# `(:unhandled_tag, tag)`. On Julia 1.11 and later, a read, a write or a table counts them
# by kind (`with_content_warnings`), and gives one warning per kind when it ends, with the
# number of elements. Elsewhere, and on Julia 1.10, each kind is shown once per session.

# The first occurrence of a kind, and how many there were.
mutable struct Note
    message::String
    kwargs::NamedTuple
    _module::Module
    file::String
    line::Int
    count::Int
end

@static if isdefined(Base, :ScopedValues)
    const NOTES = Base.ScopedValues.ScopedValue{Union{Nothing,OrderedDict{Any,Note}}}(nothing)
    current() = NOTES[]

    function with_content_warnings(f)
        # Within a read or a write already: one count for the whole of it.
        NOTES[] === nothing || return f()
        notes = OrderedDict{Any,Note}()
        try
            return Base.ScopedValues.with(f, NOTES => notes)
        finally
            foreach(summarize, values(notes))
        end
    end
else
    current() = nothing
    with_content_warnings(f) = f()
end

# Counts an occurrence of `kind`; true for the first one, whose message is then kept.
function first!(notes, kind)
    note = get(notes, kind, nothing)
    note === nothing && return true
    note.count += 1
    return false
end

keep!(notes, kind, message, kwargs, _module, file, line) =
    (notes[kind] = Note(String(message), kwargs, _module, file, line, 1); nothing)

function summarize(note::Note)
    if note.count == 1
        @warn note.message note.kwargs... _module = note._module _file = note.file _line = note.line
    else
        @warn note.message note.kwargs... elements = note.count _module = note._module _file = note.file _line = note.line
    end
end

"""
    @content_warn kind message key=value…

A warning about the content of a file. Within a read, a write or a table on Julia 1.11 and
later, it is counted by `kind`, and the message is built only for the first occurrence.
Elsewhere, and on Julia 1.10, it is shown once per session for each `kind`.
"""
macro content_warn(kind, message, kws...)
    file = String(something(__source__.file, :none))
    line = __source__.line
    params = Expr(:parameters, (kw isa Expr && kw.head === :(=) ? Expr(:kw, kw.args...) : kw for kw in kws)...)
    k, notes = gensym("kind"), gensym("notes")   # no clash with the caller's names
    warn = Expr(:macrocall, Symbol("@warn"), __source__,
                :(string($message, " (shown once per session)")), kws..., :(_id = $k), :(maxlog = 1))
    return esc(quote
        let $k = $kind, $notes = $ContentWarnings.current()
            if $notes === nothing
                $warn
            elseif $ContentWarnings.first!($notes, $k)
                $ContentWarnings.keep!($notes, $k, $message, $(Expr(:tuple, params)), @__MODULE__, $file, $line)
            end
        end
    end)
end

end # module
