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

# Polygon plotting with proper hole support using GeometryBasics
function Makie.convert_arguments(P::Type{<:Poly}, poly::FastKML.Polygon)
    outer = poly.outerBoundaryIs
    if isnothing(outer) || isnothing(outer.coordinates)
        return ([Point2f(NaN, NaN)],)
    end
    
    # Convert outer boundary
    outer_points = [Point2f(c[1], c[2]) for c in outer.coordinates]
    
    # Check if we have holes
    if !isnothing(poly.innerBoundaryIs) && !isempty(poly.innerBoundaryIs)
        # Convert holes
        holes = [Point2f.([(c[1], c[2]) for c in ring.coordinates]) 
                 for ring in poly.innerBoundaryIs 
                 if !isnothing(ring.coordinates)]
        
        # Create a GeometryBasics Polygon with holes
        # GeometryBasics is a dependency of Makie, so this should work
        gb_poly = Makie.GeometryBasics.Polygon(outer_points, holes)
        return (gb_poly,)
    else
        # No holes, just return the points
        return (outer_points,)
    end
end

# Recipe for MultiGeometry
@recipe(KMLMultiGeom, multigeometry) do scene
    Attributes()
end

function Makie.plot!(plot::KMLMultiGeom)
    mg = plot.multigeometry[]
    if !isnothing(mg.Geometries)
        for geom in mg.Geometries
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
        if !isnothing(p.coordinates)
            push!(coords, Point2f(p.coordinates[1], p.coordinates[2]))
        end
    end
    return (coords,)
end

function Makie.convert_arguments(P::Type{<:Lines}, lines::AbstractVector{<:Union{FastKML.LineString, FastKML.LinearRing}})
    all_coords = Vector{Point2f}[]
    for line in lines
        if !isnothing(line.coordinates)
            push!(all_coords, [Point2f(c[1], c[2]) for c in line.coordinates])
        end
    end
    return (all_coords,)
end

function Makie.convert_arguments(P::Type{<:Poly}, polys::AbstractVector{<:FastKML.Polygon})
    all_polys = []
    for poly in polys
        if !isnothing(poly.outerBoundaryIs) && !isnothing(poly.outerBoundaryIs.coordinates)
            outer_points = [Point2f(c[1], c[2]) for c in poly.outerBoundaryIs.coordinates]
            
            if !isnothing(poly.innerBoundaryIs) && !isempty(poly.innerBoundaryIs)
                holes = [Point2f.([(c[1], c[2]) for c in ring.coordinates]) 
                         for ring in poly.innerBoundaryIs 
                         if !isnothing(ring.coordinates)]
                gb_poly = Makie.GeometryBasics.Polygon(outer_points, holes)
                push!(all_polys, gb_poly)
            else
                push!(all_polys, outer_points)
            end
        end
    end
    return (all_polys,)
end

end # module FastKMLMakieExt