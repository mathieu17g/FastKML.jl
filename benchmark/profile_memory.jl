# Memory-allocation profile of the FastKML hot path on a representative
# KML file. Runs under `julia --track-allocation=user`, which writes
# `*.mem` files alongside each touched `.jl` source. `Profile.clear_malloc_data()`
# resets the counters between the warm-up call (which would otherwise be
# dominated by JIT compilation allocations) and the measured call.
#
# Usage:
#
#   julia --project=benchmark --track-allocation=user \
#         benchmark/profile_memory.jl [/path/to/file.kml]
#
# After the run, summarize hot spots with Coverage.analyze_malloc, e.g.:
#
#   julia -e 'using Pkg; Pkg.activate(temp=true); Pkg.add("Coverage");
#             using Coverage;
#             ms = analyze_malloc("src");
#             sort!(ms, by = m -> m.bytes, rev = true);
#             for m in first(ms, 20); println(m); end'

using FastKML, DataFrames, Dates
using Profile

const DEFAULT_PATH = joinpath(
    homedir(),
    ".julia",
    "scratchspaces",
    "00000000-0000-0000-0000-000000000000",
    "KMLBenchmarkCache",
    "enzone2022.kml",
)

const KML_PATH = isempty(ARGS) ? DEFAULT_PATH : ARGS[1]

isfile(KML_PATH) || error("KML file not found: $KML_PATH")

println("Profiling target: ", KML_PATH)
println("File size: ", round(filesize(KML_PATH) / 1024^2; digits = 2), " MiB")

# --- Warm-up -----------------------------------------------------------------
println("[$(Dates.format(now(), "HH:MM:SS"))] warm-up …")
warm_t = @elapsed begin
    df_warm = DataFrame(KML_PATH; layer = 1)
    nrow(df_warm), ncol(df_warm)
    df_warm = nothing
end
GC.gc()
println("  warm-up: ", round(warm_t * 1000; digits = 1), " ms")

# --- Reset counters and run the measured call --------------------------------
Profile.clear_malloc_data()
println("[$(Dates.format(now(), "HH:MM:SS"))] measured run …")
meas_t = @elapsed df = DataFrame(KML_PATH; layer = 1)
println("  measured: ", round(meas_t * 1000; digits = 1), " ms")
println("  result : ", nrow(df), " rows × ", ncol(df), " cols")

println("\n.mem files written next to each touched .jl source — analyze with Coverage.analyze_malloc.")
