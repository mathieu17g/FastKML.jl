module Utils

export unwrap_single_part_multigeometry, find_placemarks, count_features, 
       get_bounds, merge_kml_files, extract_styles, extract_path, get_metadata,
       haversine_distance, path_length

using Base: sin, cos, atan, sqrt, deg2rad  # Import math functions we use
import ..Types: KMLFile, KMLElement, Feature, Container, Document, Folder, 
                Placemark, Geometry, MultiGeometry, Point, LineString, Polygon,
                Coord2, Coord3, StyleSelector

# ─── Geometry Utilities ──────────────────────────────────────────────────────
"""
    unwrap_single_part_multigeometry(geom::Geometry)

If a MultiGeometry contains only one geometry, return that geometry directly.
Otherwise return the MultiGeometry unchanged.
"""
function unwrap_single_part_multigeometry(geom::MultiGeometry)
    if geom.Geometries !== nothing && length(geom.Geometries) == 1
        return geom.Geometries[1]
    end
    return geom
end

unwrap_single_part_multigeometry(geom::Geometry) = geom
unwrap_single_part_multigeometry(::Nothing) = nothing
unwrap_single_part_multigeometry(::Missing) = missing

# ─── Feature Finding Utilities ───────────────────────────────────────────────
"""
    find_placemarks(container; name_pattern=nothing, has_geometry=nothing)

Find all placemarks in a container matching the given criteria.
"""
function find_placemarks(container::Union{Document, Folder, KMLFile}; 
                        name_pattern::Union{Nothing, Regex, String}=nothing,
                        has_geometry::Union{Nothing, Bool}=nothing)
    placemarks = Placemark[]
    
    features = if container isa KMLFile
        Feature[f for f in container.children if f isa Feature]
    else
        container.Features === nothing ? Feature[] : container.Features
    end
    
    for feat in features
        if feat isa Placemark
            # Check criteria
            matches = true
            
            if name_pattern !== nothing
                name = feat.name === nothing ? "" : feat.name
                if name_pattern isa Regex
                    matches &= occursin(name_pattern, name)
                else
                    matches &= occursin(string(name_pattern), name)
                end
            end
            
            if has_geometry !== nothing
                matches &= (feat.Geometry !== nothing) == has_geometry
            end
            
            if matches
                push!(placemarks, feat)
            end
        elseif feat isa Container
            # Recursive search
            append!(placemarks, find_placemarks(feat; 
                                              name_pattern=name_pattern, 
                                              has_geometry=has_geometry))
        end
    end
    
    return placemarks
end

# ─── Feature Counting ────────────────────────────────────────────────────────
"""
    count_features(container) -> Dict{Symbol, Int}

Count features by type in a container.
"""
function count_features(container::Union{Document, Folder, KMLFile})
    counts = Dict{Symbol, Int}(
        :Placemark => 0,
        :Document => 0,
        :Folder => 0,
        :NetworkLink => 0,
        :GroundOverlay => 0,
        :ScreenOverlay => 0,
        :PhotoOverlay => 0,
        :Tour => 0
    )
    
    features = if container isa KMLFile
        Feature[f for f in container.children if f isa Feature]
    else
        container.Features === nothing ? Feature[] : container.Features
    end
    
    for feat in features
        feat_type = Symbol(typeof(feat).name.name)
        if haskey(counts, feat_type)
            counts[feat_type] += 1
        end
        
        # Recursive count for containers
        if feat isa Container
            sub_counts = count_features(feat)
            for (k, v) in sub_counts
                counts[k] += v
            end
        end
    end
    
    return counts
end

# ─── Bounds Calculation ──────────────────────────────────────────────────────
"""
    get_bounds(geom::Geometry) -> (min_lon, min_lat, max_lon, max_lat)

Calculate the bounding box of a geometry.
"""
function get_bounds(geom::Point)
    if geom.coordinates === nothing
        return nothing
    end
    c = geom.coordinates
    return (c[1], c[2], c[1], c[2])
end

function get_bounds(geom::Union{LineString, Polygon})
    coords = if geom isa LineString
        geom.coordinates
    else  # Polygon
        geom.outerBoundaryIs === nothing ? nothing : geom.outerBoundaryIs.coordinates
    end
    
    if coords === nothing || isempty(coords)
        return nothing
    end
    
    min_lon = min_lat = Inf
    max_lon = max_lat = -Inf
    
    for c in coords
        min_lon = min(min_lon, c[1])
        max_lon = max(max_lon, c[1])
        min_lat = min(min_lat, c[2])
        max_lat = max(max_lat, c[2])
    end
    
    return (min_lon, min_lat, max_lon, max_lat)
end

function get_bounds(geom::MultiGeometry)
    if geom.Geometries === nothing || isempty(geom.Geometries)
        return nothing
    end
    
    min_lon = min_lat = Inf
    max_lon = max_lat = -Inf
    
    for g in geom.Geometries
        bounds = get_bounds(g)
        if bounds !== nothing
            min_lon = min(min_lon, bounds[1])
            min_lat = min(min_lat, bounds[2])
            max_lon = max(max_lon, bounds[3])
            max_lat = max(max_lat, bounds[4])
        end
    end
    
    if isinf(min_lon)
        return nothing
    end
    
    return (min_lon, min_lat, max_lon, max_lat)
end

function get_bounds(container::Union{Document, Folder, KMLFile})
    min_lon = min_lat = Inf
    max_lon = max_lat = -Inf
    
    placemarks = find_placemarks(container; has_geometry=true)
    
    for pm in placemarks
        if pm.Geometry !== nothing
            bounds = get_bounds(pm.Geometry)
            if bounds !== nothing
                min_lon = min(min_lon, bounds[1])
                min_lat = min(min_lat, bounds[2])
                max_lon = max(max_lon, bounds[3])
                max_lat = max(max_lat, bounds[4])
            end
        end
    end
    
    if isinf(min_lon)
        return nothing
    end
    
    return (min_lon, min_lat, max_lon, max_lat)
end

# ─── KML File Merging ────────────────────────────────────────────────────────
"""
    merge_kml_files(files...; name="Merged Document") -> KMLFile

Merge multiple KML files into a single file with a Document container.
"""
function merge_kml_files(files::KMLFile...; name::String="Merged Document")
    all_features = Feature[]
    
    for file in files
        for child in file.children
            if child isa Feature
                push!(all_features, child)
            elseif child isa Document || child isa Folder
                if child.Features !== nothing
                    append!(all_features, child.Features)
                end
            end
        end
    end
    
    merged_doc = Document(
        name = name,
        Features = all_features
    )
    
    return KMLFile(merged_doc)
end

# ─── Style Utilities ─────────────────────────────────────────────────────────
"""
    extract_styles(container) -> Vector{StyleSelector}

Extract all style definitions from a container.
"""
function extract_styles(container::Union{Document, KMLFile})
    styles = StyleSelector[]
    
    if container isa Document && container.StyleSelectors !== nothing
        append!(styles, container.StyleSelectors)
    elseif container isa KMLFile
        for child in container.children
            if child isa StyleSelector
                push!(styles, child)
            elseif child isa Document && child.StyleSelectors !== nothing
                append!(styles, child.StyleSelectors)
            end
        end
    end
    
    return styles
end

# ─── Path Utilities ──────────────────────────────────────────────────────────
"""
    extract_path(linestring::LineString) -> Vector{Tuple{Float64, Float64}}

Extract a path as (lon, lat) tuples from a LineString.
"""
function extract_path(ls::LineString)
    if ls.coordinates === nothing
        return Tuple{Float64, Float64}[]
    end
    
    return [(c[1], c[2]) for c in ls.coordinates]
end

# ─── Metadata Utilities ──────────────────────────────────────────────────────
"""
    get_metadata(placemark::Placemark) -> Dict{Symbol, Any}

Extract metadata from a placemark as a dictionary.
"""
function get_metadata(pm::Placemark)
    metadata = Dict{Symbol, Any}()
    
    # Basic properties
    metadata[:name] = pm.name
    metadata[:description] = pm.description
    metadata[:visibility] = pm.visibility
    metadata[:styleUrl] = pm.styleUrl
    
    # Geometry type
    if pm.Geometry !== nothing
        metadata[:geometry_type] = string(typeof(pm.Geometry).name.name)
    end
    
    # Extended data if present
    if pm.ExtendedData !== nothing && pm.ExtendedData.children !== nothing
        extended = Dict{String, Any}()
        for child in pm.ExtendedData.children
            if hasproperty(child, :name) && hasproperty(child, :value)
                extended[child.name] = child.value
            end
        end
        if !isempty(extended)
            metadata[:extended_data] = extended
        end
    end
    
    # Remove nothing values
    filter!(p -> p.second !== nothing, metadata)
    
    return metadata
end

# ─── Distance Utilities ──────────────────────────────────────────────────────
"""
    haversine_distance(coord1, coord2) -> Float64

Calculate the great circle distance between two coordinates in meters.
Uses the haversine formula.
"""
function haversine_distance(coord1::Union{Coord2, Coord3}, coord2::Union{Coord2, Coord3})
    # Earth's radius in meters
    R = 6371000.0
    
    # Convert to radians
    lat1 = deg2rad(coord1[2])
    lat2 = deg2rad(coord2[2])
    Δlat = lat2 - lat1
    Δlon = deg2rad(coord2[1] - coord1[1])
    
    # Haversine formula
    a = sin(Δlat/2)^2 + cos(lat1) * cos(lat2) * sin(Δlon/2)^2
    c = 2 * atan(sqrt(a), sqrt(1-a))
    
    return R * c
end

"""
    path_length(linestring::LineString) -> Float64

Calculate the total length of a LineString path in meters.
"""
function path_length(ls::LineString)
    if ls.coordinates === nothing || length(ls.coordinates) < 2
        return 0.0
    end
    
    total_length = 0.0
    for i in 2:length(ls.coordinates)
        total_length += haversine_distance(ls.coordinates[i-1], ls.coordinates[i])
    end
    
    return total_length
end

end # module Utils