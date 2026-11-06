module ContentWarnings

export @content_warn, with_content_warnings

using OrderedCollections: OrderedDict, OrderedSet

# Warnings about the content of a file: an element without a field, a value that does not
# convert, an element that the writer leaves out. Each has a kind, such as
# `(:unhandled_tag, tag)`. On Julia 1.11 and later, a read, a write or a table counts them
# by kind (`with_content_warnings`), and gives one warning per kind when it ends, with the
# number of elements. Elsewhere, and on Julia 1.10, each kind is shown once per session.

# The distinct values noted for a kind, at most: beyond, the warning says "100 or more".
const MAX_VALUES = 100

# The first occurrence of a kind, how many there were, and their distinct values.
mutable struct Note
    message::String
    kwargs::NamedTuple
    _module::Module
    file::String
    line::Int
    count::Int
    values::OrderedSet{Any}
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
    (notes[kind] = Note(String(message), kwargs, _module, file, line, 1, OrderedSet{Any}()); nothing)

# Notes the value that an occurrence of `kind` shows, up to `MAX_VALUES` distinct values.
function cite!(notes, kind, value)
    values = notes[kind].values
    if length(values) < MAX_VALUES && !(value in values)
        push!(values, value isa AbstractString ? String(value) : value)
    end
    return nothing
end

function summarize(note::Note)
    # The number of elements and, when they differ in the value that the warning shows, of
    # their distinct values, with the first three.
    k = length(note.values)
    counts = note.count == 1 ? (;) :
             k < 2 ? (elements = note.count,) :
             (elements = note.count, distinct = k < MAX_VALUES ? k : Base.Text("$MAX_VALUES or more"),
              examples = Tuple(Iterators.take(note.values, 3)))
    @warn note.message note.kwargs... counts... _module = note._module _file = note.file _line = note.line
end

"""
    @content_warn kind message key=value… example=value

A warning about the content of a file. Within a read, a write or a table on Julia 1.11 and
later, it is counted by `kind`, and the message is built only for the first occurrence.
Elsewhere, and on Julia 1.10, it is shown once per session for each `kind`.

`example` repeats the value that the warning shows, when the elements of one kind can
differ in it, such as the text of a date. The logger does not receive it: when the elements
differ in it, the count gives the number of distinct values, up to $MAX_VALUES, and the
first three.
"""
macro content_warn(kind, message, kws...)
    file = String(something(__source__.file, :none))
    line = __source__.line
    k, notes = gensym("kind"), gensym("notes")   # no clash with the caller's names
    # `example = value` goes to the count, not to the logger.
    isexample(kw) = kw isa Expr && kw.head === :(=) && kw.args[1] === :example
    i = findfirst(isexample, kws)
    cite = i === nothing ? nothing : :($ContentWarnings.cite!($notes, $k, $(kws[i].args[2])))
    kws = filter(!isexample, kws)
    params = Expr(:parameters, (kw isa Expr && kw.head === :(=) ? Expr(:kw, kw.args...) : kw for kw in kws)...)
    warn = Expr(:macrocall, Symbol("@warn"), __source__,
                :(string($message, " (shown once per session)")), kws..., :(_id = $k), :(maxlog = 1))
    return esc(quote
        let $k = $kind, $notes = $ContentWarnings.current()
            if $notes === nothing
                $warn
            else
                if $ContentWarnings.first!($notes, $k)
                    $ContentWarnings.keep!($notes, $k, $message, $(Expr(:tuple, params)), @__MODULE__, $file, $line)
                end
                $cite
            end
        end
    end)
end

end # module
