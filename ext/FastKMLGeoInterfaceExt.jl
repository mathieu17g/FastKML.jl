module FastKMLGeoInterfaceExt

using FastKML
using GeoInterface
import GeoFormatTypes
import Base: show

const GI = GeoInterface

# --- Generic helpers for all FastKML.Geometry subtypes ---
GI.isgeometry(::FastKML.Geometry) = true
GI.isgeometry(::Type{<:FastKML.Geometry}) = true

# The OGC KML standard (2.3, Annex B) gives KML coordinates in WGS 84 with the longitude
# first, "adapted from EPSG-4326". An altitude is a height above the EGM96 geoid in the
# altitude mode `absolute` (EPSG:9707), above the terrain or ignored in the other modes, so
# `crs` gives the horizontal system alone.
GI.crs(::FastKML.Geometry) = GeoFormatTypes.EPSG(4326)
GI.crs(::FastKML.Placemark) = GeoFormatTypes.EPSG(4326)

# An optional list is read once into a local. An absent list counts as an empty one:
# indexing it is out of bounds, as for the features of a Document.
_count(list) = list === nothing ? 0 : length(list)
_at(list, owner, i) = list === nothing ? throw(BoundsError(owner, i)) : list[i]
# Number of dimensions of a list of points: that of its first point, 0 without points
_dims(points) = (points === nothing || isempty(points)) ? 0 : length(points[1])

# --- Point ---
GI.geomtrait(::FastKML.Point) = GI.PointTrait()
GI.ngeom(::GI.PointTrait, geom::FastKML.Point) = 0 # A point has no sub-geometries
GI.ncoord(::GI.PointTrait, geom::FastKML.Point) = _count(geom.coordinates)
GI.getcoord(::GI.PointTrait, geom::FastKML.Point, i::Integer) =
    _at(geom.coordinates, geom, i)

# --- LineString and LinearRing: number of points, points wrapped in a FastKML.Point, and
# number of dimensions ---
GI.geomtrait(::FastKML.LineString) = GI.LineStringTrait()
GI.ngeom(::GI.LineStringTrait, geom::FastKML.LineString) = _count(geom.coordinates)
GI.getgeom(::GI.LineStringTrait, geom::FastKML.LineString, i::Integer) =
    FastKML.Point(coordinates = _at(geom.coordinates, geom, i))
GI.ncoord(::GI.LineStringTrait, geom::FastKML.LineString) = _dims(geom.coordinates)

GI.geomtrait(::FastKML.LinearRing) = GI.LinearRingTrait()
GI.ngeom(::GI.LinearRingTrait, geom::FastKML.LinearRing) = _count(geom.coordinates)
GI.getgeom(::GI.LinearRingTrait, geom::FastKML.LinearRing, i::Integer) =
    FastKML.Point(coordinates = _at(geom.coordinates, geom, i))
GI.ncoord(::GI.LinearRingTrait, geom::FastKML.LinearRing) = _dims(geom.coordinates)

# --- Polygon: its rings, the outer one first ---
GI.geomtrait(::FastKML.Polygon) = GI.PolygonTrait()
GI.ngeom(::GI.PolygonTrait, geom::FastKML.Polygon) = 1 + _count(geom.innerBoundaryIs)
function GI.getgeom(::GI.PolygonTrait, geom::FastKML.Polygon, i::Integer) # A LinearRing
    i == 1 && return geom.outerBoundaryIs
    inner = geom.innerBoundaryIs
    return inner === nothing ? throw(BoundsError(geom, i)) : inner[i-1]
end
GI.ncoord(::GI.PolygonTrait, geom::FastKML.Polygon) =
    _dims(geom.outerBoundaryIs.coordinates)

# --- MultiGeometry (Dynamic Trait Dispatch) ---
function GI.geomtrait(mg::FastKML.MultiGeometry)
    geoms = mg.Geometries
    if geoms === nothing || isempty(geoms)
        return GI.GeometryCollectionTrait()
    end

    first_geom_type = typeof(geoms[1])

    if first_geom_type <: FastKML.Polygon && all(g -> isa(g, FastKML.Polygon), geoms)
        return GI.MultiPolygonTrait()
    elseif first_geom_type <: FastKML.LineString &&
           all(g -> isa(g, FastKML.LineString), geoms)
        return GI.MultiLineStringTrait()
    elseif first_geom_type <: FastKML.Point && all(g -> isa(g, FastKML.Point), geoms)
        return GI.MultiPointTrait()
    else
        return GI.GeometryCollectionTrait()
    end
end

# Number of dimensions of a geometry, 0 for one without a GeoInterface trait (a Model or a
# track). One method per type, so that each trait meets only its own geometry type.
_ncoord(g::FastKML.Point) = GI.ncoord(GI.PointTrait(), g)
_ncoord(g::FastKML.LineString) = GI.ncoord(GI.LineStringTrait(), g)
_ncoord(g::FastKML.LinearRing) = GI.ncoord(GI.LinearRingTrait(), g)
_ncoord(g::FastKML.Polygon) = GI.ncoord(GI.PolygonTrait(), g)
_ncoord(g::FastKML.MultiGeometry) = GI.ncoord(GI.geomtrait(g), g)
_ncoord(g) = 0

# Methods for FastKML.MultiGeometry based on its dynamically determined trait, the same for
# each trait. A collection takes the dimension of its first geometry, 0 if it has none.
function _first_ncoord(mg)
    geoms = mg.Geometries
    return (geoms === nothing || isempty(geoms)) ? 0 : _ncoord(geoms[1])
end
for T in (GI.MultiPolygonTrait, GI.MultiLineStringTrait, GI.MultiPointTrait,
          GI.GeometryCollectionTrait)
    @eval begin
        GI.ngeom(::$T, mg::FastKML.MultiGeometry) = _count(mg.Geometries)
        GI.getgeom(::$T, mg::FastKML.MultiGeometry, i::Integer) = _at(mg.Geometries, mg, i)
        GI.ncoord(::$T, mg::FastKML.MultiGeometry) = _first_ncoord(mg)
    end
end

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

# --- Internal helpers for Base.show ---
function _get_geom_display_info(geom)
    coord_dim = _ncoord(geom)
    return coord_dim == 3, coord_dim
end

# Summary of a geometry, from its type; the trait matters only for a MultiGeometry, whose
# trait depends on its geometries
_count_str(n, singular, plural) = "with $n " * (n == 1 ? singular : plural)
function _summary(g::FastKML.Point, trait)
    coords = g.coordinates
    return coords === nothing ? "(empty)" : "($(join(coords, ", ")))"
end
function _summary(g::Union{FastKML.LineString, FastKML.LinearRing}, trait)
    n = _count(g.coordinates)
    return n == 0 ? _count_str(n, "part", "parts") : _count_str(n, "point", "points")
end
_summary(g::FastKML.Polygon, trait) =
    _count_str(1 + _count(g.innerBoundaryIs), "ring", "rings")
function _summary(g::FastKML.MultiGeometry, trait)
    n = _count(g.Geometries)
    trait isa GI.MultiPolygonTrait && return _count_str(n, "polygon", "polygons")
    trait isa GI.MultiPointTrait && return _count_str(n, "point", "points")
    trait isa GI.MultiLineStringTrait && return _count_str(n, "part", "parts")
    return _count_str(n, "geometry", "geometries")
end

# Preview of the first two points of a line or of the outer ring of a polygon, "" if there
# is none
function _preview_points(points, prefix)
    (points === nothing || isempty(points)) && return ""
    n = length(points)
    shown = ["($(join(points[i], " ")))" for i in 1:min(n, 2)]
    return " (" * prefix * join(shown, ", ") * (n > length(shown) ? ", ..." : "") * ")"
end
_preview(g::Union{FastKML.LineString, FastKML.LinearRing}) =
    _preview_points(g.coordinates, "")
_preview(g::FastKML.Polygon) = _preview_points(g.outerBoundaryIs.coordinates, "outer: ")
_preview(g) = ""

# Enhanced show for geometries with DataFrame-aware coloring. It names the GeoInterface
# trait, so it covers only the geometries that have one: a Model or a track keeps the
# display of FastKML.
const TraitGeometry = Union{FastKML.Point, FastKML.LineString, FastKML.LinearRing,
                            FastKML.Polygon, FastKML.MultiGeometry}
function Base.show(io::IO, g::TraitGeometry)
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
    
    # Summary information, from the type of the geometry
    summary = _summary(g, trait)
    if !isempty(summary)
        # Print the summary with optional color on the whole thing
        if use_color
            printstyled(io, " ", summary; color = :green)
        else
            print(io, " ", summary)
        end
    end

    # Preview coordinates
    preview_str = _preview(g)
    if !isempty(preview_str)
        if use_color
            printstyled(io, preview_str; color = :light_gray)
        else
            print(io, preview_str)
        end
    end
end

end # module FastKMLGeoInterfaceExt
