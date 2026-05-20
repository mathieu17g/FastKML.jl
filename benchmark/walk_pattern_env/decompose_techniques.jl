# benchmark/walk_pattern_env/decompose_techniques.jl
#
# Companion to walk_pattern.jl — decomposes technique-4 and technique-6
# walk cost into parse / cursor-advance / value-extraction phases for an
# apples-to-apples comparison.
#
# Usage:
#   julia --project=benchmark/walk_pattern_env benchmark/walk_pattern_env/decompose_techniques.jl <dev_path>
#
# <dev_path> is the local checkout of XML.jl to develop against. Run twice
# with the two paths to get both halves of the comparison:
#   - dev/XML.jl         (== v0.3.8 + PR #58 + PR #59) → measures technique 4
#   - dev/XML.jl-v0.4    (== v0.4.0)                  → measures technique 6
#
# Technique 4 needs XML.next!() (v0.3.x + PR #59).
# Technique 6 needs XML.Tokenizer + XML.XMLTokenizer (v0.4 only).
# The script auto-detects which technique to measure based on which symbols
# are present.

using Pkg

const DEV_PATH = isempty(ARGS) ? error("usage: decompose_techniques.jl <dev_path>") : ARGS[1]
isdir(DEV_PATH) || error("dev path does not exist: $DEV_PATH")

Pkg.activate(; temp=true)
Pkg.develop(path=DEV_PATH)
Pkg.add(["BenchmarkTools", "Printf"])

using XML
using BenchmarkTools
using Printf

# ── synthetic doc generator (verbatim from walk_pattern.jl) ──
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

# ── tech 4 walkers (only valid when next! exists) ──

# Advance-only (no value extraction): isolates pure cursor cost
if isdefined(XML, :next!)
    function walk4_advance_only(root::XML.LazyNode, acc::Ref{Int})
        o = root
        while XML.next!(o) !== nothing
            nt = XML.nodetype(o)
            acc[] += Int(nt === XML.Text || nt === XML.CData)
        end
        nothing
    end

    # Full tech 4 walk: advance + value extraction
    function walk4_full(root::XML.LazyNode, acc::Ref{Int})
        o = root
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

# ── tech 6 walkers (only valid when v0.4 Tokenizer exists) ──

if isdefined(XML, :eachchildnode)
    # Tech 3: eachchildnode iterator (v0.4 only)
    function walk3_full(node::XML.LazyNode, acc::Ref{Int})
        for child in XML.eachchildnode(node)
            nt = XML.nodetype(child)
            if nt === XML.Element
                walk3_full(child, acc)
            elseif nt === XML.Text || nt === XML.CData
                v = XML.value(child)
                v !== nothing && (acc[] += length(v))
            end
        end
        nothing
    end
end

if isdefined(XML, :Tokenizer)
    # Advance-only tech 6: recursive walk WITHOUT XML.value() calls
    # (still allocates a LazyNode per child — that cost is intrinsic to tech 6)
    function walk6_advance_only(node::XML.LazyNode, acc::Ref{Int})
        data = node.data
        start_pos = node.token.raw.offset + 1
        tokenizer = XML.Tokenizer(data, start_pos)
        state = XML.TokenizerState(start_pos, XML.XMLTokenizer.M_DEFAULT,
                                   XML.XMLTokenizer.no_token(data))
        is_elem = XML.nodetype(node) === XML.Element

        if is_elem
            while true
                result = iterate(tokenizer, state)
                result === nothing && return
                token, state = result
                k = token.kind
                k === XML.XMLTokenizer.TOKEN_SELF_CLOSE && return
                k === XML.XMLTokenizer.TOKEN_TAG_CLOSE && break
            end
        end

        while true
            result = iterate(tokenizer, state)
            result === nothing && return
            token, state = result
            k = token.kind
            if k === XML.XMLTokenizer.TOKEN_OPEN_TAG
                child = XML.LazyNode(data, token, XML.Element)
                walk6_advance_only(child, acc)
                state = _skip_subtree_synth!(tokenizer, state)
            elseif k === XML.XMLTokenizer.TOKEN_TEXT
                # No XML.value() call — just count the kind hit
                acc[] += 1
            elseif k === XML.XMLTokenizer.TOKEN_CDATA_OPEN
                acc[] += 1
                state = _skip_until_synth!(tokenizer, state,
                                           XML.XMLTokenizer.TOKEN_CDATA_CLOSE)
            elseif k === XML.XMLTokenizer.TOKEN_CLOSE_TAG
                return
            end
        end
    end

    # Full tech 6 walk: advance + LazyNode allocation per child + value extraction
    # (mirrors walk_raw_tokenizer_recursive from walk_pattern.jl)
    function walk6_full(node::XML.LazyNode, acc::Ref{Int})
        data = node.data
        start_pos = node.token.raw.offset + 1
        tokenizer = XML.Tokenizer(data, start_pos)
        state = XML.TokenizerState(start_pos, XML.XMLTokenizer.M_DEFAULT,
                                   XML.XMLTokenizer.no_token(data))
        is_elem = XML.nodetype(node) === XML.Element

        if is_elem
            while true
                result = iterate(tokenizer, state)
                result === nothing && return
                token, state = result
                k = token.kind
                k === XML.XMLTokenizer.TOKEN_SELF_CLOSE && return
                k === XML.XMLTokenizer.TOKEN_TAG_CLOSE && break
            end
        end

        while true
            result = iterate(tokenizer, state)
            result === nothing && return
            token, state = result
            k = token.kind
            if k === XML.XMLTokenizer.TOKEN_OPEN_TAG
                child = XML.LazyNode(data, token, XML.Element)
                walk6_full(child, acc)
                state = _skip_subtree_synth!(tokenizer, state)
            elseif k === XML.XMLTokenizer.TOKEN_TEXT
                child = XML.LazyNode(data, token, XML.Text)
                v = XML.value(child)
                v !== nothing && (acc[] += length(v))
            elseif k === XML.XMLTokenizer.TOKEN_CDATA_OPEN
                child = XML.LazyNode(data, token, XML.CData)
                v = XML.value(child)
                v !== nothing && (acc[] += length(v))
                state = _skip_until_synth!(tokenizer, state,
                                           XML.XMLTokenizer.TOKEN_CDATA_CLOSE)
            elseif k === XML.XMLTokenizer.TOKEN_CLOSE_TAG
                return
            end
        end
    end

    @inline function _skip_subtree_synth!(tokenizer, state)
        depth = 1
        while true
            result = iterate(tokenizer, state)
            result === nothing && return state
            token, state = result
            k = token.kind
            if k === XML.XMLTokenizer.TOKEN_OPEN_TAG
                depth += 1
            elseif k === XML.XMLTokenizer.TOKEN_SELF_CLOSE
                depth -= 1
                depth == 0 && return state
            elseif k === XML.XMLTokenizer.TOKEN_CLOSE_TAG
                depth -= 1
                if depth == 0
                    result = iterate(tokenizer, state)
                    return result === nothing ? state : result[2]
                end
            end
        end
    end

    @inline function _skip_until_synth!(tokenizer, state, target_kind)
        while true
            result = iterate(tokenizer, state)
            result === nothing && return state
            token, state = result
            token.kind === target_kind && return state
        end
    end
end

# ── measurement harness ──

function measure(label, expr_quoted)
    b = eval(:(@benchmark $expr_quoted seconds=3))
    t_ms = median(b.times) / 1e6
    m_mib = b.memory / 1024^2
    allocs = b.allocs
    @printf("  %-32s %8.2f ms / %7.1f MiB / %10d allocs\n", label, t_ms, m_mib, allocs)
    return (t_ms, m_mib, allocs)
end

# ── main ──

const N = 100_000
str = generate_doc(N)
@printf("\n=== Decomposition bench on N = %d placemarks (%.1f MiB) ===\n", N, sizeof(str) / 1024^2)
@printf("Dev path: %s\n", DEV_PATH)
@printf("Julia %s, %s %s\n\n", VERSION, Sys.KERNEL, Sys.ARCH)

# Common: parse-only (independent of technique)
println("== Parse-only ==")
parse_t, parse_m, parse_a = measure("parse(str, XML.LazyNode)",
                                     :(parse($str, XML.LazyNode)))

if isdefined(XML, :next!)
    println("\n== Technique 4 (next!() DFS) ==")
    t4_adv = measure("parse + advance-only", :(walk4_advance_only(parse($str, XML.LazyNode), Ref(0))))
    t4_full = measure("parse + full walk", :(walk4_full(parse($str, XML.LazyNode), Ref(0))))

    println("\n  Decomposition (by subtraction):")
    @printf("  %-32s %8.2f ms / %7.1f MiB\n", "parse",
            parse_t, parse_m)
    @printf("  %-32s %8.2f ms / %7.1f MiB\n", "cursor advance",
            t4_adv[1] - parse_t, t4_adv[2] - parse_m)
    @printf("  %-32s %8.2f ms / %7.1f MiB\n", "value extraction",
            t4_full[1] - t4_adv[1], t4_full[2] - t4_adv[2])
    println("  ", "─" ^ 70)
    @printf("  %-32s %8.2f ms / %7.1f MiB / %10d allocs\n", "total (parse + walk)",
            t4_full[1], t4_full[2], t4_full[3])
    @printf("  %-32s %8.2f ms / %7.1f MiB\n", "walk-only (advance + value)",
            t4_full[1] - parse_t, t4_full[2] - parse_m)
end

if isdefined(XML, :eachchildnode)
    println("\n== Technique 3 (eachchildnode) ==")
    lazy_root_3 = parse(str, XML.LazyNode)
    t3_full = measure("walk-only full", :(walk3_full($lazy_root_3, Ref(0))))
end

if isdefined(XML, :Tokenizer)
    println("\n== Technique 6 (raw Tokenizer + recursive LazyNode) ==")
    # Tech 6's recursive walker takes a pre-parsed LazyNode root
    lazy_root = parse(str, XML.LazyNode)
    t6_adv = measure("walk-only advance (no value)", :(walk6_advance_only($lazy_root, Ref(0))))
    t6_full = measure("walk-only full",              :(walk6_full($lazy_root, Ref(0))))

    println("\n  Decomposition (by subtraction):")
    @printf("  %-32s %8.2f ms / %7.1f MiB\n", "parse (= shared with tech 4)",
            parse_t, parse_m)
    @printf("  %-32s %8.2f ms / %7.1f MiB\n", "advance + LazyNode-per-child",
            t6_adv[1], t6_adv[2])
    @printf("  %-32s %8.2f ms / %7.1f MiB\n", "value extraction (delta)",
            t6_full[1] - t6_adv[1], t6_full[2] - t6_adv[2])
    println("  ", "─" ^ 70)
    @printf("  %-32s %8.2f ms / %7.1f MiB / %10d allocs\n", "walk-only total",
            t6_full[1], t6_full[2], t6_full[3])
    @printf("  %-32s %8.2f ms / %7.1f MiB\n", "implied parse + walk total",
            parse_t + t6_full[1], parse_m + t6_full[2])
end
