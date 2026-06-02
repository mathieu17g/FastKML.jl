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
const SECS  = 5

@printf("\n%-6s %7s  %-12s  %10s %10s %10s   (ms / MiB)\n",
        "file", "rows", "curs==lazy", "lazy", "cursor", "gdal")
println("─"^78)

for (name, url) in CASES
    try
        path = fetch_kml_or_kmz(url)
        df_lazy = table_with_fastkml(path)
        df_curs = table_with_fastkml_cursor(path)
        same = isequal(df_lazy, df_curs)

        bl = @benchmark table_with_fastkml($path)        seconds = SECS
        bc = @benchmark table_with_fastkml_cursor($path) seconds = SECS
        bg = @benchmark table_with_archgdal($path)       seconds = SECS

        ml, mc, mg = median(bl).time/1e6, median(bc).time/1e6, median(bg).time/1e6
        mbl, mbc, mbg = bl.memory/1024^2, bc.memory/1024^2, bg.memory/1024^2
        @printf("%-6s %7d  %-12s  %5.0f/%-4.0f %5.0f/%-4.0f %5.0f/%-4.0f\n",
                name, nrow(df_lazy), string(same), ml, mbl, mc, mbc, mg, mbg)
    catch e
        @printf("%-6s  ERROR: %s\n", name, sprint(showerror, e))
    end
end
