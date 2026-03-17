module XMLSerialization

export Node, to_xml, xml_children

using OrderedCollections: OrderedDict
import XML
import ..Types: KMLElement, KMLFile, LazyKMLFile, Document
import ..Enums
import ..Coordinates: coordinate_string

# ─── Type tag mapping ────────────────────────────────────────────────────────
typetag(T::Type) = replace(string(nameof(T)), "_" => ":")

# ─── KMLElement → Node conversion ────────────────────────────────────────────
Node(o::T) where {T<:Enums.AbstractKMLEnum} = XML.Node(XML.Element, typetag(T), nothing, nothing, [XML.Node(XML.Text, nothing, nothing, o.value, XML.Node[])])

function Node(o::T) where {names,T<:KMLElement{names}}
    tag = typetag(T)
    
    attributes = Dict(string(k) => string(getfield(o, k)) for k in names if !isnothing(getfield(o, k)))
    element_fields = filter(x -> !isnothing(getfield(o, x)), setdiff(fieldnames(T), names))
    
    if isempty(element_fields)
        return XML.Node(XML.Element, tag, attributes, nothing, XML.Node[])
    end
    
    children = XML.Node[]
    for field in element_fields
        val = getfield(o, field)
        
        # IMPORTANT: Skip nothing values - this line must be here!
        if val === nothing
            continue
        end
        
        if field == :innerBoundaryIs
            # Create a container element for innerBoundaryIs
            inner_children = [Node(ring) for ring in val]
            push!(children, XML.Node(XML.Element, "innerBoundaryIs", nothing, nothing, inner_children))
        elseif field == :outerBoundaryIs
            # Create a container element for outerBoundaryIs
            push!(children, XML.Node(XML.Element, "outerBoundaryIs", nothing, nothing, [Node(val)]))
        elseif field == :coordinates
            # Create text node with coordinate string
            coord_text = XML.Node(XML.Text, nothing, nothing, coordinate_string(val), XML.Node[])
            push!(children, XML.Node(XML.Element, "coordinates", nothing, nothing, [coord_text]))
        elseif val isa KMLElement
            push!(children, Node(val))
        elseif val isa Vector{<:KMLElement}
            append!(children, Node.(val))
        elseif val isa Enums.AbstractKMLEnum
            # Handle enum values
            push!(children, Node(val))
        elseif val isa Vector
            # Handle other vector types (like Vector{String})
            for item in val
                if item isa KMLElement
                    push!(children, Node(item))
                else
                    text_node = XML.Node(XML.Text, nothing, nothing, string(item), XML.Node[])
                    push!(children, XML.Node(XML.Element, string(field), nothing, nothing, [text_node]))
                end
            end
        else
            # Create text node for simple values
            text_node = XML.Node(XML.Text, nothing, nothing, string(val), XML.Node[])
            push!(children, XML.Node(XML.Element, string(field), nothing, nothing, [text_node]))
        end
    end
    return XML.Node(XML.Element, tag, attributes, nothing, children)
end

# ─── KMLFile → Node conversion ───────────────────────────────────────────────
function Node(k::KMLFile)
    children = map(k.children) do child
        # Check KMLElement FIRST, before XML types
        if child isa KMLElement
            # Convert KML elements to Node
            Node(child)
        elseif child isa XML.Node
            # Already a Node, use as is
            child
        elseif child isa XML.AbstractXMLNode
            # Convert other XML nodes to Node
            XML.Node(child)
        else
            # This shouldn't happen, but log a warning
            @warn "Unexpected child type in KMLFile" type=typeof(child)
            XML.Node(XML.Text, nothing, nothing, string(child), XML.Node[])
        end
    end

    XML.Node(
        XML.Document,
        nothing,
        nothing,
        nothing,
        [
            XML.Node(XML.Declaration, nothing, OrderedDict("version" => "1.0", "encoding" => "UTF-8"), nothing, XML.Node[]),
            XML.Node(XML.Element, "kml", OrderedDict("xmlns" => "http://earth.google.com/kml/2.2"), nothing, children),
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