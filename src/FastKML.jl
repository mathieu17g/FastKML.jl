module FastKML

# Base dependencies
using OrderedCollections: OrderedDict
using StaticArrays
using Automa, Parsers
using TimeZones, Dates
using InteractiveUtils: subtypes

# XML LazyNode and Node iterating macros helpers
include("macros.jl")

# Include all modules in dependency order
include("Enums.jl")
include("types.jl")
include("Coordinates.jl")
include("time_parsing.jl")
include("html_entities.jl")
include("field_conversion.jl")
include("xml_parsing.jl")
include("xml_serialization.jl")
include("io.jl")
include("Layers.jl")
include("utils.jl")
include("tables.jl")
include("validation.jl")
include("navigation.jl")

# Import for easier access
using .Types
using .Enums
using .Coordinates: coordinate_string, Coord2, Coord3
using .XMLSerialization: to_xml, xml_children, Node
using .XMLParsing: object
using .Layers: list_layers, get_layer_names, get_num_layers
using .TablesBridge: PlacemarkTable
using .Utils: unwrap_single_part_multigeometry
using .Navigation: children

# Re-export public API
export KMLFile, LazyKMLFile, object
export children, to_xml, xml_children
export unwrap_single_part_multigeometry
export PlacemarkTable, list_layers, get_layer_names, get_num_layers
export coordinate_string, Coord2, Coord3

# Export all type names from Types module
for name in names(Types; all=false)
    if name != :Types && name != :eval && name != :include
        @eval export $name
    end
end

# Export all enum types
for name in names(Enums; all=false)
    if name != :Enums && name != :AbstractKMLEnum
        @eval export $name
    end
end

# ─── Make KMLFile Iterable and Indexable ────────────────────────────────────

"""
    iterate(kml::KMLFile)

Iterate over the children of a KMLFile.

# Example
```julia
for child in kml
    println(typeof(child), ": ", child.name)
end
```
"""
Base.iterate(k::KMLFile, state...) = iterate(k.children, state...)
Base.length(k::KMLFile) = length(k.children)
Base.eltype(::Type{KMLFile}) = Union{XML.AbstractXMLNode, KMLElement}

"""
    kml[i]

Access children of a KMLFile by index.

# Example
```julia
doc = kml[1]  # Get first child (usually Document)
```
"""
Base.getindex(k::KMLFile, i) = k.children[i]
Base.firstindex(k::KMLFile) = 1
Base.lastindex(k::KMLFile) = length(k.children)

# Optional: Add similar functionality for Document and Folder
Base.iterate(d::Document, state...) = d.Features === nothing ? nothing : iterate(d.Features, state...)
Base.length(d::Document) = d.Features === nothing ? 0 : length(d.Features)
Base.getindex(d::Document, i) = d.Features === nothing ? throw(BoundsError(d, i)) : d.Features[i]

Base.iterate(f::Folder, state...) = f.Features === nothing ? nothing : iterate(f.Features, state...)
Base.length(f::Folder) = f.Features === nothing ? 0 : length(f.Features)
Base.getindex(f::Folder, i) = f.Features === nothing ? throw(BoundsError(f, i)) : f.Features[i]

# ─── Initialization ──────────────────────────────────────────────────────────

function __init__()
    # Register error hints for KMZ support
    Base.Experimental.register_error_hint(IO._read_kmz_file_from_path_error_hinter, ErrorException)

    # Only check for conflicts when not precompiling
    # Use generating_output if available (Julia 1.11+), otherwise check ccall
    is_precompiling = if isdefined(Base, :generating_output)
        Base.generating_output()
    else
        # Julia 1.10 and earlier: check if we're in precompilation
        ccall(:jl_generating_output, Cint, ()) != 0
    end
    
    if !is_precompiling
        check_geometry_conflicts()
    end
end

function check_geometry_conflicts()
    geometry_types = [:Point, :LineString, :LinearRing, :Polygon, :MultiGeometry]
    blocked_exports = Symbol[]
    conflicts_with = Set{Symbol}()

    for geom_type in geometry_types
        if isdefined(Main, geom_type)
            main_type = getfield(Main, geom_type)
            kml_type = getfield(FastKML, geom_type)

            # Check if Main's type is NOT KML's type
            if main_type !== kml_type && !isa(main_type, Module)
                push!(blocked_exports, geom_type)

                # Try to identify source package
                try
                    # For types, use parentmodule directly
                    source_module = parentmodule(main_type)
                    if source_module !== Main && source_module !== Base && source_module !== Core
                        push!(conflicts_with, nameof(source_module))
                    end
                catch
                    # If that fails, try checking methods
                    meths = methods(main_type)
                    if !isempty(meths)
                        for m in meths
                            mod = parentmodule(m.module)
                            if mod !== Main && mod !== Base && mod !== Core
                                push!(conflicts_with, nameof(mod))
                                break
                            end
                        end
                    end
                end
            end
        end
    end

    if !isempty(blocked_exports)
        conflict_source = isempty(conflicts_with) ? "" : " (from $(join(collect(conflicts_with), ", ")))"

        @warn """
        FastKML.jl exports were blocked by existing definitions$conflict_source: $(join(blocked_exports, ", "))

        To use FastKML's geometry types:
        • Import FastKML first:
          using FastKML
          using GeometryBasics  # or other geometry packages
        • Or use qualified names:
          FastKML.Point(coordinates=(1.0, 2.0))
          df = DataFrame(kml_file)  # Other FastKML functions work normally
        """
    end
end

end # module FastKML
