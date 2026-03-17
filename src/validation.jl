module Validation

export validate_coordinates, validate_geometry, validate_document_structure

import ..Types: KMLElement, Geometry, Point, LineString, LinearRing, Polygon, MultiGeometry,
                Document, Folder, Feature, Placemark, Coord2, Coord3

# ─── Coordinate Validation ───────────────────────────────────────────────────
const MAX_ALTITUDE_METERS = 50_000 # 50km

"""
Validate coordinate bounds and format.
Returns (is_valid, error_message)
"""
function validate_coordinates(coords::Union{Coord2, Coord3})
    lon = coords[1]
    lat = coords[2]
    
    if abs(lon) > 180
        return false, "Longitude $lon is out of range [-180, 180]"
    end
    
    if abs(lat) > 90
        return false, "Latitude $lat is out of range [-90, 90]"
    end
    
    if length(coords) == 3
        alt = coords[3]
        # Altitude can technically be any value, but warn on extremes
        if abs(alt) > MAX_ALTITUDE_METERS  
            @warn "Altitude $alt meters seems extreme"
        end
    end
    
    return true, ""
end

function validate_coordinates(coords::Vector{<:Union{Coord2, Coord3}})
    for (i, coord) in enumerate(coords)
        is_valid, msg = validate_coordinates(coord)
        if !is_valid
            return false, "Coordinate $i: $msg"
        end
    end
    return true, ""
end

# ─── Geometry Validation ─────────────────────────────────────────────────────
"""
Validate geometry objects according to KML/OGC standards.
"""
function validate_geometry(geom::Point)
    if geom.coordinates === nothing
        return false, "Point has no coordinates"
    end
    return validate_coordinates(geom.coordinates)
end

function validate_geometry(geom::LineString)
    if geom.coordinates === nothing || isempty(geom.coordinates)
        return false, "LineString has no coordinates"
    end
    
    if length(geom.coordinates) < 2
        return false, "LineString must have at least 2 points"
    end
    
    return validate_coordinates(geom.coordinates)
end

function validate_geometry(geom::LinearRing)
    if geom.coordinates === nothing || isempty(geom.coordinates)
        return false, "LinearRing has no coordinates"
    end
    
    if length(geom.coordinates) < 4
        return false, "LinearRing must have at least 4 points"
    end
    
    # Check if ring is closed
    if geom.coordinates[1] != geom.coordinates[end]
        return false, "LinearRing is not closed (first point != last point)"
    end
    
    return validate_coordinates(geom.coordinates)
end

function validate_geometry(geom::Polygon)
    # Validate outer boundary
    if geom.outerBoundaryIs === nothing
        return false, "Polygon has no outer boundary"
    end
    
    is_valid, msg = validate_geometry(geom.outerBoundaryIs)
    if !is_valid
        return false, "Outer boundary: $msg"
    end
    
    # Validate inner boundaries if present
    if geom.innerBoundaryIs !== nothing
        for (i, ring) in enumerate(geom.innerBoundaryIs)
            is_valid, msg = validate_geometry(ring)
            if !is_valid
                return false, "Inner boundary $i: $msg"
            end
        end
    end
    
    return true, ""
end

function validate_geometry(geom::MultiGeometry)
    if geom.Geometries === nothing || isempty(geom.Geometries)
        return false, "MultiGeometry has no geometries"
    end
    
    for (i, g) in enumerate(geom.Geometries)
        is_valid, msg = validate_geometry(g)
        if !is_valid
            return false, "Geometry $i: $msg"
        end
    end
    
    return true, ""
end

function validate_geometry(geom::Geometry)
    # Fallback for other geometry types
    @warn "No specific validation for $(typeof(geom))"
    return true, ""
end

# ─── Document Structure Validation ───────────────────────────────────────────
"""
Validate document structure for common issues.
"""
function validate_document_structure(doc::Document)
    issues = String[]
    
    # Check for empty document
    if doc.Features === nothing || isempty(doc.Features)
        push!(issues, "Document has no features")
    end
    
    # Count feature types
    n_placemarks = 0
    n_folders = 0
    n_documents = 0
    
    if doc.Features !== nothing
        for feat in doc.Features
            if feat isa Placemark
                n_placemarks += 1
                # Validate placemark geometry
                if feat.Geometry !== nothing
                    is_valid, msg = validate_geometry(feat.Geometry)
                    if !is_valid
                        push!(issues, "Placemark '$(feat.name)': $msg")
                    end
                end
            elseif feat isa Folder
                n_folders += 1
            elseif feat isa Document
                n_documents += 1
                push!(issues, "Nested Document found - this is unusual")
            end
        end
    end
    
    # Report structure
    if isempty(issues)
        @info "Document structure valid" placemarks=n_placemarks folders=n_folders documents=n_documents
    end
    
    return isempty(issues), issues
end

function validate_document_structure(folder::Folder)
    issues = String[]
    
    if folder.Features === nothing || isempty(folder.Features)
        push!(issues, "Folder has no features")
    end
    
    # Similar validation as Document
    n_placemarks = 0
    if folder.Features !== nothing
        for feat in folder.Features
            if feat isa Placemark
                n_placemarks += 1
                if feat.Geometry !== nothing
                    is_valid, msg = validate_geometry(feat.Geometry)
                    if !is_valid
                        push!(issues, "Placemark '$(feat.name)': $msg")
                    end
                end
            end
        end
    end
    
    return isempty(issues), issues
end

# ─── Helper Functions ────────────────────────────────────────────────────────
"""
Check if a LinearRing is oriented counter-clockwise (for outer rings).
Uses the shoelace formula.
"""
function is_ccw(ring::LinearRing)
    coords = ring.coordinates
    if coords === nothing || length(coords) < 3
        return false
    end
    
    # Calculate signed area
    area = 0.0
    n = length(coords) - 1  # Exclude repeated last point
    
    for i in 1:n
        j = i % n + 1
        area += (coords[j][1] - coords[i][1]) * (coords[j][2] + coords[i][2])
    end
    
    return area < 0  # Negative area means CCW
end

"""
Validate that polygon rings have correct orientation:
- Outer rings should be CCW
- Inner rings should be CW
"""
function validate_polygon_orientation(poly::Polygon)
    issues = String[]
    
    # Check outer ring
    if poly.outerBoundaryIs !== nothing && poly.outerBoundaryIs.coordinates !== nothing
        if !is_ccw(poly.outerBoundaryIs)
            push!(issues, "Outer ring is not counter-clockwise")
        end
    end
    
    # Check inner rings
    if poly.innerBoundaryIs !== nothing
        for (i, ring) in enumerate(poly.innerBoundaryIs)
            if ring.coordinates !== nothing && is_ccw(ring)
                push!(issues, "Inner ring $i is not clockwise")
            end
        end
    end
    
    return isempty(issues), issues
end

end # module Validation