module XMLSerialization

export Node, to_xml, xml_children

import XML
import ..Types: KMLElement, KMLFile, LazyKMLFile, Document, XMLAnyNode, StyleMapPair, AtomAuthor,
                AtomLink, typemap
import ..Enums
import ..Coordinates: coordinate_string

# ─── KML names ───────────────────────────────────────────────────────────────
# A field or type name stands for a KML name: a namespace prefix gets its colon back
# (`gx_coord` is `gx:coord`), and `begin_`/`end_` avoid Julia keywords.
function kmlname(s::AbstractString)
    s == "begin_" && return "begin"
    s == "end_" && return "end"
    for p in ("gx_", "atom_", "xal_")
        startswith(s, p) && return string(chop(p), ':', chopprefix(s, p))
    end
    return String(s)
end
kmlname(s::Symbol) = kmlname(string(s))

# The element of a type, for a value in a field of an abstract type or in a vector. Three
# types are named apart from their element.
typetag(T::Type) = T === StyleMapPair ? "Pair" :
                   T === AtomAuthor   ? "atom:author" :
                   T === AtomLink     ? "atom:link" : kmlname(string(nameof(T)))

# The namespaces of the document and of the prefixes it may use.
const KML_NAMESPACE = "http://www.opengis.net/kml/2.2"
const PREFIX_NAMESPACES = ("gx" => "http://www.google.com/kml/ext/2.2",
                           "atom" => "http://www.w3.org/2005/Atom",
                           "xal" => "urn:oasis:names:tc:ciq:xsdschema:xAL:2.0")

# ─── v0.4 helpers ────────────────────────────────────────────────────────────
# In XML.jl v0.4, `Node{S}` is parameterized by storage type, and:
# - `attributes` is `Union{Nothing, Vector{Pair{S,S}}}` (was OrderedDict-like).
# - "leaf" node types (Text, CData, Comment, DTD, ProcessingInstruction,
#   Declaration) require `children = nothing` (not an empty vector — the v0.4
#   constructor validates this strictly).
# All FastKML serialization uses `S = String`. The aliases below keep call
# sites compact.
const FNode = XML.Node{String}
const Attrs = Union{Nothing, Vector{Pair{String, String}}}

function _build_attrs(o::T) where {names, T<:KMLElement{names}}
    pairs = Pair{String, String}[]
    for k in names
        v = getfield(o, k)
        v === nothing && continue
        push!(pairs, string(k) => string(v))
    end
    isempty(pairs) ? nothing : pairs
end

# ─── KMLElement → Node conversion ────────────────────────────────────────────
Node(o::T) where {T<:Enums.AbstractKMLEnum} = FNode(
    XML.Element, typetag(T), nothing, nothing,
    FNode[FNode(XML.Text, nothing, nothing, o.value, nothing)],
)

function Node(o::T, tag::AbstractString = typetag(T)) where {names, T<:KMLElement{names}}
    children = FNode[]
    declared = typemap(T)
    for field in fieldnames(T)
        field in names && continue
        val = getfield(o, field)
        val === nothing || _push_field!(children, field, declared[field], val)
    end
    return FNode(XML.Element, tag, _build_attrs(o), nothing, children)
end

_element(tag, children) = FNode(XML.Element, tag, nothing, nothing, children)
_text_element(tag, text) = _element(tag, FNode[FNode(XML.Text, nothing, nothing, text, nothing)])

# Text of a simple value: one `<gx:coord>` holds the numbers of one point, separated by spaces.
_text(x) = string(x)
_text(x::AbstractVector{<:Real}) = join(x, ' ')

# A node that `Metadata` keeps from the source, as a `Node{String}`. A `LazyNode` element is
# written and parsed again.
_source_node(n::FNode) = n
function _source_node(n::XMLAnyNode)
    nt = XML.nodetype(n)
    nt === XML.Element || return FNode(nt, nothing, nothing, String(something(XML.value(n), "")), nothing)
    doc = XML.parse(sprint(io -> XML.write(io, n)), XML.Node)
    return only(c for c in XML.children(doc) if XML.nodetype(c) === XML.Element)
end

function _push_field!(children::Vector{FNode}, field::Symbol, declared::Type, val)
    if field === :innerBoundaryIs
        push!(children, _element("innerBoundaryIs", FNode[Node(ring) for ring in val]))
    elseif field === :outerBoundaryIs
        push!(children, _element("outerBoundaryIs", FNode[Node(val)]))
    elseif field === :coordinates
        push!(children, _text_element("coordinates", coordinate_string(val)))
    elseif field === :content && val isa AbstractString
        # The text of the element itself (Snippet, SimpleData), not a child element.
        isempty(val) || push!(children, FNode(XML.Text, nothing, nothing, val, nothing))
    elseif val isa KMLElement
        # A field of a concrete type is named after the field (overlayXY, linkSnippet,
        # atom:author); a field of an abstract type, after the type of its value.
        push!(children, Node(val, isconcretetype(declared) ? kmlname(field) : typetag(typeof(val))))
    elseif val isa AbstractVector && !(val isa AbstractVector{<:Real})
        for item in val
            if item isa KMLElement
                push!(children, Node(item))
            elseif item isa XMLAnyNode
                push!(children, _source_node(item))
            else
                push!(children, _text_element(kmlname(field), _text(item)))
            end
        end
    else
        # Simple values and enumerations are named after their field: `key`, `state`, `gx:flyToMode`.
        push!(children, _text_element(kmlname(field), _text(val)))
    end
end

# ─── KMLFile → Node conversion ───────────────────────────────────────────────
# The prefixes of the element names in `n` and below, to declare on the root.
function _prefixes!(found::Set{String}, n)
    t = XML.tag(n)
    if t !== nothing
        i = findfirst(':', t)
        i === nothing || push!(found, t[begin:prevind(t, i)])
    end
    for c in XML.children(n)
        _prefixes!(found, c)
    end
    return found
end

function Node(k::KMLFile)
    children = FNode[]
    for child in k.children
        if child isa KMLElement
            push!(children, Node(child))
        elseif child isa XML.Node
            # Already a Node{S} of some S — narrow/copy if needed; for now,
            # FastKML's serialization path produces only Node{String}, so any
            # foreign Node{T} would be unusual. Push as-is and let the caller
            # observe the heterogeneity.
            push!(children, child)
        elseif child isa XMLAnyNode
            # XML.LazyNode encountered — convert to Node{String} via tree walk.
            # XML.jl v0.4 doesn't expose a one-shot LazyNode → Node converter
            # in the public API; for now, materialize via a write-then-parse
            # round-trip if this path ever fires (rare in practice — only
            # if something stuffed a LazyNode into a KMLFile.children).
            @warn "LazyNode in KMLFile.children — coercing via round-trip" type=typeof(child)
            push!(children, XML.parse(sprint(io -> XML.write(io, child)), XML.Node))
        else
            @warn "Unexpected child type in KMLFile" type=typeof(child)
            push!(children, FNode(XML.Text, nothing, nothing, string(child), nothing))
        end
    end

    decl_attrs = Pair{String, String}["version" => "1.0", "encoding" => "UTF-8"]
    used = Set{String}()
    foreach(c -> _prefixes!(used, c), children)
    kml_attrs = Pair{String, String}["xmlns" => KML_NAMESPACE]
    for (prefix, uri) in PREFIX_NAMESPACES
        prefix in used && push!(kml_attrs, "xmlns:$prefix" => uri)
    end

    return FNode(
        XML.Document,
        nothing,
        nothing,
        nothing,
        FNode[
            FNode(XML.Declaration, nothing, decl_attrs, nothing, nothing),
            FNode(XML.Element, "kml", kml_attrs, nothing, children),
        ],
    )
end

# ─── Helper to enable XML.children on KMLElement ─────────────────────────────
"""
    to_xml(element::Union{KMLElement, KMLFile}) -> XML.Node

Convert a KML element or file to its XML representation.
"""
to_xml(element::Union{KMLElement, KMLFile}) = Node(element)

"""
    xml_children(element::KMLElement) -> Vector{XML.Node}

Get the XML node children of a KML element after converting it to XML.
This is structural navigation, not semantic KML navigation.
"""
function xml_children(element::KMLElement)
    xml_node = Node(element)
    return XML.children(xml_node)
end

end # module XMLSerialization
