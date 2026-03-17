module TablesBridge

export PlacemarkTable

import Tables
import ..Layers: get_layer_info, select_layer
import ..Types: KMLFile, LazyKMLFile, Feature, Document, Folder, Placemark, Geometry,
                LinearRing, Point, LineString, Polygon, MultiGeometry, Coord2, Coord3
import ..XMLParsing: object, extract_text_content_fast
import ..Macros: @find_immediate_child, @for_each_immediate_child
import ..HtmlEntities: decode_named_entities
import ..Coordinates: parse_coordinates_automa
import ..Utils: unwrap_single_part_multigeometry
import XML: XML, parse, Node, LazyNode, tag, children, attributes
using StaticArrays
using Base.Iterators: flatten

# Use the parent module's types to ensure consistent display
const KML = parentmodule(@__MODULE__)

#────────────────────────── Optimized Lazy Iterator Types ──────────────────────────#

# ===== Optimized Eager Collection (FASTEST - Recommended) =====
struct EagerLazyPlacemarkIterator
    placemarks::Vector{NamedTuple{(:name, :description, :geometry),Tuple{String,String,Union{Missing,Geometry}}}}

    function EagerLazyPlacemarkIterator(root_node::XML.AbstractXMLNode)
        placemarks = Vector{NamedTuple{(:name, :description, :geometry),Tuple{String,String,Union{Missing,Geometry}}}}()
        sizehint!(placemarks, 1000)  # Pre-allocate for typical layer size

        _collect_placemarks_optimized!(placemarks, root_node)

        # Shrink to fit
        sizehint!(placemarks, length(placemarks))

        new(placemarks)
    end
end

# Optimized collection with minimal allocations
function _collect_placemarks_optimized!(placemarks::Vector, node::XML.AbstractXMLNode)
    @for_each_immediate_child node child begin
        XML.nodetype(child) === XML.Element || continue
        
        child_tag = tag(child)
        
        if child_tag == "Placemark"
            placemark_data = extract_placemark_fields_lazy(child)
            push!(placemarks, placemark_data)
        elseif child_tag in ("Document", "Folder")
            _collect_placemarks_optimized!(placemarks, child)
        end
    end
end

# Fast iteration for eager collection
Base.iterate(iter::EagerLazyPlacemarkIterator, state = 1) =
    state > length(iter.placemarks) ? nothing : (iter.placemarks[state], state + 1)

Base.length(iter::EagerLazyPlacemarkIterator) = length(iter.placemarks)
Base.IteratorSize(::Type{EagerLazyPlacemarkIterator}) = Base.HasLength()
Base.eltype(::Type{EagerLazyPlacemarkIterator}) = eltype(iter.placemarks)

#─────────────────────────────────────────────────────────────────────────────────────#

# Minimal geometry parsing - only what's needed for DataFrame
function parse_geometry_lazy(geom_node::XML.AbstractXMLNode)
    geom_tag = tag(geom_node)

    if geom_tag == "Point"
        # Extract coordinates directly
        coord_child = @find_immediate_child geom_node child begin
            XML.nodetype(child) === XML.Element && tag(child) == "coordinates"
        end
        
        if coord_child !== nothing
            coord_text = extract_text_content_fast(coord_child)
            coords = parse_coordinates_automa(coord_text)
            if !isempty(coords)
                return Point(; coordinates = coords[1])
            end
        end
        return Point(; coordinates = nothing)

    elseif geom_tag == "LineString"
        coord_child = @find_immediate_child geom_node child begin
            XML.nodetype(child) === XML.Element && tag(child) == "coordinates"
        end
        
        if coord_child !== nothing
            coord_text = extract_text_content_fast(coord_child)
            coords = parse_coordinates_automa(coord_text)
            return LineString(; coordinates = isempty(coords) ? nothing : coords)
        end
        return LineString(; coordinates = nothing)

    elseif geom_tag == "Polygon"
        outer_ring = nothing
        inner_rings = LinearRing[]

        @for_each_immediate_child geom_node child begin
            if XML.nodetype(child) === XML.Element
                child_tag = tag(child)
                if child_tag == "outerBoundaryIs"
                    lr_child = @find_immediate_child child boundary_child begin
                        XML.nodetype(boundary_child) === XML.Element && tag(boundary_child) == "LinearRing"
                    end
                    if lr_child !== nothing
                        outer_ring = parse_linear_ring_lazy(lr_child)
                    end
                elseif child_tag == "innerBoundaryIs"
                    @for_each_immediate_child child boundary_child begin
                        if XML.nodetype(boundary_child) === XML.Element && tag(boundary_child) == "LinearRing"
                            ring = parse_linear_ring_lazy(boundary_child)
                            if ring !== nothing && ring.coordinates !== nothing && !isempty(ring.coordinates)
                                push!(inner_rings, ring)
                            end
                        end
                    end
                end
            end
        end

        if outer_ring !== nothing
            return Polygon(; outerBoundaryIs = outer_ring, innerBoundaryIs = isempty(inner_rings) ? nothing : inner_rings)
        else
            # Return empty polygon with default empty LinearRing
            return Polygon(; outerBoundaryIs = LinearRing())
        end

    elseif geom_tag == "MultiGeometry"
        geometries = Geometry[]
        @for_each_immediate_child geom_node child begin
            if XML.nodetype(child) === XML.Element && tag(child) in ("Point", "LineString", "Polygon", "MultiGeometry")
                geom = parse_geometry_lazy(child)
                if !ismissing(geom)
                    push!(geometries, geom)
                end
            end
        end
        return MultiGeometry(; Geometries = isempty(geometries) ? nothing : geometries)
    end

    return missing
end

function parse_linear_ring_lazy(ring_node::XML.AbstractXMLNode)
    coord_child = @find_immediate_child ring_node child begin
        XML.nodetype(child) === XML.Element && tag(child) == "coordinates"
    end
    
    if coord_child !== nothing
        coord_text = extract_text_content_fast(coord_child)
        coords = parse_coordinates_automa(coord_text)
        return LinearRing(; coordinates = isempty(coords) ? nothing : coords)
    end
    
    return LinearRing(; coordinates = nothing)
end

# Extract only the fields needed for DataFrame
function extract_placemark_fields_lazy(placemark_node::XML.AbstractXMLNode)
    name = ""
    description = ""
    geometry = missing
    
    # Track if we have all required fields
    has_name = false
    has_description = false
    has_geometry = false
    
    @for_each_immediate_child placemark_node child begin
        XML.nodetype(child) === XML.Element || continue
        
        child_tag = tag(child)
        
        if child_tag == "name" && !has_name
            name = extract_text_content_fast(child)
            if occursin('&', name)
                name = decode_named_entities(name)
            end
            has_name = true
        elseif child_tag == "description" && !has_description
            description = extract_text_content_fast(child)
            has_description = true
        elseif child_tag in ("Point", "LineString", "Polygon", "MultiGeometry") && !has_geometry
            geometry = parse_geometry_lazy(child)
            has_geometry = true
        end
    end
    
    return (name = name, description = description, geometry = geometry)
end

#────────────────────────── streaming iterator over placemarks ──────────────────────────#

# Eager iterator for KMLFile
function _placemark_iterator(file::KMLFile, layer_spec::Union{Nothing,String,Integer})
    selected_source = select_layer(file, layer_spec)
    return _iter_feat(selected_source)
end

# Eager iteration
function _iter_feat(x)
    if x isa Placemark
        return (x for _ = 1:1)
    elseif (x isa Document || x isa Folder) && x.Features !== nothing
        return flatten(_iter_feat.(x.Features))
    elseif x isa AbstractVector{<:Feature}
        return flatten(_iter_feat.(x))
    else
        return ()
    end
end

# Lazy iterator for LazyKMLFile
function _placemark_iterator(file::LazyKMLFile, layer_spec::Union{Nothing,String,Integer})
    selected_source = select_layer(file, layer_spec)
    if selected_source === nothing
        return (p for p in ()) # Return empty iterator if no layer found
    end
    return EagerLazyPlacemarkIterator(selected_source)
end

#──────────────────────────── streaming PlacemarkTable type ────────────────────────────#
"""
    PlacemarkTable(source; layer=nothing, simplify_single_parts=false)

A lazy, streaming Tables.jl table of the placemarks in a KML file.
You can call it either with a path or with an already-loaded `KMLFile` or `LazyKMLFile`.
"""
struct PlacemarkTable
    file::Union{KMLFile,LazyKMLFile}
    layer::Union{Nothing,String,Integer}
    simplify_single_parts::Bool
end

PlacemarkTable(
    file::Union{KMLFile,LazyKMLFile};
    layer::Union{Nothing,String,Integer} = nothing,
    simplify_single_parts::Bool = false,
) = PlacemarkTable(file, layer, simplify_single_parts)

PlacemarkTable(path::AbstractString; layer::Union{Nothing,String,Integer} = nothing, simplify_single_parts::Bool = false) =
    PlacemarkTable(Base.read(path, LazyKMLFile); layer = layer, simplify_single_parts = simplify_single_parts)

#──────────────────────────────── Tables.jl API ──────────────────────────────────#
Tables.istable(::Type{<:PlacemarkTable}) = true
Tables.rowaccess(::Type{<:PlacemarkTable}) = true

Tables.schema(::PlacemarkTable) = Tables.Schema((:name, :description, :geometry), (String, String, Union{Missing,Geometry}))

function Tables.rows(tbl::PlacemarkTable)
    it = _placemark_iterator(tbl.file, tbl.layer)

    if tbl.file isa LazyKMLFile
        # Lazy path - data is already in the right format
        return (
            let pl = pl
                geom_to_return = pl.geometry
                if tbl.simplify_single_parts && !ismissing(geom_to_return)
                    geom_to_return = unwrap_single_part_multigeometry(geom_to_return)
                end
                (name = pl.name, description = pl.description, geometry = geom_to_return)
            end for pl in it
        )
    else
        # Eager path - existing logic
        return (
            let pl = pl
                desc = if pl.description === nothing
                    ""
                else
                    pl.description
                end
                name_str = pl.name === nothing ? "" : pl.name
                processed_name = if pl.name !== nothing && occursin('&', name_str)
                    decode_named_entities(name_str)
                else
                    name_str
                end
                geom_to_return = pl.Geometry
                if tbl.simplify_single_parts
                    geom_to_return = unwrap_single_part_multigeometry(geom_to_return)
                end
                (name = processed_name, description = desc, geometry = geom_to_return)
            end for pl in it if pl isa Placemark
        )
    end
end

# --- Tables.jl API for KMLFile and LazyKMLFile ---
Tables.istable(::Type{KMLFile}) = true
Tables.istable(::Type{LazyKMLFile}) = true
Tables.rowaccess(::Type{KMLFile}) = true
Tables.rowaccess(::Type{LazyKMLFile}) = true

function Tables.schema(
    k::Union{KMLFile,LazyKMLFile};
    layer::Union{Nothing,String,Integer} = nothing,
    simplify_single_parts::Bool = false,
)
    return Tables.schema(PlacemarkTable(k; layer = layer, simplify_single_parts = simplify_single_parts))
end

function Tables.rows(
    k::Union{KMLFile,LazyKMLFile};
    layer::Union{Nothing,String,Integer} = nothing,
    simplify_single_parts::Bool = false,
)
    return Tables.rows(PlacemarkTable(k; layer = layer, simplify_single_parts = simplify_single_parts))
end

end # module TablesBridge