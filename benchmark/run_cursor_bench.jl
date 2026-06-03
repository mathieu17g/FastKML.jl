# benchmark/run_cursor_bench.jl
#
# Phase 3b: compare the cursor-backed table path vs the LazyNode path vs ArchGDAL
# on the four real files (URL2/4/5/6). Checks content equivalence (cursor == lazy)
# first, then times each.
#
#   julia --project=benchmark benchmark/run_cursor_bench.jl

include(joinpath(@__DIR__, "benchmark_kml_parsers.jl"))
using BenchmarkTools, DataFrames, Printf, Statistics

const CASES = [("URL2", URL2), ("URL4", URL4), ("URL5", URL5), ("URL6", URL6)]
const SECS  = 10

@printf("\n%-6s %7s %-9s  %11s %11s %11s %11s   (ms / MiB)\n",
        "file", "rows", "cur==lazy", "v0.4 lazy", "v0.4 eager", "cursor", "ArchGDAL")
println("─"^88)

for (name, url) in CASES
    try
        path = fetch_kml_or_kmz(url)
        df_lazy = table_with_fastkml(path)
        df_curs = table_with_fastkml_cursor(path)
        same = isequal(df_lazy, df_curs)

        bl = @benchmark table_with_fastkml($path)        seconds = SECS
        be = @benchmark table_with_fastkml_eager($path)  seconds = SECS
        bc = @benchmark table_with_fastkml_cursor($path) seconds = SECS
        bg = @benchmark table_with_archgdal($path)       seconds = SECS

        m(b)  = median(b).time / 1e6
        mb(b) = b.memory / 1024^2
        @printf("%-6s %7d %-9s  %5.0f/%-5.0f %5.0f/%-5.0f %5.0f/%-5.0f %5.0f/%-5.0f\n",
                name, nrow(df_lazy), string(same),
                m(bl), mb(bl), m(be), mb(be), m(bc), mb(bc), m(bg), mb(bg))
    catch e
        @printf("%-6s  ERROR: %s\n", name, sprint(showerror, e))
    end
end
