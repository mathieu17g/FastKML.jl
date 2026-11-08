# src/navigation.jl

module Navigation

export children

import ..Types
import ..Types: KMLFile, LazyKMLFile, KMLElement, Feature, Document, Folder, Placemark,
                Geometry, MultiGeometry, Point, LineString, LinearRing, Polygon,
                Overlay, GroundOverlay, ScreenOverlay, PhotoOverlay,
                NetworkLink, Style, StyleMap, StyleMapPair, SubStyle,
                ExtendedData, SchemaData, SimpleData,
                gx_Tour, gx_Playlist, gx_TourPrimitive,
                Update, AbstractUpdateOperation
import XML
# These methods extend `XML.children`, so that `using FastKML, XML` leaves one `children`.
import XML: children

# ─── KML Navigation Functions ────────────────────────────────────────────────

"""
    children(element)

Get the logical children of a KML element. These are methods of `XML.children`, which
gives the child nodes of an XML node: after `using FastKML, XML`, `children` works on both.
- For `KMLFile`: returns all children (KMLElements and XML nodes)
- For `Document`/`Folder`: returns the Features vector
- For `Placemark`: returns the Geometry (if present)
- For `MultiGeometry`: returns the Geometries vector
- For container types: returns the appropriate child collection
- For other KMLElements: returns meaningful child elements

# Examples
```julia
kml = read("file.kml", KMLFile)
doc = only(children(kml))      # Get the Document
features = children(doc)       # Get Features in the document
folder = features[1]           # Get a Folder
placemarks = children(folder)  # Get Placemarks in the folder
```
"""
function children(k::KMLFile)
    return k.children
end

function children(doc::Document)
    features = doc.Features
    return features === nothing ? Feature[] : features
end

function children(folder::Folder)
    features = folder.Features
    return features === nothing ? Feature[] : features
end

# For Placemark - return geometry and other significant elements
function children(placemark::Placemark)
    result = KMLElement[]
    # The geometry, then other child elements like ExtendedData, when present
    for child in (placemark.Geometry, placemark.ExtendedData, placemark.Region,
                  placemark.AbstractView, placemark.TimePrimitive)
        child === nothing || push!(result, child)
    end
    # Include style selectors if present
    selectors = placemark.StyleSelectors
    if selectors !== nothing && !isempty(selectors)
        append!(result, selectors)
    end
    return result
end

# For MultiGeometry
function children(mg::MultiGeometry)
    geometries = mg.Geometries
    return geometries === nothing ? Geometry[] : geometries
end

# For NetworkLink
function children(nl::NetworkLink)
    result = KMLElement[]
    for child in (nl.Link, nl.Region, nl.AbstractView)
        child === nothing || push!(result, child)
    end
    return result
end

# For Overlay types (GroundOverlay, ScreenOverlay, PhotoOverlay)
function children(overlay::Overlay)
    result = KMLElement[]
    for child in (overlay.Icon, overlay.Region)
        child === nothing || push!(result, child)
    end
    # GroundOverlay specific
    if overlay isa GroundOverlay
        for child in (overlay.LatLonBox, overlay.gx_LatLonQuad)
            child === nothing || push!(result, child)
        end
    end
    # ScreenOverlay specific
    if overlay isa ScreenOverlay
        for child in (overlay.overlayXY, overlay.screenXY, overlay.rotationXY, overlay.size)
            child === nothing || push!(result, child)
        end
    end
    # PhotoOverlay specific
    if overlay isa PhotoOverlay
        for child in (overlay.ViewVolume, overlay.ImagePyramid, overlay.Point)
            child === nothing || push!(result, child)
        end
    end
    return result
end

# For Style elements
function children(style::Style)
    result = SubStyle[]
    # Collect all substyles
    for substyle in (style.IconStyle, style.LabelStyle, style.LineStyle, style.PolyStyle,
                     style.BalloonStyle, style.ListStyle)
        substyle === nothing || push!(result, substyle)
    end
    return result
end

# For StyleMap
function children(stylemap::StyleMap)
    map_pairs = stylemap.Pairs
    return map_pairs === nothing ? StyleMapPair[] : map_pairs
end

# For ExtendedData
function children(ed::ExtendedData)
    data = ed.children
    return data === nothing ? KMLElement[] : data
end

# For SchemaData
function children(sd::SchemaData)
    simple_data = sd.SimpleDataVec
    return simple_data === nothing ? SimpleData[] : simple_data
end

# For Tour
function children(tour::gx_Tour)
    result = KMLElement[]
    # The playlist, then other potential children
    for child in (tour.gx_Playlist, tour.AbstractView)
        child === nothing || push!(result, child)
    end
    return result
end

# For Playlist
function children(playlist::gx_Playlist)
    return playlist.gx_TourPrimitives
end

# For Update
function children(update::Update)
    operations = update.operations
    return operations === nothing ? AbstractUpdateOperation[] : operations
end

# For Create/Delete/Change operations
function children(create::Types.Create)
    created = create.CreatedObjects
    return created === nothing ? KMLElement[] : created
end

function children(delete::Types.Delete)
    features = delete.FeaturesToDelete
    return features === nothing ? Feature[] : features
end

function children(change::Types.Change)
    objects = change.ObjectsToChange
    return objects === nothing ? Types.Object[] : objects
end

# For Model
function children(model::Types.Model)
    result = KMLElement[]
    for child in (model.Location, model.Orientation, model.Scale, model.Link, model.ResourceMap)
        child === nothing || push!(result, child)
    end
    return result
end

# For geometric primitives (Point, LineString, LinearRing, Polygon) - typically no children
function children(::Union{Point, LineString, LinearRing})
    return KMLElement[]
end

# For Polygon - could return boundaries as "children" for consistency
function children(poly::Polygon)
    result = KMLElement[]
    # outerBoundaryIs is a LinearRing, never `nothing`, not wrapped in a boundary element
    push!(result, poly.outerBoundaryIs)
    inner = poly.innerBoundaryIs
    inner === nothing || append!(result, inner)
    return result
end

# Generic fallback for other KMLElements
function children(element::KMLElement)
    # Collect all non-nothing KMLElement fields
    result = KMLElement[]
    for fname in fieldnames(typeof(element))
        val = getfield(element, fname)
        if val !== nothing
            if val isa KMLElement
                push!(result, val)
            elseif val isa Vector{<:KMLElement}
                append!(result, val)
            end
        end
    end
    return result
end

# Also handle LazyKMLFile
function children(lazy::LazyKMLFile)
    # Parse and return children
    kml = KMLFile(lazy)
    return children(kml)
end

# ─── Make KMLFile Iterable ──────────────────────────────────────────────────

# These need to be in the main KML module, not here, because they extend Base methods
# on the KMLFile type which is defined in Types module

end # module Navigation