###############################################################################
# benchmark_tables.jl
# Compare FastKML.jl vs ArchGDAL.jl while materialising the whole file
# as a Tables.jl‑compatible DataFrame.
###############################################################################

using Scratch
using Downloads, ZipArchives
using URIs: URI
import XML: XML, read as xmlread, parse as xmlparse, write as xmlwrite, Node, LazyNode, nodetype
import FastKML
using ArchGDAL
using Tables, DataFrames
using BenchmarkTools
import GeoInterface as GI
import WellKnownGeometry as WKT
using Crayons
using Printf
using Profile

# ───────────────────────────── URLs ─────────────────────────────────────── #
#! WIP: This first file does not stem the same geometry than with ArchGDAL.jl
URL1 = "https://esdac.jrc.ec.europa.eu/ESDB_Archive/ESDBv3/GoogleEarth/USEDO.kmz"
#* This second file leads to the same DataFrame as ArchGDAL.jl and the parsing is faster
URL2 = "https://www.dec.ny.gov/data/der/enzones/enzone2022.kmz"
#! WIP: This third file does not stem the same geometry than with ArchGDAL.jl
URL3 = "https://esdac.jrc.ec.europa.eu/ESDB_Archive/ESDBv3/GoogleEarth/Aglim1.kmz"
#* This fourth file leads to the same DataFrame as ArchGDAL.jl and the parsing a bit slower
URL4 = "https://d9-wret.s3.us-west-2.amazonaws.com/assets/palladium/production/s3fs-public/atoms/files/WRS-2_bound_world_0.kml"
URL5 = "https://earthquake.usgs.gov/static/lfs/nshm/qfaults/qfaults.kmz"
#! WIP: This sixth file does not stem the same number of rows than with ArchGDAL.jl. ArchGDAL.jl seems to have difficulties on this parsing
URL6 = "https://ordsext.epa.gov/FLA/www3/national_frs.kmz"
# ???
URL7 = "https://www.neonscience.org/sites/default/files/NEON_Field_Sites_KMZ_v20_May2025.kmz"
#! WIP: Does not work with FastKML.jl because of NetworkLink elements not handled yet
URL8 = "https://infoterre.brgm.fr/sites/default/files/upload/kml/kml_geo_1000.kml"
#! WIP: Geometry appears to be line strings via Google Earth, but FastKML.jl extracts points
URL9 = "https://pubs.usgs.gov/of/2007/1264/SteepestDescents_Kilauea1983_10m_cell7500.KMZ"


ISO_GDAL_URLS = [URL2, URL4, URL5]
ANISO_GDAL_URLS = [URL1, URL3, URL6]
URLS_TO_BENCHMARK = ISO_GDAL_URLS
URL_TO_BENCHMARK = URL1

# ────────────────────────── fetch KML/KMZ ──────────────────────────────────── #

# Define a cache directory using Scratch.jl
# This provides a persistent, unique directory for caching files.
const CACHE_DIR = @get_scratch!("KMLBenchmarkCache")

"""
    fetch_kml_or_kmz(url::AbstractString; dest::AbstractString = CACHE_DIR)

Download the resource at `url` into `dest` (defaults to a scratch space).
If it's a KMZ file, unzip the single `.kml` entry and return its path.
Otherwise return the downloaded KML path.
The `dest` directory will be created if it does not exist.
"""
function fetch_kml_or_kmz(url::AbstractString; dest::AbstractString = CACHE_DIR)

    # Determine local filename
    uri = URI(url)
    fname = basename(uri.path)
    local_path = joinpath(dest, fname)

    # Download if missing
    if !isfile(local_path)
        Downloads.download(url, local_path)
    end

    # If KMZ, extract the KML member
    if endswith(lowercase(local_path), ".kmz") # Use lowercase for case-insensitive check
        # Define the target KML file name within the dest directory
        kml_entry_basename = replace(fname, r"\.[kK][mM][zZ]$"i => ".kml") # Case-insensitive replace
        kml_output_path = joinpath(dest, kml_entry_basename)

        # Read the entire KMZ file into memory as a byte vector
        kmz_data::Vector{UInt8} = read(local_path)
        zr = ZipReader(kmz_data) # ZipReader now uses the byte vector

        local selected_entry_for_kml_name::Union{String,Nothing} = nothing
        candidate_kml_entries = String[]
        entry_names_in_zip = zip_names(zr)

        # Find all KML file entries, checking extension case-insensitively
        for entry_name_original in entry_names_in_zip
            if length(entry_name_original) >= 4 &&
               lowercase(entry_name_original[end-3:end]) == ".kml" &&
               !endswith(entry_name_original, '/') # Check if it's not a directory entry
                push!(candidate_kml_entries, entry_name_original)
            end
        end

        if !isempty(candidate_kml_entries)
            # Prioritize "doc.kml" (case-insensitive basename)
            found_doc_kml = false
            for entry_name_original in candidate_kml_entries
                if lowercase(basename(entry_name_original)) == "doc.kml"
                    selected_entry_for_kml_name = entry_name_original
                    found_doc_kml = true
                    break
                end
            end

            # If "doc.kml" is not found, fall back to the first KML entry discovered
            if !found_doc_kml
                selected_entry_for_kml_name = candidate_kml_entries[1]
            end
        end

        if selected_entry_for_kml_name !== nothing
            # If the target KML file already exists, remove it first to avoid potential conflicts
            # from previous runs or locked states.
            if isfile(kml_output_path)
                rm(kml_output_path)
            end
            # Write the content of the selected KML entry to the target kml_output_path
            write(kml_output_path, zip_readentry(zr, selected_entry_for_kml_name))
        else
            # No KML files found in the archive.
            error("No .kml files found in KMZ archive: $local_path to write to $kml_output_path")
        end
        # No explicit close needed for zr when initialized with a byte vector.
        return relpath(kml_output_path) # Return the path to the extracted KML file
    end

    return relpath(local_path) # Return the path to the downloaded (KML) file
end

# ──────────────────────── parsing pipelines ───────────────────────────────── #

"""
Full `read → convert → DataFrame` with FastKML.jl
"""
table_with_fastkml(path; i::Integer = 1) = DataFrame(path; layer = i)

"""
Full `read → convert → DataFrame` with ArchGDAL.jl.

If `layer === nothing` (the default), concatenate every layer ArchGDAL
exposes for the file. ArchGDAL's KML driver maps each leaf `<Folder>`
to a separate layer, so files with deeply-nested folder hierarchies
(e.g. EPA's national_frs.kmz, where 19k cities each become their own
layer) would otherwise silently return only the first folder's
features. Pass an explicit `layer = i` to inspect a single ArchGDAL
layer.
"""
function table_with_archgdal(path; layer::Union{Nothing,Integer} = nothing)
    ArchGDAL.read(path) do dataset
        if layer !== nothing
            return DataFrame(ArchGDAL.getlayer(dataset, layer))
        end
        n = ArchGDAL.nlayer(dataset)
        n == 0 && return DataFrame()
        n == 1 && return DataFrame(ArchGDAL.getlayer(dataset, 0))
        dfs = [DataFrame(ArchGDAL.getlayer(dataset, k)) for k in 0:n-1]
        return vcat(dfs...; cols = :union)
    end
end

# ──────────────────────── diff display helpers ───────────────────────────── #

"""
    _first_diff_char_pos(a, b) -> Int

1-based character position of the first difference between strings `a` and `b`.
Returns `min(length(a), length(b)) + 1` if one is a prefix of the other, or `0`
if the two are equal.
"""
function _first_diff_char_pos(a::AbstractString, b::AbstractString)
    a == b && return 0
    i = 0
    for (ca, cb) in zip(a, b)
        i += 1
        ca != cb && return i
    end
    return min(length(a), length(b)) + 1
end

"""
    _diff_window(s, pos; before, after) -> String

Substring of `s` centered on character position `pos` (`before` chars left,
`after` chars right). Adds `...` markers when truncated at either end.
"""
function _diff_window(s::AbstractString, pos::Integer; before::Int = 30, after::Int = 80)
    chars = collect(s)
    n = length(chars)
    n == 0 && return ""
    pos = clamp(pos, 1, n)
    lo = max(1, pos - before)
    hi = min(n, pos + after)
    prefix = lo > 1 ? "..." : ""
    suffix = hi < n ? "..." : ""
    return prefix * String(chars[lo:hi]) * suffix
end

# ────────────────────────────── benchmark ──────────────────────────────────── #

"""
    benchmark_url(target_url::AbstractString, benchmark_seconds::Integer)

Fetches, parses, compares, and benchmarks KML/KMZ data from a given URL.
Requires Crayons.jl for colored output. Add `using Crayons` at the top of your script.
"""
function benchmark_url(target_url::AbstractString, benchmark_seconds::Integer)
    # Define Crayons for styling - ensure Crayons.jl is imported (e.g., using Crayons)
    # If `using Crayons` is at the top of the file, you can just use `Crayon(...)`
    HEADER_INFO_CRAYON = Crayon(foreground = :cyan, bold = true)
    URL_CRAYON = Crayon(foreground = :blue, underline = true)
    VALUE_CRAYON = Crayon(foreground = :yellow)
    FILE_PATH_CRAYON = Crayon(foreground = :magenta)
    SUCCESS_CRAYON = Crayon(foreground = :green, bold = true)
    ERROR_CRAYON = Crayon(foreground = :red, bold = true)
    ERROR_MSG_CRAYON = Crayon(foreground = :red)
    BENCHMARK_SECTION_CRAYON = Crayon(foreground = :yellow, bold = true)
    TABLE_HEADER_CRAYON = Crayon(bold = true)
    SEPARATOR_CRAYON = Crayon(foreground = :dark_gray)
    METRIC_NAME_CRAYON = Crayon(bold = true) # Bold metric names in the table

    print(HEADER_INFO_CRAYON("\nBenchmarking URL: "))
    println(URL_CRAYON(target_url))

    print(HEADER_INFO_CRAYON("Benchmark duration: "))
    print(VALUE_CRAYON(string(benchmark_seconds)))
    println(HEADER_INFO_CRAYON(" seconds"))

    println(SEPARATOR_CRAYON(rpad("", 80, '─')))

    # ──────────────────────── sanity‑check equality ───────────────────────────── #

    kml_file_path = fetch_kml_or_kmz(target_url)
    print(HEADER_INFO_CRAYON("Using KML file: "))
    println(FILE_PATH_CRAYON(kml_file_path))

    df_fastkml = table_with_fastkml(kml_file_path)
    df_gdal = table_with_archgdal(kml_file_path)

    # --- Helper function to print differences for a vector comparison ---
    function print_differences(label::String, vec1, vec2, crayon_msg, max_diffs_to_show::Int = 3, truncate_len::Int = 60)
        diff_count = 0

        len1, len2 = length(vec1), length(vec2)
        # Report length mismatch as a primary difference
        if len1 != len2
            println(crayon_msg("  Length mismatch for $label: FastKML.jl has $len1 rows, ArchGDAL.jl has $len2 rows."))
            # Even with length mismatch, we'll show element differences up to max_iter_len
        end

        max_iter_len = max(len1, len2) # Iterate to cover all elements in the longer vector

        for i = 1:max_iter_len
            item1_exists = i <= len1
            item2_exists = i <= len2

            val1 = item1_exists ? vec1[i] : "< FastKML.jl: value not present at row $i >"
            val2 = item2_exists ? vec2[i] : "< ArchGDAL.jl: value not present at row $i >"

            # Check if items are different
            # Use isequal to handle `missing` values correctly (missing == missing is true for isequal)
            is_different_flag = false
            if item1_exists && item2_exists
                if !isequal(val1, val2)
                    is_different_flag = true
                end
            else # One item exists, the other doesn't (due to different lengths)
                is_different_flag = true
            end

            if is_different_flag
                diff_count += 1
                if diff_count <= max_diffs_to_show
                    s_val1 = string(val1) # string() handles missing by converting to "missing"
                    s_val2 = string(val2)

                    pos = _first_diff_char_pos(s_val1, s_val2)
                    if pos > truncate_len ÷ 2
                        # Divergence past the simple-prefix window — show a
                        # context window around the first differing char.
                        disp1 = _diff_window(s_val1, pos)
                        disp2 = _diff_window(s_val2, pos)
                        println(crayon_msg("  Row $i (diff @ char $pos): FastKML.jl='$(disp1)', ArchGDAL.jl='$(disp2)'"))
                    else
                        # Divergence near the start — simple truncation suffices.
                        disp1 = length(s_val1) > truncate_len ? first(s_val1, truncate_len) * "..." : s_val1
                        disp2 = length(s_val2) > truncate_len ? first(s_val2, truncate_len) * "..." : s_val2
                        println(crayon_msg("  Row $i: FastKML.jl='$(disp1)', ArchGDAL.jl='$(disp2)'"))
                    end
                end
            end
        end

        if diff_count > max_diffs_to_show
            println(crayon_msg("  ... and $(diff_count - max_diffs_to_show) more differences for $label."))
        elseif diff_count == 0 && len1 != len2
            # This means elements matched up to min_len, but lengths were different.
            # The length mismatch message is already printed above.
            println(crayon_msg("  ($label elements match for common rows, but overall lengths differ.)"))
        elseif diff_count == 0 && len1 == len2
            # This should not be reached if this function is called only when vec1 != vec2
            # but as a safeguard:
            # println(crayon_msg("  ($label seem to match, check comparison logic if this appears.)")) 
        end
    end
    # --- End helper function ---

    overall_match = true

    # 1. Check row counts
    if nrow(df_fastkml) != nrow(df_gdal)
        overall_match = false
        println(ERROR_CRAYON("❌ Row counts differ: FastKML.jl has $(nrow(df_fastkml)) rows, ArchGDAL.jl has $(nrow(df_gdal)) rows."))
    end

    # 2. Compare 'name' column.
    # Symmetric normalization on both sides: strip leading/trailing
    # whitespace, then resolve named HTML entities. ArchGDAL preserves the
    # raw text of `<name>`, while FastKML strips and runs decode_named_entities;
    # without symmetry, every name with leading whitespace or with a
    # non-conformant uppercase entity (e.g. "DAY &AMP; DAY") would be
    # flagged as a content mismatch.
    fastkml_geomsnames = strip.(FastKML.HtmlEntities.decode_named_entities.(df_fastkml.name))
    gdal_geomsnames    = strip.(FastKML.HtmlEntities.decode_named_entities.(df_gdal.Name))
    if !isequal(fastkml_geomsnames, gdal_geomsnames)
        overall_match = false
        println(ERROR_CRAYON("❌ 'name' column differs:"))
        print_differences("Names", fastkml_geomsnames, gdal_geomsnames, ERROR_MSG_CRAYON)
    end

    # 3. Compare 'description' column.
    # Both parsers preserve raw whitespace from HTML descriptions; ArchGDAL
    # additionally collapses tab runs in some files. Normalize symmetrically
    # by collapsing every run of whitespace (incl. tabs and CRLF) to a
    # single space, then strip — so we don't flag pure-whitespace
    # divergences as content mismatches.
    fastkml_geomsdescr = strip.(replace.(df_fastkml.description, r"\s+" => " "))
    gdal_geomsdescr    = strip.(replace.(df_gdal.Description,    r"\s+" => " "))
    if !isequal(fastkml_geomsdescr, gdal_geomsdescr)
        overall_match = false
        println(ERROR_CRAYON("❌ 'description' column differs:"))
        print_differences("Descriptions", fastkml_geomsdescr, gdal_geomsdescr, ERROR_MSG_CRAYON, 3, 70)
    end

    # 4. Compare geometry columns
    # Assuming 'geometry' column exists in df_fastkml and geometry is the first column in df_gdal.

    # 4a. Compare geometry columns (as WKT)
    # Extract `.val` (the bare WKT string) so diff output isn't drowned in
    # `WellKnownText{...}(...,"…")` wrapper boilerplate.
    fastkml_wktgeoms = [WKT.getwkt(g).val for g in df_fastkml.geometry]
    gdal_wktgeoms    = [WKT.getwkt(g).val for g in df_gdal[:, 1]]
    if !isequal(fastkml_wktgeoms, gdal_wktgeoms)
        overall_match = false
        println(ERROR_CRAYON("❌ Geometry column (as WKT) differs:"))
        print_differences("Geometries (WKT)", fastkml_wktgeoms, gdal_wktgeoms, ERROR_MSG_CRAYON, 3, 100)
    end

    # 4b. Compare geometry columns (coordinates)
    # GI (GeoInterface) should be imported in your script.
    fastkml_coords = GI.coordinates.(df_fastkml.geometry)
    gdal_coords = GI.coordinates.(df_gdal[:, 1])
    if !isequal(fastkml_coords, gdal_coords)
        overall_match = false
        println(ERROR_CRAYON("❌ Geometry column (coordinates) differs:"))
        # Coordinates can be verbose; adjust truncate_len as needed.
        print_differences("Geometries (Coordinates)", fastkml_coords, gdal_coords, ERROR_MSG_CRAYON, 3, 120)
    end

    # Final summary message
    if overall_match
        println(
            SUCCESS_CRAYON(
                "✔  Tables appear identical for compared columns (name, description, geometry WKT & coordinates): ",
            ),
            nrow(df_fastkml),
            " rows.",
        )
    else
        println(ERROR_CRAYON("❌ Tables differ as detailed above. Please review the specific differences."))
    end

    # ────────────────────────── benchmarking ──────────────────────────────────── #

    println(BENCHMARK_SECTION_CRAYON("Starting benchmarks..."))
    bench_fastkml_result = @benchmark table_with_fastkml($kml_file_path) seconds = benchmark_seconds
    bench_gdal_result = @benchmark table_with_archgdal($kml_file_path) seconds = benchmark_seconds

    # ────────────────────────── print results ─────────────────────────────────── #

    println(BENCHMARK_SECTION_CRAYON("Benchmark results (including conversion → DataFrame):"))

    # Calculate values first
    fastkml_time_ms = median(bench_fastkml_result).time / 1e6
    gdal_time_ms = median(bench_gdal_result).time / 1e6
    fastkml_mem_kib = round(Int, median(bench_fastkml_result).memory / 1024)
    gdal_mem_kib = round(Int, median(bench_gdal_result).memory / 1024)

    # Print table header
    print(TABLE_HEADER_CRAYON(rpad("Metric", 30)))
    print(" ") # Separator space
    print(TABLE_HEADER_CRAYON(lpad("FastKML.jl", 15)))
    print(" ") # Separator space
    print(TABLE_HEADER_CRAYON(lpad("ArchGDAL.jl", 15)))
    println() # Newline

    println(SEPARATOR_CRAYON(rpad("", 30 + 1 + 15 + 1 + 15, '-'))) # Total width for the line

    # Print data rows
    print(METRIC_NAME_CRAYON(rpad("Median elapsed time (ms)", 30)))
    Printf.@printf " %15.2f %15.2f\n" fastkml_time_ms gdal_time_ms

    print(METRIC_NAME_CRAYON(rpad("Memory (KiB)", 30)))
    Printf.@printf " %15d %15d\n" fastkml_mem_kib gdal_mem_kib

    println(SEPARATOR_CRAYON(rpad("", 80, '─')))
    println() # Add a blank line for separation if calling multiple times
end

# ─────────────────────── Benchmark list of URLS ───────────────────────────── #

"""
    run_benchmarks(url_to_benchmark::String; default_benchmark_seconds::Integer = 20)
    run_benchmarks(urls_to_benchmark::Vector{String}; default_benchmark_seconds::Integer = 20)

Runs benchmarks for a given URL or a list of URLs.

# Arguments
- `url_to_benchmark::String`: A single URL string to benchmark. An empty string will be skipped with a warning.
- `urls_to_benchmark::Vector{String}`: A vector of URL strings to benchmark. Empty URLs within the list or an empty vector will be skipped with a warning.
- `default_benchmark_seconds::Integer = 10` (keyword): The duration in seconds for each benchmark trial. This applies to each URL processed.
"""
function run_benchmarks(
    url_to_benchmark::String;
    default_benchmark_seconds::Integer = 10,
)
    if isempty(url_to_benchmark)
        println(Crayon(foreground = :yellow)("Warning: Empty URL string provided to run_benchmarks. Skipping."))
        return
    end

    # Header for this specific benchmark operation.
    # benchmark_url itself will print "Benchmarking URL: <actual_url>"
    println(Crayon(bold = true, foreground = :magenta)("\n--- Preparing to benchmark single URL ---"))
    benchmark_url(url_to_benchmark, default_benchmark_seconds)
end

function run_benchmarks(
    urls_to_benchmark::Vector{String};
    default_benchmark_seconds::Integer = 10,
)
    if isempty(urls_to_benchmark)
        println(Crayon(foreground = :yellow)("Warning: Empty list of URLs provided to run_benchmarks. Skipping."))
        return
    end

    println(Crayon(bold = true, foreground = :magenta)("\n--- Preparing to benchmark list of URLs ($(length(urls_to_benchmark)) URLs total) ---"))
    for (idx, url_to_test) in enumerate(urls_to_benchmark)
        if isempty(url_to_test)
            println(Crayon(foreground = :yellow)("Warning: Empty URL string at index $idx in list. Skipping this entry."))
            continue
        end
        # Header for each item in the list for better traceability in logs.
        println(Crayon(bold = true, foreground = :light_cyan)("\nProcessing URL $idx of $(length(urls_to_benchmark)) from list..."))
        benchmark_url(url_to_test, default_benchmark_seconds)
    end
end

# --- Example Calls ---
# The following demonstrates how to use the refactored `run_benchmarks` function.
# The script will benchmark the globally defined `URLS_TO_BENCHMARK` (a list)
# and `URL_TO_BENCHMARK` (a single URL) sequentially.

# Benchmark the predefined list of URLs
# println(Crayon(bold = true, foreground = :blue)("\n<<< STARTING BENCHMARKS FOR PREDEFINED LIST OF URLS >>>"))
# run_benchmarks(URLS_TO_BENCHMARK) # Uses default_benchmark_seconds = 10

# Benchmark the predefined single URL
# println(Crayon(bold = true, foreground = :blue)("\n<<< STARTING BENCHMARKS FOR PREDEFINED SINGLE URL >>>"))
# run_benchmarks(URL_TO_BENCHMARK) # Uses default_benchmark_seconds = 10


# Additional commented-out examples for various use cases:

# To benchmark only a list with a custom benchmark time:
# println(Crayon(bold = true, foreground = :blue)("\n--- BENCHMARKING LIST WITH CUSTOM TIME ---"))
# run_benchmarks(URLS_TO_BENCHMARK; default_benchmark_seconds = 20)

# To benchmark only a single URL with a custom benchmark time:
# println(Crayon(bold = true, foreground = :blue)("\n--- BENCHMARKING SINGLE URL WITH CUSTOM TIME ---"))
# run_benchmarks(URL_TO_BENCHMARK; default_benchmark_seconds = 15)

# To benchmark an ad-hoc single URL:
# println(Crayon(bold = true, foreground = :blue)("\n--- BENCHMARKING AD-HOC SINGLE URL ---"))
# run_benchmarks("https://www.example.com/some.kml"; default_benchmark_seconds = 5)

# To benchmark an ad-hoc list of URLs:
# println(Crayon(bold = true, foreground = :blue)("\n--- BENCHMARKING AD-HOC LIST OF URLS ---"))
# run_benchmarks(["https://www.example.com/some1.kml", "https://www.example.com/some2.kmz"]); # Uses default_benchmark_seconds



