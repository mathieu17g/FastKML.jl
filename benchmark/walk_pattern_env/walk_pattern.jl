# benchmark/walk_pattern_env/walk_pattern.jl
#
# Standalone synthetic benchmark reproducing the deep+repeated lazy walk
# pattern (the shape used by e.g. FastKML.jl).
#
# Designed to run on three XML.jl versions and produce a directly comparable
# table:
#
#   - v0.3.8 (registry)                — baseline
#   - v0.3.8 + PR #58 (ctx-share) + PR #59 (next!/prev!)
#   - v0.4.0 (PR #54: streaming tokenizer, immutable LazyNode, eachchildnode)
#
# Strategies tested:
#
#   1. Node + children()           — eager DOM, Vector-of-children field access
#   2. LazyNode + children()       — lazy, but children() eagerly materializes
#                                    a Vector{LazyNode} per call
#   3. LazyNode + eachchildnode()  — v0.4 only: streaming iterator over children
#   4. LazyNode + next!() DFS      — v0.3+#59 only: in-place mutation, DFS walk
#
# The walker is intentionally generic: every Element child is visited
# recursively; every Text/CData child's value length is accumulated into an
# Int (the compiler cannot elide the work, but no extra strings are allocated
# by the walker itself).
#
# Self-contained: only depends on XML, BenchmarkTools, Printf. No FastKML.
#
# Usage:
#   julia --project=benchmark/walk_pattern_env benchmark/walk_pattern_env/walk_pattern.jl

using XML
using BenchmarkTools
using Printf

# ──────────────────────────────────────────────────────────────────────────────
# Synthetic document generator
# ──────────────────────────────────────────────────────────────────────────────

"""
    generate_doc(n) -> String

Generate an XML document with `n` placemark-like nested elements:

    <root>
      <placemark>
        <name>Item 1</name>
        <description>Descriptive text for item 1 on row 1.</description>
        <point>
          <coordinates>-77.0369,38.9072,1.0</coordinates>
        </point>
      </placemark>
      ...
    </root>

Each entry has depth ≥ 4 (root → placemark → point → coordinates → text),
repeated `n` times. This is the shape that triggers O(n × depth) walk
allocations when iteration is not amortized.
"""
function generate_doc(n::Integer)
    io = IOBuffer()
    print(io, """<?xml version="1.0" encoding="UTF-8"?>\n<root>\n""")
    for i in 1:n
        print(io, "  <placemark>\n")
        print(io, "    <name>Item ", i, "</name>\n")
        print(io, "    <description>Descriptive text for item ", i, " on row ", i, ".</description>\n")
        print(io, "    <point>\n")
        print(io, "      <coordinates>-77.0369,38.9072,", i, ".0</coordinates>\n")
        print(io, "    </point>\n")
        print(io, "  </placemark>\n")
    end
    print(io, "</root>\n")
    String(take!(io))
end

# ──────────────────────────────────────────────────────────────────────────────
# Walkers — all four share the same accumulation shape; only iteration differs.
# ──────────────────────────────────────────────────────────────────────────────

# Strategy 1 — Node eager: children() returns existing Vector{Node}
function walk_node_eager(node::XML.Node, acc::Ref{Int})
    for child in XML.children(node)
        nt = XML.nodetype(child)
        if nt === XML.Element
            walk_node_eager(child, acc)
        elseif nt === XML.Text || nt === XML.CData
            v = XML.value(child)
            v !== nothing && (acc[] += length(v))
        end
    end
    nothing
end

# Strategy 2 — LazyNode naïve: children() materializes Vector{LazyNode} per call
function walk_lazy_children(node::XML.LazyNode, acc::Ref{Int})
    for child in XML.children(node)
        nt = XML.nodetype(child)
        if nt === XML.Element
            walk_lazy_children(child, acc)
        elseif nt === XML.Text || nt === XML.CData
            v = XML.value(child)
            v !== nothing && (acc[] += length(v))
        end
    end
    nothing
end

# Strategy 3 — v0.4 only: LazyNode streaming via eachchildnode()
if isdefined(XML, :eachchildnode)
    function walk_lazy_each(node::XML.LazyNode, acc::Ref{Int})
        for child in XML.eachchildnode(node)
            nt = XML.nodetype(child)
            if nt === XML.Element
                walk_lazy_each(child, acc)
            elseif nt === XML.Text || nt === XML.CData
                v = XML.value(child)
                v !== nothing && (acc[] += length(v))
            end
        end
        nothing
    end
end

# Strategy 4 — v0.3 + PR #59 only: LazyNode in-place mutation via next!()
# This is a flat DFS — equivalent to "visit every node in document order
# exactly once". It is the absolute lower bound: one LazyNode allocation for
# the whole document.
if isdefined(XML, :next!)
    function walk_lazy_next_dfs(root::XML.LazyNode, acc::Ref{Int})
        o = root  # mutable in-place — same wrapper throughout
        while XML.next!(o) !== nothing
            nt = XML.nodetype(o)
            if nt === XML.Text || nt === XML.CData
                v = XML.value(o)
                v !== nothing && (acc[] += length(v))
            end
        end
        nothing
    end
end

# Strategy 5 — v0.4 only: raw Tokenizer DFS via private XMLTokenizer module
#
# Direct use of `XML.Tokenizer` + `TokenizerState` iterator interface
# (imported into XML namespace from .XMLTokenizer but NOT exported).
# Both types are immutable structs (TokenizerState is explicitly marked
# SROA-friendly in v0.4); no Stateful wrapper, no LazyChildIterator,
# no LazyNode allocation per yielded child.
#
# Token kinds also live in XML.XMLTokenizer (not exported); we capture them
# once outside the loop to make the dispatch cheap.
#
# If this strategy matches or beats Strategy 4 (next!), it demonstrates that
# v0.4's tokenizer is the right primitive for a public zero-allocation walk
# API — and that the regression observed via `eachchildnode` is purely a
# matter of API surface, not of underlying capability.
if isdefined(XML, :Tokenizer)
    const _RAW_TOK_TEXT = XML.XMLTokenizer.TOKEN_TEXT
    const _RAW_TOK_CDATA = XML.XMLTokenizer.TOKEN_CDATA_CONTENT
    function walk_raw_tokenizer_dfs(data::AbstractString, acc::Ref{Int})
        tokenizer = XML.Tokenizer(data, 1)
        result = iterate(tokenizer)
        while result !== nothing
            token, state = result
            kind = token.kind
            if kind === _RAW_TOK_TEXT || kind === _RAW_TOK_CDATA
                acc[] += ncodeunits(token.raw)
            end
            result = iterate(tokenizer, state)
        end
        nothing
    end
end

# ──────────────────────────────────────────────────────────────────────────────
# Bench harness
# ──────────────────────────────────────────────────────────────────────────────

function bench_one(n::Integer; seconds::Real = 3.0)
    str = generate_doc(n)
    @printf("\n--- N = %d placemarks (%.1f KiB) ---\n", n, sizeof(str) / 1024)

    eager_root = parse(str, XML.Node)
    lazy_root  = parse(str, XML.LazyNode)

    @printf("%-32s %10s %14s %14s\n", "Strategy", "Time (ms)", "Allocs", "Memory (KiB)")
    println("─"^76)

    runs = Any[
        ("Node + children()",           :(walk_node_eager($eager_root, Ref(0)))),
        ("LazyNode + children()",       :(walk_lazy_children($lazy_root, Ref(0)))),
    ]
    if isdefined(XML, :eachchildnode)
        push!(runs, ("LazyNode + eachchildnode()", :(walk_lazy_each($lazy_root, Ref(0)))))
    end
    if isdefined(XML, :next!)
        # next! mutates root — we need a fresh LazyNode per benchmark sample
        push!(runs, ("LazyNode + next!() DFS",
                     :(walk_lazy_next_dfs(parse($str, XML.LazyNode), Ref(0)))))
    end
    if isdefined(XML, :Tokenizer)
        push!(runs, ("raw Tokenizer DFS (private API)",
                     :(walk_raw_tokenizer_dfs($str, Ref(0)))))
    end

    for (label, expr) in runs
        b = eval(:(@benchmark $expr seconds = $seconds))
        t_ms = median(b.times) / 1e6
        @printf("%-32s %10.3f %14d %14.1f\n", label, t_ms, b.allocs, b.memory / 1024)
    end
end

function main()
    println("=" ^ 76)
    println("Synthetic walk-pattern benchmark")
    println("  XML.jl version: ", pkgversion(XML))
    println("  eachchildnode available: ", isdefined(XML, :eachchildnode))
    println("  next! available:         ", isdefined(XML, :next!))
    println("  raw Tokenizer available: ", isdefined(XML, :Tokenizer))
    println("=" ^ 76)
    for n in (1_000, 10_000, 100_000)
        bench_one(n; seconds = 3.0)
    end
end

main()
