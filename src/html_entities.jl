module HtmlEntities

export decode_named_entities

using Automa, Downloads, JSON3, Serialization, Scratch

# ────────────────────────────────────────────────────────────────────
# 1.  Scratch-space cache
# ────────────────────────────────────────────────────────────────────
const ENTITY_URL = "https://html.spec.whatwg.org/entities.json"

# Create (or reuse) a scratch directory keyed by *this* package
const CACHE_DIR = Scratch.@get_scratch!("html_entities_automa")
const CACHE_FILE = joinpath(CACHE_DIR, "entities.bin")

function _load_entities()
    # Fast path: read the already–serialised Dict
    if isfile(CACHE_FILE)
        try
            return open(deserialize, CACHE_FILE)
        catch err
            @warn "Scratch cache unreadable – rebuilding" exception = err
        end
    end

    # Slow path: download the JSON and build the Dict once
    json = JSON3.read(read(Downloads.download(ENTITY_URL), String))
    tbl = Dict{String,String}()
    for (ksym, v) in json               # ksym :: Symbol  (e.g. :&le;)
        k = String(ksym)                # "≤"   ← now a String
        name = k[2:end-1]               # strip leading '&' and trailing ';'
        cps = collect(v["codepoints"])  # JSON3.Array → Vector{Int}
        tbl[name] = String(Char.(cps))  # "≤"  (or multi-char)
    end

    # Atomically write the binary cache for the next run
    mkpath(CACHE_DIR)
    open(CACHE_FILE * ".tmp", "w") do io
        serialize(io, tbl)
    end
    mv(CACHE_FILE * ".tmp", CACHE_FILE; force = true)
    return tbl
end

const NAMED_HTML_ENTITIES = _load_entities()      # loaded once per session

# ────────────────────────────────────────────────────────────────────
# 2.  Automa state machine (single–pass scanner)
# ────────────────────────────────────────────────────────────────────
patterns = [
    re"&#[0-9]+;",        # decimal numeric – leave untouched
    re"&#x[0-9A-Fa-f]+;", # hexadecimal numeric – leave untouched
    re"&[A-Za-z0-9]+;",   # named entity – decode if it's in the Dict
    re"[^&]+",            # run of text without '&'
    re"&",                 # a stray '&'
]
make_tokenizer(patterns) |> eval    # defines `tokenize(UInt32, str)`

"""
    decode_named_entities(str) -> String

Replace **named** HTML entities (e.g. `&amp;`, `&le;`) in `str`
with their Unicode characters.
Numeric entities and unknown names are copied verbatim.
"""
function decode_named_entities(str::AbstractString)::String
    out = IOBuffer()
    for (pos, len, tok) in tokenize(UInt32, str)
        frag = @view str[pos:pos+len-1]
        if tok == 3                       # named entity
            name = frag[2:end-1]          # strip '&' and ';'
            write(out, get(NAMED_HTML_ENTITIES, name, frag))
        else                              # numeric / text / stray '&'
            write(out, frag)
        end
    end
    return String(take!(out))
end

end # module HtmlEntities