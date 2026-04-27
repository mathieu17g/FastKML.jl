#!/usr/bin/env julia

# Cross-branch benchmark script for KML.jl
# Final version with all fixes

using Pkg
using BenchmarkTools
using Statistics
using Dates
using KML

# Try to load optional packages
const HAS_DATAFRAMES = try
    using DataFrames
    true
catch
    false
end

const HAS_TABLES = try
    using Tables
    true
catch
    false
end

const HAS_JSON = try
    using JSON
    true
catch
    false
end

# Create test KML file (using standard <name> tags for compatibility)
function create_test_kml(n_placemarks::Int; filename="test.kml")
    open(filename, "w") do io
        println(io, """<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document>
    <name>Test Document</name>
    <Folder>
      <name>Test Folder</name>""")
        
        for i in 1:n_placemarks
            lat = -90 + 180 * rand()
            lon = -180 + 360 * rand()
            println(io, """      <Placemark>
        <name>Place $i</name>
        <description>Description for place $i</description>
        <Point>
          <coordinates>$lon,$lat,0</coordinates>
        </Point>
      </Placemark>""")
        end
        
        println(io, """    </Folder>
  </Document>
</kml>""")
    end
end

# Safe cleanup for Windows
function safe_cleanup(file)
    try
        if isfile(file)
            GC.gc()
            sleep(0.1)
            rm(file, force=true)
        end
    catch e
        @warn "Could not delete temp file: $file"
    end
end

# Detect available features
function detect_features()
    features = Dict{String, Bool}()
    
    # Check for LazyKMLFile
    features["LazyKMLFile"] = isdefined(KML, :LazyKMLFile)
    
    # Check for DataFrame support - only if PlacemarkTable exists or extension is loaded
    if HAS_DATAFRAMES
        features["DataFrame"] = isdefined(KML, :PlacemarkTable) || 
                               (isdefined(Base, :get_extension) && Base.get_extension(KML, :KMLDataFramesExt) !== nothing)
    else
        features["DataFrame"] = false
    end
    
    # Check for Tables.jl interface
    if HAS_TABLES
        features["Tables"] = Tables.istable(KML.KMLFile)
    else
        features["Tables"] = false
    end
    
    # Check for PlacemarkTable
    features["PlacemarkTable"] = isdefined(KML, :PlacemarkTable)
    
    return features
end

# Extract placemarks manually (improved for both branches)
function extract_placemarks_manual(kml::KML.KMLFile)
    placemarks = []
    
    # Helper function to recursively find placemarks
    function find_placemarks!(container, placemarks)
        # Check for Features field (capital F)
        if isdefined(container, :Features) && container.Features !== nothing
            for feature in container.Features
                if isa(feature, KML.Placemark)
                    push!(placemarks, feature)
                elseif isa(feature, KML.Document) || isa(feature, KML.Folder)
                    find_placemarks!(feature, placemarks)
                end
            end
        end
        
        # Check for features field (lowercase f)
        if isdefined(container, :features) && container.features !== nothing
            for feature in container.features
                if isa(feature, KML.Placemark)
                    push!(placemarks, feature)
                elseif isa(feature, KML.Document) || isa(feature, KML.Folder)
                    find_placemarks!(feature, placemarks)
                end
            end
        end
        
        # Check for children field
        if isdefined(container, :children) && container.children !== nothing
            for child in container.children
                if isa(child, KML.Placemark)
                    push!(placemarks, child)
                elseif isa(child, KML.Document) || isa(child, KML.Folder)
                    find_placemarks!(child, placemarks)
                end
            end
        end
    end
    
    # Search in KML file children
    if isdefined(kml, :children) && kml.children !== nothing
        for child in kml.children
            if isa(child, KML.Placemark)
                push!(placemarks, child)
            elseif isa(child, KML.Document) || isa(child, KML.Folder)
                find_placemarks!(child, placemarks)
            end
        end
    end
    
    # Also try direct Features if KMLFile has them
    if isdefined(kml, :Features) && kml.Features !== nothing
        for feature in kml.Features
            if isa(feature, KML.Placemark)
                push!(placemarks, feature)
            elseif isa(feature, KML.Document) || isa(feature, KML.Folder)
                find_placemarks!(feature, placemarks)
            end
        end
    end
    
    return placemarks
end

# Main benchmark function
println("="^80)
println("KML.jl Cross-Branch Benchmark")
println("="^80)

# Get branch info
try
    kml_path = dirname(dirname(pathof(KML)))
    branch = chomp(read(`git -C $kml_path rev-parse --abbrev-ref HEAD`, String))
    commit = chomp(read(`git -C $kml_path rev-parse --short HEAD`, String))
    println("\nBranch: $branch (commit: $commit)")
catch
    println("\nBranch: (unable to determine)")
end

println("Julia: v$VERSION")
println("Date: $(Dates.now())")

# Show loaded packages
println("\nLoaded packages:")
println("  BenchmarkTools: ✓")
println("  DataFrames: $(HAS_DATAFRAMES ? "✓" : "✗")")
println("  Tables: $(HAS_TABLES ? "✓" : "✗")")
println("  JSON: $(HAS_JSON ? "✓" : "✗")")

# Detect features
println("\nDetecting KML.jl features...")
features = detect_features()
for (feature, available) in features
    println("  $feature: $(available ? "✓" : "✗")")
end

# Test configurations
test_sizes = [
    ("Small", 100),
    ("Medium", 1000),
    ("Large", 5000),
    ("XLarge", 20000)
]

println("\n" * "="^80)
println("BENCHMARK 1: Reading KML file into KMLFile")
println("="^80)

benchmark1_results = []

for (size_name, n_placemarks) in test_sizes
    println("\n## $size_name file ($n_placemarks placemarks)")
    
    # Create test file
    test_file = "test_$(size_name).kml"
    create_test_kml(n_placemarks; filename=test_file)
    file_size_mb = filesize(test_file) / 1024^2
    println("File size: $(round(file_size_mb, digits=2)) MB")
    
    # Benchmark KMLFile reading
    GC.gc()
    bench = @benchmark read($test_file, KML.KMLFile) samples=5 seconds=3
    time_ms = median(bench).time / 1e6
    memory_mb = median(bench).memory / 1024^2
    
    push!(benchmark1_results, (size_name, n_placemarks, file_size_mb, time_ms, memory_mb))
    
    println("  Time: $(round(time_ms, digits=2)) ms")
    println("  Memory: $(round(memory_mb, digits=2)) MB")
    println("  Rate: $(round(n_placemarks / (time_ms / 1000), digits=0)) placemarks/sec")
    
    safe_cleanup(test_file)
end

# Benchmark 2: DataFrame extraction (if available)
if features["DataFrame"] && HAS_DATAFRAMES
    println("\n" * "="^80)
    println("BENCHMARK 2: Extracting first layer to DataFrame")
    println("="^80)
    
    benchmark2_results = []
    
    for (size_name, n_placemarks) in test_sizes
        println("\n## $size_name file ($n_placemarks placemarks)")
        
        # Create test file
        test_file = "test_$(size_name).kml"
        create_test_kml(n_placemarks; filename=test_file)
        
        # Determine which method to use based on available features
        method_used = ""
        bench = nothing
        
        if isdefined(KML, :PlacemarkTable) && hasmethod(DataFrame, (KML.PlacemarkTable,))
            # Via PlacemarkTable (parsing_perf_enhancement branch)
            GC.gc()
            bench = @benchmark DataFrame(KML.PlacemarkTable($test_file; layer=1)) samples=3 seconds=3
            method_used = "DataFrame(PlacemarkTable(file))"
        elseif isdefined(Base, :get_extension) && Base.get_extension(KML, :KMLDataFramesExt) !== nothing
            # Check if KMLDataFramesExt extension is loaded
            GC.gc()
            bench = @benchmark DataFrame($test_file; layer=1) samples=3 seconds=3
            method_used = "DataFrame(file; layer=1) via extension"
        else
            # This shouldn't happen if features["DataFrame"] is true, but fallback to manual
            GC.gc()
            bench = @benchmark begin
                kml = read($test_file, KML.KMLFile)
                placemarks = extract_placemarks_manual(kml)
                if !isempty(placemarks)
                    DataFrame(
                        name = [p.name for p in placemarks],
                        description = [p.description for p in placemarks],
                        geometry = [hasproperty(p, :Geometry) ? p.Geometry : 
                                   hasproperty(p, :geometry) ? p.geometry : 
                                   nothing for p in placemarks]
                    )
                else
                    DataFrame(name=String[], description=String[], geometry=[])
                end
            end samples=3 seconds=3
            method_used = "Manual extraction"
        end
        
        if bench !== nothing
            time_ms = median(bench).time / 1e6
            memory_mb = median(bench).memory / 1024^2
            
            push!(benchmark2_results, (size_name, n_placemarks, time_ms, memory_mb, method_used))
            
            println("  Method: $method_used")
            println("  Time: $(round(time_ms, digits=2)) ms")
            println("  Memory: $(round(memory_mb, digits=2)) MB")
            println("  Rate: $(round(n_placemarks / (time_ms / 1000), digits=0)) placemarks/sec")
        end
        
        safe_cleanup(test_file)
    end
elseif HAS_DATAFRAMES
    # DataFrames is loaded but KML doesn't have integration - do manual extraction benchmark
    println("\n" * "="^80)
    println("BENCHMARK 2: Manual DataFrame extraction (no KML integration detected)")
    println("="^80)
    
    benchmark2_results = []
    
    for (size_name, n_placemarks) in test_sizes
        println("\n## $size_name file ($n_placemarks placemarks)")
        
        # Create test file
        test_file = "test_$(size_name).kml"
        create_test_kml(n_placemarks; filename=test_file)
        
        # Manual extraction benchmark
        GC.gc()
        bench = @benchmark begin
            kml = read($test_file, KML.KMLFile)
            placemarks = extract_placemarks_manual(kml)
            if !isempty(placemarks)
                DataFrame(
                    name = [p.name for p in placemarks],
                    description = [p.description for p in placemarks],
                    geometry = [hasproperty(p, :Geometry) ? p.Geometry : 
                               hasproperty(p, :geometry) ? p.geometry : 
                               nothing for p in placemarks]
                )
            else
                DataFrame(name=String[], description=String[], geometry=[])
            end
        end samples=3 seconds=3
        
        time_ms = median(bench).time / 1e6
        memory_mb = median(bench).memory / 1024^2
        
        push!(benchmark2_results, (size_name, n_placemarks, time_ms, memory_mb, "Manual extraction"))
        
        println("  Method: Manual extraction")
        println("  Time: $(round(time_ms, digits=2)) ms")
        println("  Memory: $(round(memory_mb, digits=2)) MB")
        println("  Rate: $(round(n_placemarks / (time_ms / 1000), digits=0)) placemarks/sec")
        
        safe_cleanup(test_file)
    end
else
    println("\n" * "="^80)
    println("BENCHMARK 2: DataFrame extraction not available")
    println("="^80)
    
    println("\nDataFrames.jl not loaded. To enable this benchmark:")
    println("  1. Exit Julia")
    println("  2. Run: julia --project=.")
    println("  3. Run: using Pkg; Pkg.add(\"DataFrames\")")
    println("  4. Run the benchmark again")
end

# Summary
println("\n" * "="^80)
println("SUMMARY")
println("="^80)

println("\n## KMLFile Reading Performance:")
println("Size      | Placemarks | File (MB) | Time (ms) | Memory (MB) | Rate (p/s)")
println("----------|------------|-----------|-----------|-------------|------------")
for (size, n, file_mb, time, mem) in benchmark1_results
    println("$(rpad(size, 9)) | $(lpad(n, 10)) | $(lpad(round(file_mb, digits=2), 9)) | " *
            "$(lpad(round(time, digits=1), 9)) | $(lpad(round(mem, digits=1), 11)) | " *
            "$(lpad(round(n / (time / 1000), digits=0), 10))")
end

if @isdefined(benchmark2_results) && !isempty(benchmark2_results)
    println("\n## DataFrame Extraction Performance:")
    println("Size      | Placemarks | Time (ms) | Memory (MB) | Rate (p/s)  | Method")
    println("----------|------------|-----------|-------------|-------------|--------------------")
    for (size, n, time, mem, method) in benchmark2_results
        println("$(rpad(size, 9)) | $(lpad(n, 10)) | $(lpad(round(time, digits=1), 9)) | " *
                "$(lpad(round(mem, digits=1), 11)) | $(lpad(round(n / (time / 1000), digits=0), 11)) | $method")
    end
end

# Save results
results = Dict(
    "branch" => get(ENV, "KML_BRANCH", "unknown"),
    "timestamp" => string(Dates.now()),
    "features" => features,
    "kmlfile_reading" => benchmark1_results,
    "dataframe_extraction" => @isdefined(benchmark2_results) ? benchmark2_results : nothing
)

# Save results
if HAS_JSON
    output_file = "benchmark_results_$(get(ENV, "KML_BRANCH", "unknown"))_$(Dates.format(now(), "yyyymmdd_HHMMSS")).json"
    open(output_file, "w") do io
        JSON.print(io, results, 4)
    end
    println("\nResults saved to: $output_file")
else
    output_file = "benchmark_results_$(get(ENV, "KML_BRANCH", "unknown"))_$(Dates.format(now(), "yyyymmdd_HHMMSS")).jl"
    open(output_file, "w") do io
        println(io, "# Benchmark results")
        println(io, "results = $results")
    end
    println("\nResults saved to: $output_file")
end

println("\n✓ Benchmark complete!")