module FastKMLGeoInterfaceExt

using FastKML
using GeoInterface
import Base: show

const GI = GeoInterface

# --- Generic helpers for all FastKML.Geometry subtypes ---
GI.isgeometry(::FastKML.Geometry) = true
GI.isgeometry(::Type{<:FastKML.Geometry}) = true

GI.crs(::FastKML.Geometry) = GI.default_crs()
GI.crs(::FastKML.Placemark) = GI.default_crs()

# --- Point ---
GI.geomtrait(::FastKML.Point) = GI.PointTrait()
GI.ngeom(::GI.PointTrait, geom::FastKML.Point) = 0 # A point has no sub-geometries
GI.ncoord(::GI.PointTrait, geom::FastKML.Point) = geom.coordinates === nothing ? 0 : length(geom.coordinates)
GI.getcoord(::GI.PointTrait, geom::FastKML.Point, i::Integer) = geom.coordinates[i]

# --- LineString ---
GI.geomtrait(::FastKML.LineString) = GI.LineStringTrait()
GI.ngeom(::GI.LineStringTrait, geom::FastKML.LineString) = geom.coordinates === nothing ? 0 : length(geom.coordinates) # Number of points
GI.getgeom(::GI.LineStringTrait, geom::FastKML.LineString, i::Integer) = FastKML.Point(coordinates=geom.coordinates[i]) # Wrap point in FastKML.Point
GI.ncoord(::GI.LineStringTrait, geom::FastKML.LineString) = # Number of dimensions
    (geom.coordinates === nothing || isempty(geom.coordinates)) ? 0 : length(geom.coordinates[1])

# --- LinearRing ---
GI.geomtrait(::FastKML.LinearRing) = GI.LinearRingTrait()
GI.ngeom(::GI.LinearRingTrait, geom::FastKML.LinearRing) = geom.coordinates === nothing ? 0 : length(geom.coordinates) # Number of points
GI.getgeom(::GI.LinearRingTrait, geom::FastKML.LinearRing, i::Integer) = FastKML.Point(coordinates=geom.coordinates[i]) # Wrap point in FastKML.Point
GI.ncoord(::GI.LinearRingTrait, geom::FastKML.LinearRing) = # Number of dimensions
    (geom.coordinates === nothing || isempty(geom.coordinates)) ? 0 : length(geom.coordinates[1])

# --- Polygon ---
GI.geomtrait(::FastKML.Polygon) = GI.PolygonTrait()
GI.ngeom(::GI.PolygonTrait, geom::FastKML.Polygon) = 1 + (geom.innerBoundaryIs === nothing ? 0 : length(geom.innerBoundaryIs)) # Number of rings
GI.getgeom(::GI.PolygonTrait, geom::FastKML.Polygon, i::Integer) =
    i == 1 ? geom.outerBoundaryIs : geom.innerBoundaryIs[i-1] # Returns a FastKML.LinearRing
GI.ncoord(::GI.PolygonTrait, geom::FastKML.Polygon) = # Number of dimensions
    (geom.outerBoundaryIs === nothing || geom.outerBoundaryIs.coordinates === nothing || isempty(geom.outerBoundaryIs.coordinates)) ? 0 : length(geom.outerBoundaryIs.coordinates[1])

# --- MultiGeometry (Dynamic Trait Dispatch) ---
function GI.geomtrait(mg::FastKML.MultiGeometry)
    if mg.Geometries === nothing || isempty(mg.Geometries)
        return GI.GeometryCollectionTrait()
    end
    
    first_geom_type = typeof(mg.Geometries[1])

    if first_geom_type <: FastKML.Polygon && all(g -> isa(g, FastKML.Polygon), mg.Geometries)
        return GI.MultiPolygonTrait()
    elseif first_geom_type <: FastKML.LineString && all(g -> isa(g, FastKML.LineString), mg.Geometries)
        return GI.MultiLineStringTrait()
    elseif first_geom_type <: FastKML.Point && all(g -> isa(g, FastKML.Point), mg.Geometries)
        return GI.MultiPointTrait()
    else
        return GI.GeometryCollectionTrait()
    end
end

# Methods for FastKML.MultiGeometry based on its dynamically determined trait

# For MultiPolygonTrait
GI.ngeom(::GI.MultiPolygonTrait, mg::FastKML.MultiGeometry) = length(mg.Geometries)
GI.getgeom(::GI.MultiPolygonTrait, mg::FastKML.MultiGeometry, i::Integer) = mg.Geometries[i] # Returns FastKML.Polygon
GI.ncoord(::GI.MultiPolygonTrait, mg::FastKML.MultiGeometry) =
    (mg.Geometries === nothing || isempty(mg.Geometries)) ? 0 : GI.ncoord(GI.PolygonTrait(), mg.Geometries[1])

# For MultiLineStringTrait
GI.ngeom(::GI.MultiLineStringTrait, mg::FastKML.MultiGeometry) = length(mg.Geometries)
GI.getgeom(::GI.MultiLineStringTrait, mg::FastKML.MultiGeometry, i::Integer) = mg.Geometries[i] # Returns FastKML.LineString
GI.ncoord(::GI.MultiLineStringTrait, mg::FastKML.MultiGeometry) =
    (mg.Geometries === nothing || isempty(mg.Geometries)) ? 0 : GI.ncoord(GI.LineStringTrait(), mg.Geometries[1])

# For MultiPointTrait
GI.ngeom(::GI.MultiPointTrait, mg::FastKML.MultiGeometry) = length(mg.Geometries)
GI.getgeom(::GI.MultiPointTrait, mg::FastKML.MultiGeometry, i::Integer) = mg.Geometries[i] # Returns FastKML.Point
GI.ncoord(::GI.MultiPointTrait, mg::FastKML.MultiGeometry) =
    (mg.Geometries === nothing || isempty(mg.Geometries)) ? 0 : GI.ncoord(GI.PointTrait(), mg.Geometries[1])

# For GeometryCollectionTrait (fallback)
GI.ngeom(::GI.GeometryCollectionTrait, mg::FastKML.MultiGeometry) =
    mg.Geometries === nothing ? 0 : length(mg.Geometries)
GI.getgeom(::GI.GeometryCollectionTrait, mg::FastKML.MultiGeometry, i::Integer) = mg.Geometries[i]
GI.ncoord(::GI.GeometryCollectionTrait, mg::FastKML.MultiGeometry) = # Dimension of the first element, or 0 if empty/mixed might be undefined
    (mg.Geometries === nothing || isempty(mg.Geometries)) ? 0 : GI.ncoord(GI.geomtrait(mg.Geometries[1]), mg.Geometries[1])

# --- Placemark feature helpers ---
GI.isfeature(::FastKML.Placemark) = true
GI.isfeature(::Type{FastKML.Placemark}) = true

const _PLACEMARK_PROP_FIELDS = Tuple(
    filter(
        f -> f != :Geometry && f != :id && f != :targetId,
        fieldnames(FastKML.Placemark)
    )
)

GI.properties(p::FastKML.Placemark) = begin
    props = (; (f => getfield(p, f) for f in _PLACEMARK_PROP_FIELDS if getfield(p,f) !== nothing)...)
    # Ensure we always have at least one property for GeoInterface compatibility
    isempty(props) ? (hasGeometry = p.Geometry !== nothing,) : props
end
GI.trait(::FastKML.Placemark) = GI.FeatureTrait()
GI.geometry(p::FastKML.Placemark) = p.Geometry

# --- Internal helper for Base.show ---
function _get_geom_display_info(geom)
    trait = GI.geomtrait(geom)
    is_3d = false
    coord_dim = 0
    # This try-catch is a fallback for safety, ideally ncoord is always defined for valid trait-geom pairs
    try
        coord_dim = GI.ncoord(trait, geom)
    catch e
        # This might happen if a trait is returned for which ncoord isn't (or can't be)
        # meaningfully defined for the underlying KML type directly.
        # For display, we might infer from a sub-geometry if possible.
        if geom isa FastKML.MultiGeometry && geom.Geometries !== nothing && !isempty(geom.Geometries)
            first_sub_geom = geom.Geometries[1]
            sub_trait = GI.geomtrait(first_sub_geom)
            coord_dim = GI.ncoord(sub_trait, first_sub_geom) # Try ncoord of first sub-element
        else
            coord_dim = 0 # Default or error
        end
    end
    is_3d = (coord_dim == 3)
    return is_3d, coord_dim
end

# Enhanced show for geometries with DataFrame-aware coloring
function Base.show(io::IO, g::FastKML.Geometry)
    trait = GI.geomtrait(g)
    trait_name_str = replace(string(nameof(typeof(trait))), "Trait" => "")
    
    is_3d_disp, coord_dim_disp = _get_geom_display_info(g)
    zm_suffix = is_3d_disp ? " Z" : ""
    
    # Smart color detection
    in_dataframe = (get(io, :compact, false) && get(io, :limit, false)) ||
                   (get(io, :typeinfo, nothing) === Vector{Any})
    color_requested = get(io, :color, false)
    
    # Never use color in DataFrame cells
    use_color = !in_dataframe && color_requested
    
    # Type name with optional color
    if use_color
        printstyled(io, trait_name_str, zm_suffix; color = :light_cyan)
    else
        print(io, trait_name_str, zm_suffix)
    end
    
    # Summary information
    summary_parts = String[]
    
    if trait isa GI.PointTrait
        if g.coordinates !== nothing
            coord_str = "($(join(g.coordinates, ", ")))"
            push!(summary_parts, coord_str)  # No color in summary parts
        else
            push!(summary_parts, "(empty)")
        end
    elseif trait isa GI.AbstractCurveTrait || trait isa GI.AbstractPolygonTrait ||
           trait isa GI.AbstractMultiPointTrait || trait isa GI.AbstractMultiCurveTrait ||
           trait isa GI.AbstractMultiPolygonTrait
        n = GI.ngeom(trait, g)
        item_name_singular = "part"
        item_name_plural = "parts"
        
        # Determine specific item names
        if n > 0
            local first_sub_geom_obj
            try
                first_sub_geom_obj = GI.getgeom(trait, g, 1)
            catch
                first_sub_geom_obj = nothing
            end
            
            if trait isa GI.MultiPolygonTrait || trait isa GI.PolygonTrait
                item_name_singular = "ring"; item_name_plural = "rings"
                if trait isa GI.MultiPolygonTrait && first_sub_geom_obj isa FastKML.Polygon
                    item_name_singular = "polygon"
                    item_name_plural = "polygons"
                end
            elseif trait isa GI.MultiCurveTrait || trait isa GI.LineStringTrait || trait isa GI.LinearRingTrait
                item_name_singular = "point"; item_name_plural = "points"
                if trait isa GI.MultiCurveTrait && first_sub_geom_obj isa FastKML.LineString
                    item_name_singular = "linestring"
                    item_name_plural = "linestrings"
                end
            elseif trait isa GI.MultiPointTrait
                item_name_singular = "point"; item_name_plural = "points"
            end
        end
        
        count_str = "with $n " * (n == 1 ? item_name_singular : item_name_plural)
        push!(summary_parts, count_str)  # No color in summary parts
    elseif trait isa GI.GeometryCollectionTrait
        n = GI.ngeom(trait, g)
        count_str = "with $n " * (n == 1 ? "geometry" : "geometries")
        push!(summary_parts, count_str)  # No color in summary parts
    end
    
    if !isempty(summary_parts)
        # Print the summary with optional color on the whole thing
        if use_color
            printstyled(io, " ", join(summary_parts, ", "); color = :green)
        else
            print(io, " ", join(summary_parts, ", "))
        end
    end
    
    # Preview coordinates
    preview_pt_strings = String[]
    if (trait isa GI.LineStringTrait || trait isa GI.LinearRingTrait) &&
       hasfield(typeof(g), :coordinates) && g.coordinates !== nothing && GI.ngeom(trait, g) > 0
        coords_to_show = min(GI.ngeom(trait, g), 2)
        for i in 1:coords_to_show
            pt_obj = GI.getgeom(trait, g, i)
            if hasfield(typeof(pt_obj), :coordinates) && pt_obj.coordinates !== nothing
                push!(preview_pt_strings, "($(join(pt_obj.coordinates, " ")))")
            end
        end
        
        if !isempty(preview_pt_strings)
            preview_str = " (" * join(preview_pt_strings, ", ") * 
                         (GI.ngeom(trait, g) > length(preview_pt_strings) ? ", ..." : "") * ")"
            if use_color
                printstyled(io, preview_str; color = :light_gray)
            else
                print(io, preview_str)
            end
        end
    elseif trait isa GI.PolygonTrait && GI.ngeom(trait, g) > 0
        outer_ring_obj = GI.getgeom(trait, g, 1)
        if outer_ring_obj isa FastKML.LinearRing && hasfield(typeof(outer_ring_obj), :coordinates) && 
           outer_ring_obj.coordinates !== nothing && GI.ngeom(GI.LinearRingTrait(), outer_ring_obj) > 0
            coords_to_show = min(GI.ngeom(GI.LinearRingTrait(), outer_ring_obj), 2)
            for i in 1:coords_to_show
                pt_obj = GI.getgeom(GI.LinearRingTrait(), outer_ring_obj, i)
                if hasfield(typeof(pt_obj), :coordinates) && pt_obj.coordinates !== nothing
                    push!(preview_pt_strings, "($(join(pt_obj.coordinates, " ")))")
                end
            end
            
            if !isempty(preview_pt_strings)
                preview_str = " (outer: " * join(preview_pt_strings, ", ") * 
                             (GI.ngeom(GI.LinearRingTrait(), outer_ring_obj) > length(preview_pt_strings) ? ", ..." : "") * ")"
                if use_color
                    printstyled(io, preview_str; color = :light_gray)
                else
                    print(io, preview_str)
                end
            end
        end
    end
end

end # module FastKMLGeoInterfaceExt