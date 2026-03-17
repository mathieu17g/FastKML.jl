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

# ─── KML Navigation Functions ────────────────────────────────────────────────

"""
    children(element)

Get the logical children of a KML element.
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
    return doc.Features === nothing ? Feature[] : doc.Features
end

function children(folder::Folder)
    return folder.Features === nothing ? Feature[] : folder.Features
end

# For Placemark - return geometry and other significant elements
function children(placemark::Placemark)
    result = KMLElement[]
    if placemark.Geometry !== nothing
        push!(result, placemark.Geometry)
    end
    # Also include other child elements like ExtendedData if present
    if placemark.ExtendedData !== nothing
        push!(result, placemark.ExtendedData)
    end
    if placemark.Region !== nothing
        push!(result, placemark.Region)
    end
    if placemark.AbstractView !== nothing
        push!(result, placemark.AbstractView)
    end
    if placemark.TimePrimitive !== nothing
        push!(result, placemark.TimePrimitive)
    end
    # Include style selectors if present
    if placemark.StyleSelectors !== nothing && !isempty(placemark.StyleSelectors)
        append!(result, placemark.StyleSelectors)
    end
    return result
end

# For MultiGeometry
function children(mg::MultiGeometry)
    return mg.Geometries === nothing ? Geometry[] : mg.Geometries
end

# For NetworkLink
function children(nl::NetworkLink)
    result = KMLElement[]
    if nl.Link !== nothing
        push!(result, nl.Link)
    end
    if nl.Region !== nothing
        push!(result, nl.Region)
    end
    if nl.AbstractView !== nothing
        push!(result, nl.AbstractView)
    end
    return result
end

# For Overlay types (GroundOverlay, ScreenOverlay, PhotoOverlay)
function children(overlay::Overlay)
    result = KMLElement[]
    if overlay.Icon !== nothing
        push!(result, overlay.Icon)
    end
    if overlay.Region !== nothing
        push!(result, overlay.Region)
    end
    # GroundOverlay specific
    if overlay isa GroundOverlay
        if overlay.LatLonBox !== nothing
            push!(result, overlay.LatLonBox)
        end
        if overlay.gx_LatLonQuad !== nothing
            push!(result, overlay.gx_LatLonQuad)
        end
    end
    # ScreenOverlay specific
    if overlay isa ScreenOverlay
        if overlay.overlayXY !== nothing
            push!(result, overlay.overlayXY)
        end
        if overlay.screenXY !== nothing
            push!(result, overlay.screenXY)
        end
        if overlay.rotationXY !== nothing
            push!(result, overlay.rotationXY)
        end
        if overlay.size !== nothing
            push!(result, overlay.size)
        end
    end
    # PhotoOverlay specific
    if overlay isa PhotoOverlay
        if overlay.ViewVolume !== nothing
            push!(result, overlay.ViewVolume)
        end
        if overlay.ImagePyramid !== nothing
            push!(result, overlay.ImagePyramid)
        end
        if overlay.Point !== nothing
            push!(result, overlay.Point)
        end
    end
    return result
end

# For Style elements
function children(style::Style)
    result = SubStyle[]
    # Collect all substyles
    for field in (:IconStyle, :LabelStyle, :LineStyle, :PolyStyle, :BalloonStyle, :ListStyle)
        substyle = getfield(style, field)
        if substyle !== nothing
            push!(result, substyle)
        end
    end
    return result
end

# For StyleMap
function children(stylemap::StyleMap)
    return stylemap.Pairs === nothing ? StyleMapPair[] : stylemap.Pairs
end

# For ExtendedData
function children(ed::ExtendedData)
    return ed.children === nothing ? KMLElement[] : ed.children
end

# For SchemaData
function children(sd::SchemaData)
    return sd.SimpleDataVec === nothing ? SimpleData[] : sd.SimpleDataVec
end

# For Tour
function children(tour::gx_Tour)
    result = KMLElement[]
    if tour.gx_Playlist !== nothing
        push!(result, tour.gx_Playlist)
    end
    # Include other potential children
    if tour.AbstractView !== nothing
        push!(result, tour.AbstractView)
    end
    return result
end

# For Playlist
function children(playlist::gx_Playlist)
    return playlist.gx_TourPrimitives
end

# For Update
function children(update::Update)
    return update.operations === nothing ? AbstractUpdateOperation[] : update.operations
end

# For Create/Delete/Change operations
function children(create::Types.Create)
    return create.CreatedObjects === nothing ? KMLElement[] : create.CreatedObjects
end

function children(delete::Types.Delete)
    return delete.FeaturesToDelete === nothing ? Feature[] : delete.FeaturesToDelete
end

function children(change::Types.Change)
    return change.ObjectsToChange === nothing ? Types.Object[] : change.ObjectsToChange
end

# For Model
function children(model::Types.Model)
    result = KMLElement[]
    if model.Location !== nothing
        push!(result, model.Location)
    end
    if model.Orientation !== nothing
        push!(result, model.Orientation)
    end
    if model.Scale !== nothing
        push!(result, model.Scale)
    end
    if model.Link !== nothing
        push!(result, model.Link)
    end
    if model.ResourceMap !== nothing
        push!(result, model.ResourceMap)
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
    # Note: outerBoundaryIs is a LinearRing, not wrapped in a boundary element
    if poly.outerBoundaryIs !== nothing
        push!(result, poly.outerBoundaryIs)
    end
    if poly.innerBoundaryIs !== nothing
        append!(result, poly.innerBoundaryIs)
    end
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