#!/usr/bin/env julia
###############################################################################
# Scaling benchmark for FastKML.jl — synthetic Point-only KMLs at four sizes
# (100 / 1 000 / 5 000 / 20 000 Placemarks). Reports time + memory +
# throughput for:
#   1. read(file, KMLFile)
#   2. DataFrame(file; layer = 1)
#
# Run with:
#   julia --project=benchmark benchmark/scaling_benchmark.jl
#
# Complementary to `benchmark_kml_parsers.jl`, which fetches real-world
# KML/KMZ fixtures and compares against ArchGDAL — useful for parity but
# slower and dependent on cached downloads. This script stays
# self-contained: no network, just FastKML on synthetic Points.
###############################################################################

using BenchmarkTools
using Statistics
using Dates
using FastKML
using DataFrames

function create_test_kml(n_placemarks::Int; filename = "test.kml")
    open(filename, "w") do io
        println(io, """<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document>
    <name>Test Document</name>
    <Folder>
      <name>Test Folder</name>""")
        for i = 1:n_placemarks
            lat = -90 + 180 * rand()
            lon = -180 + 360 * rand()
            println(io, """      <Placemark>
        <name>Place $i</name>
        <description>Description for place $i</description>
        <Point><coordinates>$lon,$lat,0</coordinates></Point>
      </Placemark>""")
        end
        println(io, """    </Folder>
  </Document>
</kml>""")
    end
end

const TEST_SIZES = [
    ("Small",  100),
    ("Medium", 1_000),
    ("Large",  5_000),
    ("XLarge", 20_000),
]

println("="^80)
println("FastKML.jl scaling benchmark — synthetic Point-only KMLs")
println("="^80)
println("Julia: v$VERSION")
println("Date:  $(Dates.now())")

# ── Benchmark 1: KMLFile reading ────────────────────────────────────────────
println("\n", "="^80)
println("BENCHMARK 1: read(file, KMLFile)")
println("="^80)

reading_results = []

for (size_name, n) in TEST_SIZES
    println("\n## $size_name ($n placemarks)")
    test_file = "test_$(size_name).kml"
    create_test_kml(n; filename = test_file)
    file_size_mb = filesize(test_file) / 1024^2
    println("File size: $(round(file_size_mb, digits = 2)) MB")

    GC.gc()
    bench = @benchmark read($test_file, FastKML.KMLFile) samples = 5 seconds = 3
    time_ms = median(bench).time / 1e6
    memory_mb = median(bench).memory / 1024^2
    push!(reading_results, (size_name, n, file_size_mb, time_ms, memory_mb))

    println("  Time:   $(round(time_ms, digits = 2)) ms")
    println("  Memory: $(round(memory_mb, digits = 2)) MB")
    println("  Rate:   $(round(n / (time_ms / 1000), digits = 0)) placemarks/sec")
    rm(test_file; force = true)
end

# ── Benchmark 2: DataFrame extraction ───────────────────────────────────────
println("\n", "="^80)
println("BENCHMARK 2: DataFrame(file; layer = 1)")
println("="^80)

dataframe_results = []

for (size_name, n) in TEST_SIZES
    println("\n## $size_name ($n placemarks)")
    test_file = "test_$(size_name).kml"
    create_test_kml(n; filename = test_file)

    GC.gc()
    bench = @benchmark DataFrame($test_file; layer = 1) samples = 3 seconds = 3
    time_ms = median(bench).time / 1e6
    memory_mb = median(bench).memory / 1024^2
    push!(dataframe_results, (size_name, n, time_ms, memory_mb))

    println("  Time:   $(round(time_ms, digits = 2)) ms")
    println("  Memory: $(round(memory_mb, digits = 2)) MB")
    println("  Rate:   $(round(n / (time_ms / 1000), digits = 0)) placemarks/sec")
    rm(test_file; force = true)
end

# ── Summary ─────────────────────────────────────────────────────────────────
println("\n", "="^80)
println("SUMMARY")
println("="^80)

println("\n## KMLFile reading:")
println("Size      | Placemarks | File (MB) | Time (ms) | Memory (MB) | Rate (p/s)")
println("----------|------------|-----------|-----------|-------------|------------")
for (size, n, file_mb, time, mem) in reading_results
    println(
        "$(rpad(size, 9)) | $(lpad(n, 10)) | $(lpad(round(file_mb, digits = 2), 9)) | " *
        "$(lpad(round(time, digits = 1), 9)) | $(lpad(round(mem, digits = 1), 11)) | " *
        "$(lpad(round(n / (time / 1000), digits = 0), 10))",
    )
end

println("\n## DataFrame extraction:")
println("Size      | Placemarks | Time (ms) | Memory (MB) | Rate (p/s)")
println("----------|------------|-----------|-------------|------------")
for (size, n, time, mem) in dataframe_results
    println(
        "$(rpad(size, 9)) | $(lpad(n, 10)) | $(lpad(round(time, digits = 1), 9)) | " *
        "$(lpad(round(mem, digits = 1), 11)) | $(lpad(round(n / (time / 1000), digits = 0), 10))",
    )
end

println("\n✓ Benchmark complete!")
