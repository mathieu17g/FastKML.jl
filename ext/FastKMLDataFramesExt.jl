# ext/FastKMLDataFramesExt.jl

module FastKMLDataFramesExt

using DataFrames
import FastKML
import FastKML: KMLFile, LazyKMLFile, PlacemarkTable, read


"""
    DataFrame(kml_file::Union{FastKML.KMLFile,FastKML.LazyKMLFile}; layer::Union{Nothing,String,Integer}=nothing, simplify_single_parts::Bool=false)

Constructs a DataFrame from the Placemarks in a `KMLFile` or `LazyKMLFile` object.

# Arguments

  - `kml_file::Union{FastKML.KMLFile,FastKML.LazyKMLFile}`: The KML file object already read into memory.
    LazyKMLFile is more efficient for this use case as it doesn't materialize the entire KML structure.

  - `layer::Union{Nothing,String,Integer}=nothing`: Specifies the layer to extract Placemarks from.

      + If `nothing` (default): The behavior is defined by `FastKML.PlacemarkTable` (e.g., attempts to find a default layer or prompts if multiple are available and in interactive mode).
      + If `String`: The name of the Document or Folder to use as the layer.
      + If `Integer`: The index of the layer to use.
  - `simplify_single_parts::Bool=false`: If `true`, when a MultiGeometry contains only a single geometry part, that part is extracted directly, simplifying the structure. For example, a MultiGeometry containing a single LineString will be treated as a LineString. Defaults to `false`.
"""
function DataFrames.DataFrame(
    kml_file::Union{FastKML.KMLFile,FastKML.LazyKMLFile};
    layer::Union{Nothing,String,Integer} = nothing,
    simplify_single_parts::Bool = false,
)
    placemark_table = FastKML.PlacemarkTable(kml_file; layer = layer, simplify_single_parts = simplify_single_parts)
    return DataFrames.DataFrame(placemark_table)
end

"""
    DataFrame(kml_path::AbstractString; layer::Union{Nothing,String,Integer}=nothing, simplify_single_parts::Bool=false, lazy::Bool=true)

Constructs a DataFrame from the Placemarks in a KML file specified by its path.

# Arguments

  - `kml_path::AbstractString`: Path to the .kml or .kmz file.

  - `layer::Union{Nothing,String,Integer}=nothing`: Specifies the layer to extract Placemarks from.

      + If `nothing` (default): The behavior is defined by `FastKML.PlacemarkTable` (e.g., attempts to find a default layer or prompts if multiple are available and in interactive mode).
      + If `String`: The name of the Document or Folder to use as the layer.
      + If `Integer`: The index of the layer to use.
  - `simplify_single_parts::Bool=false`: If `true`, when a MultiGeometry contains only a single geometry part, it will be simplified to that single geometry. For example, a MultiGeometry containing a single Point will become just a Point. Defaults to `false`.
  - `lazy::Bool=true`: If `true` (default), uses `LazyKMLFile` for better performance when only extracting placemarks.
    If `false`, uses regular `KMLFile` which materializes the entire KML structure.
    For DataFrame extraction, `lazy=true` is recommended as it's significantly faster for large files.

# Examples

```julia
# Default lazy loading (recommended for DataFrames)
df = DataFrame("large_file.kml")

# Force eager loading if you need the full KML structure later
df = DataFrame("file.kml"; lazy = false)

# Select a specific layer by name
df = DataFrame("file.kml"; layer = "Points of Interest")

# Select layer by index
df = DataFrame("file.kml"; layer = 2)
```
"""
function DataFrames.DataFrame(
    kml_path::AbstractString;
    layer::Union{Nothing,String,Integer} = nothing,
    simplify_single_parts::Bool = false,
    lazy::Bool = true,
)
    kml_file_obj = if lazy
        FastKML.read(kml_path, FastKML.LazyKMLFile)
    else
        FastKML.read(kml_path, FastKML.KMLFile)
    end
    return DataFrames.DataFrame(kml_file_obj; layer = layer, simplify_single_parts = simplify_single_parts)
end

end # module FastKMLDataFramesExt