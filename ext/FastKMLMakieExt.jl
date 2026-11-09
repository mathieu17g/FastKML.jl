module FastKMLMakieExt

using FastKML
using Makie

# Define plotting recipes for KML geometry types
Makie.plottype(::FastKML.Point) = Makie.Scatter
Makie.plottype(::FastKML.LineString) = Makie.Lines
Makie.plottype(::FastKML.LinearRing) = Makie.Lines
Makie.plottype(::FastKML.Polygon) = Makie.Poly

# Point plotting
function Makie.convert_arguments(P::Type{<:Scatter}, point::FastKML.Point)
    coords = point.coordinates
    isnothing(coords) && return ([Point2f(NaN, NaN)],)
    return ([Point2f(coords[1], coords[2])],)
end

# LineString plotting
function Makie.convert_arguments(P::Type{<:Lines}, ls::FastKML.LineString)
    coords = ls.coordinates
    isnothing(coords) && return ([Point2f(NaN, NaN)],)
    return ([Point2f(c[1], c[2]) for c in coords],)
end

# LinearRing plotting (same as LineString)
function Makie.convert_arguments(P::Type{<:Lines}, lr::FastKML.LinearRing)
    coords = lr.coordinates
    isnothing(coords) && return ([Point2f(NaN, NaN)],)
    return ([Point2f(c[1], c[2]) for c in coords],)
end

# The holes of a polygon as vectors of points, or `nothing` if it has no inner ring. A ring
# without coordinates gives no hole.
function _holes(poly::FastKML.Polygon)
    inner = poly.innerBoundaryIs
    (inner === nothing || isempty(inner)) && return nothing
    holes = Vector{Point2f}[]
    for ring in inner
        coords = ring.coordinates
        isnothing(coords) || push!(holes, [Point2f(c[1], c[2]) for c in coords])
    end
    return holes
end

# Polygon plotting with proper hole support using GeometryBasics
function Makie.convert_arguments(P::Type{<:Poly}, poly::FastKML.Polygon)
    outer = poly.outerBoundaryIs.coordinates
    isnothing(outer) && return ([Point2f(NaN, NaN)],)

    # Convert outer boundary
    outer_points = [Point2f(c[1], c[2]) for c in outer]

    # A GeometryBasics Polygon when the polygon has inner rings, else just the points
    holes = _holes(poly)
    isnothing(holes) && return (outer_points,)
    return (Makie.GeometryBasics.Polygon(outer_points, holes),)
end

# Recipe for MultiGeometry
@recipe(KMLMultiGeom, multigeometry) do scene
    Attributes()
end

function Makie.plot!(plot::KMLMultiGeom)
    mg = plot.multigeometry[]::FastKML.MultiGeometry
    geoms = mg.Geometries
    if !isnothing(geoms)
        for geom in geoms
            Makie.plot!(plot, geom)
        end
    end
    plot
end

# Register MultiGeometry to use the recipe
Makie.plottype(::FastKML.MultiGeometry) = KMLMultiGeom

# Handle arrays of KML geometries
function Makie.convert_arguments(P::Type{<:Scatter}, points::AbstractVector{<:FastKML.Point})
    coords = Point2f[]
    for p in points
        c = p.coordinates
        isnothing(c) || push!(coords, Point2f(c[1], c[2]))
    end
    return (coords,)
end

function Makie.convert_arguments(P::Type{<:Lines}, lines::AbstractVector{<:Union{FastKML.LineString, FastKML.LinearRing}})
    all_coords = Vector{Point2f}[]
    for line in lines
        coords = line.coordinates
        isnothing(coords) || push!(all_coords, [Point2f(c[1], c[2]) for c in coords])
    end
    return (all_coords,)
end

function Makie.convert_arguments(P::Type{<:Poly}, polys::AbstractVector{<:FastKML.Polygon})
    # One element type, which Poly accepts: a polygon without holes is a Polygon too
    all_polys = Makie.GeometryBasics.Polygon{2, Float32}[]
    for poly in polys
        outer = poly.outerBoundaryIs.coordinates
        isnothing(outer) && continue
        outer_points = [Point2f(c[1], c[2]) for c in outer]
        holes = _holes(poly)
        gb_poly = isnothing(holes) ? Makie.GeometryBasics.Polygon(outer_points) :
                  Makie.GeometryBasics.Polygon(outer_points, holes)
        push!(all_polys, gb_poly)
    end
    return (all_polys,)
end

end # module FastKMLMakieExt
