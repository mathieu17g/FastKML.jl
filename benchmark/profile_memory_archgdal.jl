# Memory-allocation profile of the ArchGDAL hot path on a representative
# KML file. Mirror of `profile_memory.jl`, used to provide a baseline for
# comparison: most of ArchGDAL's work happens in C++/GDAL (and is invisible
# to Julia's allocation tracker), so the .mem files below capture only the
# Julia-side wrapper allocations during DataFrame construction.
#
# Usage:
#
#   julia --project=benchmark --track-allocation=user \
#         benchmark/profile_memory_archgdal.jl [/path/to/file.kml]

using ArchGDAL, DataFrames, Dates
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

# Mirror the benchmark's `table_with_archgdal`: concatenate every layer.
function table_with_archgdal(path)
    ArchGDAL.read(path) do dataset
        n = ArchGDAL.nlayer(dataset)
        n == 0 && return DataFrame()
        n == 1 && return DataFrame(ArchGDAL.getlayer(dataset, 0))
        dfs = [DataFrame(ArchGDAL.getlayer(dataset, k)) for k in 0:n-1]
        return vcat(dfs...; cols = :union)
    end
end

# --- Warm-up -----------------------------------------------------------------
println("[$(Dates.format(now(), "HH:MM:SS"))] warm-up …")
warm_t = @elapsed begin
    df_warm = table_with_archgdal(KML_PATH)
    nrow(df_warm), ncol(df_warm)
    df_warm = nothing
end
GC.gc()
println("  warm-up: ", round(warm_t * 1000; digits = 1), " ms")

# --- Reset counters and run the measured call --------------------------------
Profile.clear_malloc_data()
println("[$(Dates.format(now(), "HH:MM:SS"))] measured run …")
meas_t = @elapsed df = table_with_archgdal(KML_PATH)
println("  measured: ", round(meas_t * 1000; digits = 1), " ms")
println("  result : ", nrow(df), " rows × ", ncol(df), " cols")
