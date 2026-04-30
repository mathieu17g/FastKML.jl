###############################################################################
# integration_archgdal_test.jl
#
# Network-gated integration tests. For each KML/KMZ in `ISO_GDAL_URLS`,
# parse with both FastKML and ArchGDAL and assert the resulting
# DataFrames agree on row count, name, description, geometry WKT, and
# geometry coordinates.
#
# Mirrors `benchmark/benchmark_kml_parsers.jl` but trades the
# `@benchmark` loop for plain `@test` assertions, so CI gets functional
# parity coverage without paying the benchmark's wall-clock cost.
#
# Opt in with:
#   FASTKML_INTEGRATION=true julia --project=. -e 'using Pkg; Pkg.test()'
#
# Files are cached in a Scratch space (`FastKMLIntegrationCache`),
# so subsequent runs only re-download if the cache was wiped.
###############################################################################

using Test
using FastKML
using DataFrames
using ZipArchives: ZipReader, zip_names, zip_readentry
using Scratch: @get_scratch!
using Downloads
using URIs: URI
using ArchGDAL
import GeoInterface as GI
import WellKnownGeometry as WKT

# ── URLs (subset of `benchmark_kml_parsers.jl`'s ISO_GDAL_URLS) ──
# Kept in sync manually; matching basename comments make drift obvious.
const ENZONE_URL  = "https://www.dec.ny.gov/data/der/enzones/enzone2022.kmz"          # URL2
const WRS2_URL    = "https://d9-wret.s3.us-west-2.amazonaws.com/assets/palladium/production/s3fs-public/atoms/files/WRS-2_bound_world_0.kml"  # URL4
const QFAULTS_URL = "https://earthquake.usgs.gov/static/lfs/nshm/qfaults/qfaults.kmz" # URL5

const ISO_GDAL_URLS = [ENZONE_URL, WRS2_URL, QFAULTS_URL]

const CACHE_DIR = @get_scratch!("FastKMLIntegrationCache")

# ── KML/KMZ fetcher (simplified port of benchmark's fetch_kml_or_kmz) ──
function fetch_kml_or_kmz(url::AbstractString; dest = CACHE_DIR)
    fname = basename(URI(url).path)
    local_path = joinpath(dest, fname)
    isfile(local_path) || Downloads.download(url, local_path)

    endswith(lowercase(local_path), ".kmz") || return local_path

    kml_out = joinpath(dest, replace(fname, r"\.[kK][mM][zZ]$" => ".kml"))
    if !isfile(kml_out)
        zr = ZipReader(read(local_path))
        candidates = [n for n in zip_names(zr)
                      if length(n) >= 4 &&
                         lowercase(n[end-3:end]) == ".kml" &&
                         !endswith(n, '/')]
        isempty(candidates) && error("No .kml entry found in $local_path")
        idx_doc = findfirst(n -> lowercase(basename(n)) == "doc.kml", candidates)
        chosen = candidates[idx_doc === nothing ? firstindex(candidates) : idx_doc]
        write(kml_out, zip_readentry(zr, chosen))
    end
    return kml_out
end

# ── Parsing pipelines: concatenate every top-level layer when `layer === nothing` ──
function table_with_fastkml(path; layer::Union{Nothing,Integer} = nothing)
    layer !== nothing && return DataFrame(path; layer = layer)
    file = read(path, FastKML.LazyKMLFile)
    n = FastKML.get_num_layers(file)
    n == 0 && return DataFrame()
    n == 1 && return DataFrame(file; layer = 1)
    return vcat([DataFrame(file; layer = k) for k in 1:n]...; cols = :union)
end

function table_with_archgdal(path; layer::Union{Nothing,Integer} = nothing)
    ArchGDAL.read(path) do dataset
        layer !== nothing && return DataFrame(ArchGDAL.getlayer(dataset, layer))
        n = ArchGDAL.nlayer(dataset)
        n == 0 && return DataFrame()
        n == 1 && return DataFrame(ArchGDAL.getlayer(dataset, 0))
        return vcat([DataFrame(ArchGDAL.getlayer(dataset, k)) for k in 0:n-1]...;
                    cols = :union)
    end
end

# ── Symmetric normalizations (see benchmark_kml_parsers.jl for rationale) ──
# `name`: ArchGDAL preserves leading/trailing whitespace and raw HTML entities
# (`&AMP;`); FastKML strips and decodes. Apply both transforms on both sides
# so we don't flag whitespace or entity-encoding choices as content mismatches.
norm_name(x) = strip(FastKML.HtmlEntities.decode_named_entities(x))
# `description`: collapse every run of whitespace (incl. tabs and CRLF) to a
# single space and strip; some files have tab-run differences between parsers.
norm_desc(x) = strip(replace(x, r"\s+" => " "))

# ── Tests ──
@testset "Integration vs ArchGDAL ($(basename(URI(url).path)))" for url in ISO_GDAL_URLS
    path = fetch_kml_or_kmz(url)
    df_f = table_with_fastkml(path)
    df_g = table_with_archgdal(path)

    @test nrow(df_f) == nrow(df_g)
    @test isequal(norm_name.(df_f.name),         norm_name.(df_g.Name))
    @test isequal(norm_desc.(df_f.description),  norm_desc.(df_g.Description))
    @test isequal([WKT.getwkt(g).val for g in df_f.geometry],
                  [WKT.getwkt(g).val for g in df_g[:, 1]])
    @test isequal(GI.coordinates.(df_f.geometry), GI.coordinates.(df_g[:, 1]))
end
