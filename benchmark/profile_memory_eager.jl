# Memory-allocation profile of the FastKML EAGER hot path
# (KMLFile materialization + DataFrame extraction).
#
# Counterpart to profile_memory.jl (which profiles the default lazy path).
# Used to identify the dominant allocation sites when reading via
# `read(path, KMLFile)` — relevant for the v0.4 migration where the eager
# path is competitive but URL4/URL6 still lag GDAL.
#
# Usage:
#
#   julia --project=benchmark --track-allocation=user \
#         benchmark/profile_memory_eager.jl [/path/to/file.kml]
#
# After the run, summarize hot spots with Coverage.analyze_malloc.

using FastKML, DataFrames, Dates
using Profile

const DEFAULT_PATH = joinpath(
    homedir(),
    ".julia",
    "scratchspaces",
    "00000000-0000-0000-0000-000000000000",
    "KMLBenchmarkCache",
    "WRS-2_bound_world_0.kml",   # URL4 — eager URL4 is the worst case currently
)

const KML_PATH = isempty(ARGS) ? DEFAULT_PATH : ARGS[1]

isfile(KML_PATH) || error("KML file not found: $KML_PATH")

println("Profiling EAGER target: ", KML_PATH)
println("File size: ", round(filesize(KML_PATH) / 1024^2; digits = 2), " MiB")

# --- Warm-up -----------------------------------------------------------------
println("[$(Dates.format(now(), "HH:MM:SS"))] warm-up …")
warm_t = @elapsed begin
    df_warm = DataFrame(KML_PATH; layer = 1, lazy = false)
    nrow(df_warm), ncol(df_warm)
    df_warm = nothing
end
GC.gc()
println("  warm-up: ", round(warm_t * 1000; digits = 1), " ms")

# --- Reset counters and run the measured call --------------------------------
Profile.clear_malloc_data()
println("[$(Dates.format(now(), "HH:MM:SS"))] measured eager run …")
meas_t = @elapsed df = DataFrame(KML_PATH; layer = 1, lazy = false)
println("  measured: ", round(meas_t * 1000; digits = 1), " ms")
println("  result : ", nrow(df), " rows × ", ncol(df), " cols")

println("\n.mem files written next to each touched .jl source — analyze with:")
println("""
  julia -e 'using Pkg; Pkg.activate(temp=true); Pkg.add("Coverage");
            using Coverage;
            ms = vcat(analyze_malloc("src"), analyze_malloc("dev/XML.jl-v0.4/src"));
            sort!(ms, by = m -> m.bytes, rev = true);
            for m in first(ms, 30); println(m); end'
""")
