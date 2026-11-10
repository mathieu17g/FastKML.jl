module FastKML

# Base dependencies
using OrderedCollections: OrderedDict
using StaticArrays
using Automa, Parsers
using TimeZones, Dates

# XML LazyNode and Node iterating macros helpers
include("macros.jl")

# Include all modules in dependency order
include("content_warnings.jl")
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
using .Types: dates
using .Enums
using .Coordinates: coordinate_string, Coord2, Coord3
using .XMLSerialization: to_xml, xml_children, Node
using .XMLParsing: object
using .Layers: list_layers, get_layer_names, get_num_layers
using .TablesBridge: PlacemarkTable
using .Utils: unwrap_single_part_multigeometry
using .Navigation: children

# The exported names are the entry points: the two kinds of file, the table of placemarks,
# the coordinate and date types that fields hold, and the functions
export KMLFile, LazyKMLFile, object
export children, to_xml, xml_children
export unwrap_single_part_multigeometry
export PlacemarkTable, list_layers, get_layer_names, get_num_layers
export coordinate_string, Coord2, Coord3
export dates, PartialDate

# The types of KML elements and the enumerations are not exported, since other packages
# export a `Point`, a `Polygon`, a `Camera` or a `Document` too: they take the prefix of the
# module, as in `FastKML.Point`, and are declared public. Julia 1.10 has no `public` keyword
# and fails to parse it, hence the expression. `NoAttributes`, the supertype of the elements
# without attributes, `AbstractKMLEnum`, and the functions, tables and macro of both modules
# are for FastKML's own code.
@static if VERSION >= v"1.11.0-DEV.469"
    for (m, internal) in ((Types, :NoAttributes), (Enums, :AbstractKMLEnum))
        for name in names(m; all = false)
            getglobal(m, name) isa Type && name != internal || continue
            Base.isexported(@__MODULE__, name) || eval(Expr(:public, name))
        end
    end
end

# ─── Make KMLFile Iterable and Indexable ────────────────────────────────────

Base.iterate(k::KMLFile, state...) = iterate(k.children, state...)
Base.length(k::KMLFile) = length(k.children)
Base.eltype(::Type{KMLFile}) = Union{Types.XMLAnyNode, KMLElement}
Base.getindex(k::KMLFile, i) = k.children[i]
Base.firstindex(k::KMLFile) = 1
Base.lastindex(k::KMLFile) = length(k.children)

# Optional: Add similar functionality for Document and Folder
Base.iterate(d::Document, state...) = (fs = d.Features; fs === nothing ? nothing : iterate(fs, state...))
Base.length(d::Document) = (fs = d.Features; fs === nothing ? 0 : length(fs))
Base.getindex(d::Document, i) = (fs = d.Features; fs === nothing ? throw(BoundsError(d, i)) : fs[i])

Base.iterate(f::Folder, state...) = (fs = f.Features; fs === nothing ? nothing : iterate(fs, state...))
Base.length(f::Folder) = (fs = f.Features; fs === nothing ? 0 : length(fs))
Base.getindex(f::Folder, i) = (fs = f.Features; fs === nothing ? throw(BoundsError(f, i)) : fs[i])

# ─── Initialization ──────────────────────────────────────────────────────────

function __init__()
    # Register error hints for KMZ support
    Base.Experimental.register_error_hint(IO._read_kmz_file_from_path_error_hinter, ErrorException)
end

end # module FastKML
