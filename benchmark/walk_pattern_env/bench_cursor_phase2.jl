# benchmark/walk_pattern_env/bench_cursor_phase2.jl
#
# Phase 2 re-bench: measure XML.Cursor next!() DFS allocations on the bitstype
# `Token` branch, against the Phase-1 baseline (103 ms / 305 MiB / 4.0M allocs)
# and the tech-4 target (57 ms / 123 MiB / 1.9M allocs).
#
# Usage:
#   julia --project=benchmark/walk_pattern_env \
#         benchmark/walk_pattern_env/bench_cursor_phase2.jl <dev_path>
# <dev_path> = the XML.jl checkout to develop against (the bitstype-Token branch).

using Pkg
const DEV_PATH = isempty(ARGS) ? error("usage: bench_cursor_phase2.jl <dev_path>") : ARGS[1]
isdir(DEV_PATH) || error("dev path does not exist: $DEV_PATH")
Pkg.activate(; temp=true)
Pkg.develop(path=DEV_PATH)
Pkg.add(["BenchmarkTools", "Printf", "Statistics"])

using XML
using XML: Cursor, next!, nodetype, tag, value, Element, Text
using BenchmarkTools, Printf, Statistics

# synthetic doc generator (verbatim from walk_pattern.jl / decompose_techniques.jl)
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

# Advance-only: pure cursor cost — isolates the per-token allocation that the
# bitstype Token is meant to remove.
function cursor_advance_only(str)
    c = parse(Cursor, str)
    acc = 0
    while next!(c) !== nothing
        acc += 1
    end
    acc
end

# Full walk: advance + extract value/tag at each node (accumulate byte lengths so
# the calls aren't elided). Mirrors walk4_full / a real consumer pass.
function cursor_full(str)
    c = parse(Cursor, str)
    acc = 0
    while next!(c) !== nothing
        nt = nodetype(c)
        if nt === Element
            t = tag(c)
            t === nothing || (acc += ncodeunits(t))
        elseif nt === Text
            v = value(c)
            v === nothing || (acc += ncodeunits(v))
        end
    end
    acc
end

function measure(label, f, str)
    b = @benchmark $f($str) seconds=3
    t_ms = median(b.times) / 1e6
    m_mib = b.memory / 1024^2
    @printf("  %-28s %8.2f ms / %8.2f MiB / %10d allocs\n", label, t_ms, m_mib, b.allocs)
    (t_ms, m_mib, b.allocs)
end

const N = 100_000
str = generate_doc(N)
@printf("\n=== Cursor Phase-2 re-bench, N = %d placemarks (%.1f MiB) ===\n", N, sizeof(str)/1024^2)
@printf("Dev path: %s\n", DEV_PATH)
@printf("Julia %s, %s %s\n\n", VERSION, Sys.KERNEL, Sys.ARCH)
@printf("isbitstype(XML.XMLTokenizer.Token) = %s\n", isbitstype(XML.XMLTokenizer.Token))
@printf("sizeof(Token) = %d bytes\n\n", sizeof(XML.XMLTokenizer.Token))

# correctness sanity: both walkers visit the same node count region
@printf("nodes advanced = %d\n", cursor_advance_only(str))

println("\n== Cursor next!() DFS ==")
adv = measure("advance-only", cursor_advance_only, str)
full = measure("full (value extraction)", cursor_full, str)

println("\n── Reference points ──")
@printf("  %-28s %8s    %8s    %10s\n", "", "ms", "MiB", "allocs")
@printf("  %-28s %8.0f    %8.0f    %10d\n", "Phase-1 cursor (SubString)", 103, 305, 4_000_000)
@printf("  %-28s %8.0f    %8.0f    %10d\n", "tech-4 target (v0.3.8+#59)", 57, 123, 1_900_000)
@printf("  %-28s %8.2f    %8.2f    %10d   <- bitstype now (full)\n", "Phase-2 cursor (bitstype)", full[1], full[2], full[3])
