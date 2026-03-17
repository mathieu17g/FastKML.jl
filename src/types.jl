module Types

export KMLElement, NoAttributes, Object, Feature, Overlay, Container, Geometry,
       StyleSelector, TimePrimitive, AbstractView, SubStyle, ColorStyle,
       gx_TourPrimitive, AbstractUpdateOperation, KMLFile, LazyKMLFile,
       # Coordinate types
       Coord2, Coord3,
       # Time types
       TimeStamp, TimeSpan,
       # Component types
       Link, Icon, Orientation, Location, Scale, Lod, LatLonBox, LatLonAltBox,
       Region, gx_LatLonQuad, hotSpot, overlayXY, screenXY, rotationXY, size,
       ItemIcon, ViewVolume, ImagePyramid, Snippet, Data, SimpleData, SchemaData,
       ExtendedData, Alias, ResourceMap, SimpleField, Schema, AtomAuthor, AtomLink,
       # Style types
       LineStyle, PolyStyle, IconStyle, LabelStyle, ListStyle, BalloonStyle,
       Style, StyleMapPair, StyleMap,
       # View types
       Camera, LookAt,
       # Geometry types
       Point, LineString, LinearRing, Polygon, MultiGeometry, Model, gx_Track, gx_MultiTrack,
       # Feature types
       Placemark, NetworkLink, Document, Folder, GroundOverlay, ScreenOverlay,
       PhotoOverlay, gx_Tour, gx_Playlist, gx_AnimatedUpdate, gx_FlyTo,
       gx_SoundCue, gx_TourControl, gx_Wait, Update, Create, Delete, Change,
       # Utilities
       TAG_TO_TYPE, typemap, all_concrete_subtypes

using OrderedCollections: OrderedDict
using StaticArrays
using TimeZones, Dates
using InteractiveUtils: subtypes
import XML
import ..Enums

# Coordinate type aliases
const Coord2 = SVector{2,Float64}
const Coord3 = SVector{3,Float64}

# ─── Base infrastructure ─────────────────────────────────────────────────────
const TAG_TO_TYPE = Dict{Symbol,DataType}()

macro def(name, definition)
    quote
        macro $(esc(name))()
            esc($(Expr(:quote, definition)))
        end
    end
end

macro option(ex)
    ex.head == :(::) || error("@option must annotate a field, e.g. f::T")
    ex.args[2] = Expr(:curly, :Union, :Nothing, ex.args[2])
    :($(esc(ex)) = nothing)
end

macro required(ex)
    ex.head == :(::) || error("@required must annotate a field, e.g. f::T")
    ex.args[2] = Expr(:curly, :Union, :Nothing, ex.args[2])
    :($(esc(ex)) = (@warn "Required field :$(ex.args[1]) initialised as nothing"; nothing))
end

# ─── KMLElement base type ────────────────────────────────────────────────────
abstract type KMLElement{attr_names} <: XML.AbstractXMLNode end
const NoAttributes = KMLElement{()}

# ─── Abstract type hierarchy ─────────────────────────────────────────────────
abstract type Object <: KMLElement{(:id, :targetId)} end
abstract type Feature <: Object end
abstract type Overlay <: Feature end
abstract type Container <: Feature end
abstract type Geometry <: Object end
abstract type StyleSelector <: Object end
abstract type TimePrimitive <: Object end
abstract type AbstractView <: Object end
abstract type SubStyle <: Object end
abstract type ColorStyle <: SubStyle end
abstract type gx_TourPrimitive <: Object end
abstract type AbstractUpdateOperation <: Object end

# ─── Helper utilities ────────────────────────────────────────────────────────
Base.:(==)(a::T, b::T) where {T<:KMLElement} = all(getfield(a, f) == getfield(b, f) for f in fieldnames(T))

# XML interface
XML.tag(o::KMLElement) = replace(string(typeof(o)), r"([a-zA-Z]*\.)" => "", "_" => ":")
function XML.attributes(o::T) where {names,T<:KMLElement{names}}
    OrderedDict(string(k) => string(getfield(o, k)) for k in names if !isnothing(getfield(o, k)))
end

# ─── Common field macros ─────────────────────────────────────────────────────
@def object begin
    @option id ::String
    @option targetId ::String
end

@def altitude_mode_elements begin
    altitudeMode::Union{Nothing,Enums.altitudeMode} = nothing
    gx_altitudeMode::Union{Nothing,Enums.gx_altitudeMode} = nothing
end

@def feature begin
    @object
    @option name ::String
    @option visibility ::Bool
    @option open ::Bool
    @option atom_author ::AtomAuthor
    @option atom_link ::AtomLink
    @option address ::String
    @option xal_AddressDetails::String
    @option phoneNumber ::String
    @option Snippet ::Snippet
    @option description ::String
    @option AbstractView ::AbstractView
    @option TimePrimitive ::TimePrimitive
    @option styleUrl ::String
    @option StyleSelectors ::Vector{StyleSelector}
    @option Region ::Region
    @option ExtendedData ::ExtendedData
    @altitude_mode_elements
    @option gx_balloonVisibility ::Bool
end

@def colorstyle begin
    @object
    @option color ::String
    @option colorMode ::Enums.colorMode
end

@def overlay begin
    @feature
    @option color ::String
    @option drawOrder::Int
    @option Icon ::Icon
end

# ─── Container types ─────────────────────────────────────────────────────────
mutable struct KMLFile
    children::Vector{Union{XML.AbstractXMLNode,KMLElement}}
end
KMLFile(content::KMLElement...) = KMLFile(collect(content))
Base.push!(k::KMLFile, x::Union{XML.AbstractXMLNode,KMLElement}) = push!(k.children, x)
Base.:(==)(a::KMLFile, b::KMLFile) = all(getfield(a, f) == getfield(b, f) for f in fieldnames(KMLFile))

function Base.show(io::IO, k::KMLFile)
    print(io, "KMLFile ")
    if get(io, :color, false)
        printstyled(io, '(', Base.format_bytes(Base.summarysize(k)), ')'; color = :light_black)
    else
        print(io, '(', Base.format_bytes(Base.summarysize(k)), ')')
    end
end

mutable struct LazyKMLFile
    root_node::XML.AbstractXMLNode
    _layer_cache::Dict{String,Any}
    _layer_info_cache::Union{Nothing,Vector{Tuple{Int,String,Any}}}
    _lock::ReentrantLock
    
    LazyKMLFile(root_node::XML.AbstractXMLNode) = new(root_node, Dict{String,Any}(), nothing, ReentrantLock())
end

Base.:(==)(a::LazyKMLFile, b::LazyKMLFile) = a.root_node == b.root_node
Base.convert(::Type{KMLFile}, lazy::LazyKMLFile) = KMLFile(lazy)

function Base.show(io::IO, k::LazyKMLFile)
    print(io, "LazyKMLFile ")
    if get(io, :color, false)
        printstyled(io, "(lazy, ", Base.format_bytes(Base.summarysize(k.root_node)), ')'; color = :light_black)
    else
        print(io, "(lazy, ", Base.format_bytes(Base.summarysize(k.root_node)), ')')
    end
end

# ─── Time types ──────────────────────────────────────────────────────────────
Base.@kwdef mutable struct TimeStamp <: TimePrimitive
    @object
    @option when ::Union{TimeZones.ZonedDateTime,Dates.Date,String}
end

Base.@kwdef mutable struct TimeSpan <: TimePrimitive
    @object
    @option begin_ ::Union{TimeZones.ZonedDateTime,Dates.Date,String}
    @option end_ ::Union{TimeZones.ZonedDateTime,Dates.Date,String}
end

# ─── Component types ─────────────────────────────────────────────────────────
Base.@kwdef mutable struct hotSpot <: KMLElement{(:x, :y, :xunits, :yunits)}
    @option x ::Float64
    @option y ::Float64
    @option xunits ::Enums.units
    @option yunits ::Enums.units
end

const overlayXY = hotSpot
const screenXY = hotSpot
const rotationXY = hotSpot
const size = hotSpot

Base.@kwdef mutable struct Link <: Object
    @object
    @option href ::String
    @option refreshMode ::Enums.refreshMode
    @option refreshInterval ::Float64
    @option viewRefreshMode ::Enums.viewRefreshMode
    @option viewRefreshTime ::Float64
    @option viewBoundScale ::Float64
    @option viewFormat ::String
    @option httpQuery ::String
end

Base.@kwdef mutable struct Icon <: Object
    @object
    @option href ::String
    @option refreshMode ::Enums.refreshMode
    @option refreshInterval::Float64
    @option viewRefreshMode::Enums.viewRefreshMode
    @option viewRefreshTime::Float64
    @option viewBoundScale ::Float64
    @option viewFormat ::String
    @option httpQuery ::String
    @option x ::Int
    @option y ::Int
    @option w ::Int
    @option h ::Int
end

Base.@kwdef mutable struct Orientation <: Object
    @object
    @option heading::Float64
    @option tilt ::Float64
    @option roll ::Float64
end

Base.@kwdef mutable struct Location <: Object
    @object
    @option longitude::Float64
    @option latitude ::Float64
    @option altitude ::Float64
end

Base.@kwdef mutable struct Scale <: Object
    @object
    @option x::Float64
    @option y::Float64
    @option z::Float64
end

Base.@kwdef mutable struct Lod <: Object
    @object
    minLodPixels::Int = 0  # Changed from 128 to match KML spec default
    @option maxLodPixels ::Int
    @option minFadeExtent ::Int
    @option maxFadeExtent ::Int
end

Base.@kwdef mutable struct LatLonBox <: Object
    @object
    north::Float64 = 0
    south::Float64 = 0
    east::Float64 = 0
    west::Float64 = 0
    @option rotation::Float64
end

Base.@kwdef mutable struct LatLonAltBox <: Object
    @object
    north::Float64 = 0
    south::Float64 = 0
    east::Float64 = 0
    west::Float64 = 0
    @option minAltitude::Float64
    @option maxAltitude::Float64
    @altitude_mode_elements
end

Base.@kwdef mutable struct Region <: Object
    @object
    LatLonAltBox::LatLonAltBox = LatLonAltBox()
    @option Lod::Lod
end

Base.@kwdef mutable struct gx_LatLonQuad <: Object
    @object
    coordinates::SVector{4, Coord2} = SVector{4}(fill(SVector(0.0, 0.0), 4))
    
    # Custom constructor for validation when creating from Vector
    function gx_LatLonQuad(id, targetId, c::Vector{Coord2})
        @assert length(c) == 4 "gx:LatLonQuad requires exactly 4 coordinates"
        new(id, targetId, SVector{4}(c))
    end
    
    # Constructor for SVector input
    gx_LatLonQuad(id, targetId, c::SVector{4, Coord2}) = new(id, targetId, c)
end

Base.@kwdef mutable struct ItemIcon <: NoAttributes
    @option state::Enums.itemIconState
    @option href ::String
end

Base.@kwdef mutable struct ViewVolume <: NoAttributes
    @option leftFov ::Float64
    @option rightFov ::Float64
    @option bottomFov ::Float64
    @option topFov ::Float64
    @option near ::Float64
end

Base.@kwdef mutable struct ImagePyramid <: NoAttributes
    @option tileSize ::Int
    @option maxWidth ::Int
    @option maxHeight ::Int
    @option gridOrigin::Enums.gridOrigin
end

Base.@kwdef mutable struct Snippet <: KMLElement{(:maxLines,)}
    content::String = ""
    maxLines::Int = 2
end

Base.@kwdef mutable struct Data <: KMLElement{(:name,)}
    @option name::String
    @option value ::String
    @option displayName ::String
end

Base.@kwdef mutable struct SimpleData <: KMLElement{(:name,)}
    name::String = ""
    content::String = ""
end

Base.@kwdef mutable struct SchemaData <: KMLElement{(:schemaUrl,)}
    @option schemaUrl::String
    @option SimpleDataVec ::Vector{SimpleData}
end

Base.@kwdef mutable struct ExtendedData <: NoAttributes
    @option children ::Vector{Union{Data,SchemaData,KMLElement}}
end

Base.@kwdef mutable struct Alias <: NoAttributes
    @option targetHref::String
    @option sourceHref::String
end

Base.@kwdef mutable struct ResourceMap <: NoAttributes
    @option Aliases::Vector{Alias}
end

Base.@kwdef mutable struct SimpleField <: KMLElement{(:type, :name)}
    type::String
    name::String
    @option displayName::String
end

Base.@kwdef mutable struct Schema <: KMLElement{(:id,)}
    id::String
    @option SimpleFields::Vector{SimpleField}
end

Base.@kwdef mutable struct AtomAuthor <: KMLElement{()}
    @option name::String
    @option uri::String
    @option email::String
end

Base.@kwdef mutable struct AtomLink <: KMLElement{(:href, :rel, :type, :hreflang, :title, :length)}
    @option href::String
    @option rel::String
    @option type::String
    @option hreflang::String
    @option title::String
    @option length::Int
end

# ─── Style types ─────────────────────────────────────────────────────────────
Base.@kwdef mutable struct LineStyle <: ColorStyle
    @colorstyle
    @option width ::Float64
    @option gx_outerColor ::String
    @option gx_outerWidth ::Float64
    @option gx_physicalWidth::Float64
    @option gx_labelVisibility::Bool
end

Base.@kwdef mutable struct PolyStyle <: ColorStyle
    @colorstyle
    @option fill ::Bool
    @option outline::Bool
end

Base.@kwdef mutable struct IconStyle <: ColorStyle
    @colorstyle
    @option scale ::Float64
    @option heading ::Float64
    @option Icon ::Icon
    @option hotSpot ::hotSpot
end

Base.@kwdef mutable struct LabelStyle <: ColorStyle
    @colorstyle
    @option scale::Float64
end

Base.@kwdef mutable struct ListStyle <: SubStyle
    @object
    @option listItemType::Symbol
    @option bgColor ::String
    @option ItemIcons ::Vector{ItemIcon}
end

Base.@kwdef mutable struct BalloonStyle <: SubStyle
    @object
    @option bgColor ::String
    @option textColor ::String
    @option text ::String
    @option displayMode::Enums.displayMode
end

Base.@kwdef mutable struct Style <: StyleSelector
    @object
    @option IconStyle ::IconStyle
    @option LabelStyle ::LabelStyle
    @option LineStyle ::LineStyle
    @option PolyStyle ::PolyStyle
    @option BalloonStyle::BalloonStyle
    @option ListStyle ::ListStyle
end

Base.@kwdef mutable struct StyleMapPair <: Object
    @object
    @option key ::Enums.styleState
    @option styleUrl::String
    @option Style ::Style
end

Base.@kwdef mutable struct StyleMap <: StyleSelector
    @object
    @option Pairs::Vector{StyleMapPair}
end

# ─── View types ──────────────────────────────────────────────────────────────
Base.@kwdef mutable struct Camera <: AbstractView
    @object
    @option TimePrimitive ::TimePrimitive
    @option longitude ::Float64
    @option latitude ::Float64
    @option altitude ::Float64
    @option heading ::Float64
    @option tilt ::Float64
    @option roll ::Float64
    @altitude_mode_elements
end

Base.@kwdef mutable struct LookAt <: AbstractView
    @object
    @option TimePrimitive ::TimePrimitive
    @option longitude ::Float64
    @option latitude ::Float64
    @option altitude ::Float64
    @option heading ::Float64
    @option tilt ::Float64
    @option range ::Float64
    @altitude_mode_elements
end

# ─── Geometry types ──────────────────────────────────────────────────────────
Base.@kwdef mutable struct Point <: Geometry
    @object
    @option extrude::Bool
    @altitude_mode_elements
    @option coordinates::Union{Coord2,Coord3}
end

Base.@kwdef mutable struct LineString <: Geometry
    @object
    @option gx_altitudeOffset::Float64
    @option extrude::Bool
    @option tessellate::Bool
    @altitude_mode_elements
    @option gx_drawOrder::Int
    @option coordinates::Union{Vector{Coord2},Vector{Coord3}}
end

Base.@kwdef mutable struct LinearRing <: Geometry
    @object
    @option gx_altitudeOffset::Float64
    @option extrude::Bool
    @option tessellate::Bool
    @altitude_mode_elements
    @option coordinates::Union{Vector{Coord2},Vector{Coord3}}
end

Base.@kwdef mutable struct Polygon <: Geometry
    @object
    @option extrude::Bool
    @option tessellate::Bool
    @altitude_mode_elements
    outerBoundaryIs::LinearRing = LinearRing()
    @option innerBoundaryIs::Vector{LinearRing}
end

Base.@kwdef mutable struct MultiGeometry <: Geometry
    @object
    @option Geometries::Vector{Geometry}
end

Base.@kwdef mutable struct Model <: Geometry
    @object
    @altitude_mode_elements
    @option Location ::Location
    @option Orientation ::Orientation
    @option Scale ::Scale
    @option Link ::Link
    @option ResourceMap ::ResourceMap
end

Base.@kwdef mutable struct gx_Track <: Geometry
    @object
    @altitude_mode_elements
    @option when ::Vector{Union{TimeZones.ZonedDateTime,Dates.Date,String}}
    @option gx_coord ::Union{Vector{Coord2},Vector{Coord3}}
    @option gx_angles ::String
    @option Model ::Model
    @option ExtendedData::ExtendedData
    @option Icon ::Icon
end

Base.@kwdef mutable struct gx_MultiTrack <: Geometry
    @object
    @option gx_interpolate::Bool
    @option gx_Track ::Vector{gx_Track}
end

# ─── Feature types ───────────────────────────────────────────────────────────
Base.@kwdef mutable struct Placemark <: Feature
    @feature
    @option Geometry ::Geometry
end

Base.@kwdef mutable struct NetworkLink <: Feature
    @feature
    @option refreshVisibility::Bool
    @option flyToView ::Bool
    Link::Link = Link()
end

Base.@kwdef mutable struct Folder <: Container
    @feature
    @option Features::Vector{Feature}
end

Base.@kwdef mutable struct Document <: Container
    @feature
    @option Schemas ::Vector{Schema}
    @option Features::Vector{Feature}
end

Base.@kwdef mutable struct GroundOverlay <: Overlay
    @overlay
    @option altitude ::Float64
    @option LatLonBox ::LatLonBox
    @option gx_LatLonQuad ::gx_LatLonQuad
end

Base.@kwdef mutable struct ScreenOverlay <: Overlay
    @overlay
    @option overlayXY ::overlayXY
    @option screenXY ::screenXY
    @option rotationXY ::rotationXY
    @option size ::size
    rotation::Float64 = 0.0
end

Base.@kwdef mutable struct PhotoOverlay <: Overlay
    @overlay
    @option rotation ::Float64
    @option ViewVolume ::ViewVolume
    @option ImagePyramid ::ImagePyramid
    @option Point ::Point
    @option shape ::Enums.shape
end

Base.@kwdef mutable struct Create <: AbstractUpdateOperation
    @object
    @option CreatedObjects::Vector{KMLElement}
end

Base.@kwdef mutable struct Delete <: AbstractUpdateOperation
    @object
    @option FeaturesToDelete::Vector{Feature}
end

Base.@kwdef mutable struct Change <: AbstractUpdateOperation
    @object
    @option ObjectsToChange::Vector{Object}
end

Base.@kwdef mutable struct Update <: KMLElement{()}
    @option targetHref ::String
    @option operations ::Vector{Union{Create,Delete,Change}}
end

Base.@kwdef mutable struct gx_AnimatedUpdate <: gx_TourPrimitive
    @object
    @option gx_duration ::Float64
    @option Update ::Update
    @option gx_delayedStart ::Float64
end

Base.@kwdef mutable struct gx_FlyTo <: gx_TourPrimitive
    @object
    @option gx_duration ::Float64
    @option gx_flyToMode ::Enums.flyToMode
    @option AbstractView ::AbstractView
end

Base.@kwdef mutable struct gx_SoundCue <: gx_TourPrimitive
    @object
    @option href ::String
    @option gx_delayedStart::Float64
end

Base.@kwdef mutable struct gx_TourControl <: gx_TourPrimitive
    @object
    @option gx_playMode::String  # Made optional - no default per KML spec
end

Base.@kwdef mutable struct gx_Wait <: gx_TourPrimitive
    @object
    @option gx_duration::Float64
end

Base.@kwdef mutable struct gx_Playlist <: Object
    @object
    gx_TourPrimitives::Vector{gx_TourPrimitive} = []
end

Base.@kwdef mutable struct gx_Tour <: Feature
    @feature
    @option gx_Playlist ::gx_Playlist
end

# ─── Populate TAG_TO_TYPE ────────────────────────────────────────────────────
function _populate_tag_to_type()
    # Auto-populate from concrete subtypes
    for S in all_concrete_subtypes(KMLElement)
        TAG_TO_TYPE[Symbol(replace(string(S), r".*\." => ""))] = S
    end
    
    # Manual mappings
    TAG_TO_TYPE[:kml] = KMLFile
    TAG_TO_TYPE[:Placemark] = Placemark
    TAG_TO_TYPE[:Point] = Point
    TAG_TO_TYPE[:Polygon] = Polygon
    TAG_TO_TYPE[:LineString] = LineString
    TAG_TO_TYPE[:LinearRing] = LinearRing
    TAG_TO_TYPE[:Style] = Style
    TAG_TO_TYPE[:Document] = Document
    TAG_TO_TYPE[:Folder] = Folder
    TAG_TO_TYPE[:overlayXY] = hotSpot
    TAG_TO_TYPE[:screenXY] = hotSpot
    TAG_TO_TYPE[:rotationXY] = hotSpot
    TAG_TO_TYPE[:size] = hotSpot
    TAG_TO_TYPE[:snippet] = Snippet
    TAG_TO_TYPE[:Url] = Link
    TAG_TO_TYPE[:Pair] = StyleMapPair
    TAG_TO_TYPE[:TimeStamp] = TimeStamp
    TAG_TO_TYPE[:TimeSpan] = TimeSpan
    TAG_TO_TYPE[:Data] = Data
    TAG_TO_TYPE[:SimpleData] = SimpleData
    TAG_TO_TYPE[:SchemaData] = SchemaData
    TAG_TO_TYPE[:atom_author] = AtomAuthor
    TAG_TO_TYPE[:atom_link] = AtomLink
    TAG_TO_TYPE[:Create] = Create
    TAG_TO_TYPE[:Delete] = Delete
    TAG_TO_TYPE[:Change] = Change
    TAG_TO_TYPE[:Update] = Update
end

# Helper functions
function all_concrete_subtypes(T)
    out = DataType[]
    for S in subtypes(T)
        isabstracttype(S) ? append!(out, all_concrete_subtypes(S)) : push!(out, S)
    end
    out
end

# Show method for KMLElement
function Base.show(io::IO, o::T) where {names,T<:KMLElement{names}}
    # Simple rule: only use color if NOT in a DataFrame
    in_dataframe = (get(io, :compact, false) && get(io, :limit, false)) ||
                   (get(io, :typeinfo, nothing) === Vector{Any})
    use_color = !in_dataframe && get(io, :color, false)
    
    # Display type name
    if use_color
        printstyled(io, T; color = :light_cyan)
    else
        print(io, T)
    end
    
    # Display XML representation
    print(io, ": [")
    print(io, "<", XML.tag(o))
    attrs = XML.attributes(o)
    if !isempty(attrs)
        for (k, v) in attrs
            print(io, " ", k, "=\"", v, "\"")
        end
    end
    print(io, ">")
    print(io, "]")
end

# Initialize TAG_TO_TYPE
_populate_tag_to_type()

# ─── XML Tag to Symbol Conversion (Thread-Safe) ─────────────────────────────
# Pre-populated caches for thread safety and performance

function _create_tagsym_cache()
    cache = Dict{String,Symbol}()
    
    # Helper to add both underscore and colon versions
    function add_tag!(cache, str::String)
        # Always convert colons to underscores for the symbol
        sym = Symbol(replace(str, ":" => "_"))
        cache[str] = sym
        
        # If the string contains a colon, also add the underscore version
        if occursin(':', str)
            underscore_version = replace(str, ":" => "_")
            cache[underscore_version] = sym
        # If the string contains an underscore, also add the colon version
        elseif occursin('_', str)
            colon_version = replace(str, "_" => ":")
            cache[colon_version] = sym
        end
    end
    
    # 1. Add all known KML element tags
    kml_tags = [
        "kml", "Document", "Folder", "Placemark", "NetworkLink",
        "Point", "LineString", "LinearRing", "Polygon", "MultiGeometry",
        "Model", "gx_Track", "gx_MultiTrack",
        "Style", "StyleMap", "StyleMapPair", "LineStyle", "PolyStyle", 
        "IconStyle", "LabelStyle", "ListStyle", "BalloonStyle",
        "Camera", "LookAt", "GroundOverlay", "ScreenOverlay", "PhotoOverlay",
        "TimeStamp", "TimeSpan", "gx_Tour", "gx_Playlist", "gx_AnimatedUpdate",
        "gx_FlyTo", "gx_SoundCue", "gx_TourControl", "gx_Wait",
        "Update", "Create", "Delete", "Change",
        "Link", "Icon", "Orientation", "Location", "Scale", "Lod",
        "LatLonBox", "LatLonAltBox", "Region", "gx_LatLonQuad",
        "ItemIcon", "ViewVolume", "ImagePyramid", "Snippet",
        "Data", "SimpleData", "SchemaData", "ExtendedData",
        "Alias", "ResourceMap", "SimpleField", "Schema",
        "atom_author", "atom_link",
        # Special mappings from TAG_TO_TYPE
        "overlayXY", "screenXY", "rotationXY", "size", "hotSpot",
        "snippet", "Url", "Pair",
        # Structural tags
        "outerBoundaryIs", "innerBoundaryIs",
        # gx: prefixed versions
        "gx:Track", "gx:MultiTrack", "gx:Tour", "gx:Playlist",
        "gx:AnimatedUpdate", "gx:FlyTo", "gx:SoundCue", "gx:TourControl",
        "gx:Wait", "gx:LatLonQuad", "gx:altitudeMode", "gx:altitudeOffset",
        "gx:angles", "gx:balloonVisibility", "gx:coord", "gx:delayedStart",
        "gx:drawOrder", "gx:duration", "gx:flyToMode", "gx:interpolate",
        "gx:labelVisibility", "gx:outerColor", "gx:outerWidth", 
        "gx:physicalWidth", "gx:playMode"
    ]
    
    for tag in kml_tags
        add_tag!(cache, tag)
    end
    
    # 2. Add all field names from all KML types
    for T in all_concrete_subtypes(KMLElement)
        for field in fieldnames(T)
            field_str = string(field)
            cache[field_str] = field
            
            # Handle special underscore fields
            if endswith(field_str, "_")
                # For fields like "begin_" -> also map "begin"
                base_name = field_str[1:end-1]
                cache[base_name] = field
            end
        end
    end
    
    # 3. Add enum names from Enums module
    enum_names = [
        "altitudeMode", "gx_altitudeMode", "refreshMode", "viewRefreshMode",
        "shape", "gridOrigin", "displayMode", "listItemType", "units",
        "itemIconState", "styleState", "colorMode", "flyToMode"
    ]
    
    for enum_name in enum_names
        add_tag!(cache, enum_name)
    end
    
    # 4. Add field names that might appear as tags
    field_tags = [
        "name", "visibility", "open", "address", "phoneNumber", "description",
        "styleUrl", "color", "width", "scale", "heading", "tilt", "roll",
        "longitude", "latitude", "altitude", "range", "href", "refreshInterval",
        "viewRefreshTime", "viewBoundScale", "viewFormat", "httpQuery",
        "x", "y", "z", "w", "h", "xunits", "yunits", "north", "south", "east", "west",
        "rotation", "minAltitude", "maxAltitude", "minLodPixels", "maxLodPixels",
        "minFadeExtent", "maxFadeExtent", "leftFov", "rightFov", "bottomFov", "topFov",
        "near", "tileSize", "maxWidth", "maxHeight", "bgColor", "textColor", "text",
        "key", "value", "displayName", "state", "listItemType", "targetHref", "sourceHref",
        "type", "rel", "hreflang", "title", "length", "email", "uri", "targetId",
        "id", "when", "begin", "end", "coordinates", "extrude", "tessellate", "fill", "outline"
    ]
    
    for tag in field_tags
        cache[tag] = Symbol(tag)
    end
    
    # 5. Special mappings
    cache["begin"] = :begin_
    cache["end"] = :end_
    cache["Url"] = :Link  # Legacy mapping
    cache["Pair"] = :StyleMapPair
    cache["atom:author"] = :atom_author
    cache["atom:link"] = :atom_link
    
    return cache
end

function _create_field_map_cache()
    cache = IdDict{DataType,Dict{Symbol,Type}}()
    
    # Pre-populate for all concrete KML types
    for T in all_concrete_subtypes(KMLElement)
        field_names = fieldnames(T)
        field_types = fieldtypes(T)
        field_map = Dict{Symbol,Type}()
        
        for (fn, ft) in zip(field_names, field_types)
            field_map[fn] = Base.nonnothingtype(ft)
        end
        
        cache[T] = field_map
    end
    
    return cache
end

# Create the caches at module initialization
const _TAGSYM_CACHE = _create_tagsym_cache()
const _FIELD_MAP_CACHE = _create_field_map_cache()

# Thread-safe, read-only access functions
function tagsym(x::String)
    get(_TAGSYM_CACHE, x) do
        # Fallback for truly unknown tags (shouldn't happen with KML)
        Symbol(replace(x, r":" => "_"))
    end
end

function typemap(::Type{T}) where {T<:KMLElement}
    # Direct lookup - will throw KeyError if type not found (shouldn't happen)
    _FIELD_MAP_CACHE[T]
end
typemap(o::KMLElement) = typemap(typeof(o))

end # module Types