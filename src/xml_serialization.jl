module XMLSerialization

export Node, to_xml, xml_children

import XML
import ..Types: KMLElement, KMLFile, LazyKMLFile, Document, XMLAnyNode
import ..Enums
import ..Coordinates: coordinate_string

# ─── Type tag mapping ────────────────────────────────────────────────────────
typetag(T::Type) = replace(string(nameof(T)), "_" => ":")

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

function Node(o::T) where {names, T<:KMLElement{names}}
    tag = typetag(T)

    attrs = _build_attrs(o)
    element_fields = filter(x -> !isnothing(getfield(o, x)), setdiff(fieldnames(T), names))

    if isempty(element_fields)
        return FNode(XML.Element, tag, attrs, nothing, FNode[])
    end

    children = FNode[]
    for field in element_fields
        val = getfield(o, field)

        # IMPORTANT: Skip nothing values - this line must be here!
        val === nothing && continue

        if field == :innerBoundaryIs
            inner_children = FNode[Node(ring) for ring in val]
            push!(children, FNode(XML.Element, "innerBoundaryIs", nothing, nothing, inner_children))
        elseif field == :outerBoundaryIs
            push!(children, FNode(XML.Element, "outerBoundaryIs", nothing, nothing, FNode[Node(val)]))
        elseif field == :coordinates
            coord_text = FNode(XML.Text, nothing, nothing, coordinate_string(val), nothing)
            push!(children, FNode(XML.Element, "coordinates", nothing, nothing, FNode[coord_text]))
        elseif val isa KMLElement
            push!(children, Node(val))
        elseif val isa Vector{<:KMLElement}
            append!(children, Node.(val))
        elseif val isa Enums.AbstractKMLEnum
            push!(children, Node(val))
        elseif val isa Vector
            for item in val
                if item isa KMLElement
                    push!(children, Node(item))
                else
                    text_node = FNode(XML.Text, nothing, nothing, string(item), nothing)
                    push!(children, FNode(XML.Element, string(field), nothing, nothing, FNode[text_node]))
                end
            end
        else
            text_node = FNode(XML.Text, nothing, nothing, string(val), nothing)
            push!(children, FNode(XML.Element, string(field), nothing, nothing, FNode[text_node]))
        end
    end
    return FNode(XML.Element, tag, attrs, nothing, children)
end

# ─── KMLFile → Node conversion ───────────────────────────────────────────────
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
    kml_attrs  = Pair{String, String}["xmlns" => "http://earth.google.com/kml/2.2"]

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
