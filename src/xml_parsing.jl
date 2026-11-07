module XMLParsing

export object, extract_text_content_fast

using TimeZones
using Dates
import XML
import ..Types: KMLElement, TAG_TO_TYPE, typemap, KMLFile, NoAttributes, tagsym, XMLAnyNode
import ..Types  # Import all types
import ..Enums
import ..FieldConversion: assign_field!, assign_complex_object!, handle_polygon_boundary!, map_field_name
using ..ContentWarnings: @content_warn, with_content_warnings
import ..Macros: @for_each_immediate_child, @find_immediate_child, @count_immediate_children
import ..Coordinates: coordinate_string

# ─── Text extraction ─────────────────────────────────────────────────────────

"""
    extract_text_content_fast(node::XMLAnyNode) -> String

Extracts and concatenates the text content from the immediate children of a given XML node.

This function iterates only through the direct children of `node`. If a child is an
XML Text (`XML.Text`) or CData (`XML.CData`) node, its string value is collected.
All collected text values are then joined together. If no text content is found
among the immediate children, or if all text values are `nothing`, an empty string is returned.
"""
function extract_text_content_fast(node::XMLAnyNode)
    # Fast path: most KML elements have either no Text/CData child or a
    # single one (e.g. <name>FOO</name>, <description><![CDATA[…]]></description>).
    # For that common case we avoid allocating a `Vector{String}` and the
    # eager `join` that would otherwise copy the text. We only allocate the
    # extras vector when a 2nd fragment shows up.
    found::Union{Nothing,String} = nothing
    extras::Union{Nothing,Vector{String}} = nothing
    @for_each_immediate_child node child begin
        if XML.nodetype(child) === XML.Text || XML.nodetype(child) === XML.CData
            text_value = XML.value(child)
            if text_value !== nothing
                if found === nothing
                    found = text_value
                elseif extras === nothing
                    extras = String[found, text_value]
                else
                    push!(extras, text_value)
                end
            end
        end
    end
    if extras !== nothing
        return join(extras)
    elseif found !== nothing
        return found
    else
        return ""
    end
end

# ─── Parse KMLFile from XML document ─────────────────────────────────────────
# A whole read: the warnings about the content come once per kind (`with_content_warnings`).
parse_kmlfile(doc::XMLAnyNode) = with_content_warnings(() -> _parse_kmlfile(doc))

function _parse_kmlfile(doc::XMLAnyNode)
    kml_element = @find_immediate_child doc x (XML.nodetype(x) === XML.Element && XML.tag(x) == "kml")
    isnothing(kml_element) && error("No <kml> tag found in file.")
    
    # Only process element nodes
    kml_children = Vector{Union{XMLAnyNode,KMLElement}}()
    @for_each_immediate_child kml_element child_node begin
        if XML.nodetype(child_node) === XML.Element
            parsed = object(child_node)
            # object() can return: a KMLElement (well-modeled tag), a String
            # (simple leaf), or `nothing` (an enumeration, which only the field
            # of a parent converts, or a truly unmodeled tag — warning already
            # emitted there).
            # Direct children of <kml> are only meaningful as KMLElement. Anything
            # else is either malformed KML or an unmodeled top-level element
            # (e.g. <NetworkLinkControl> in real-world feeds): drop it instead of
            # crashing the whole parse.
            parsed isa KMLElement && push!(kml_children, parsed)
        end
        # Skip non-element nodes (text, comments, etc.)
    end
    
    KMLFile(kml_children)
end

# Convert LazyKMLFile to KMLFile
function Types.KMLFile(lazy::Types.LazyKMLFile)
    parse_kmlfile(lazy.root_node)
end

# ─── Main object parsing ─────────────────────────────────────────────────────
# A tag names an enumeration only when it names one of the enum TYPES. `names(Enums; all)`
# also lists the module's own functions and the macro that defines the enumerations, such as
# `include` and `eval`; resolving a tag to one of those would call it with the element's
# text. The set holds the concrete subtypes of `AbstractKMLEnum`.
const ENUM_NAMES_SET = Set(nameof(T) for T in Types.all_concrete_subtypes(Enums.AbstractKMLEnum))

"""
Main entry point for parsing XML nodes into KML objects.
"""
function object(node::XMLAnyNode)
    # Assuming 'node' is always an XML.Element when object() is called for KML types
    sym = tagsym(XML.tag(node))

    # ──  0. Structural tags (handled by add_element!) ─────────────────────────
    if sym === :outerBoundaryIs || sym === :innerBoundaryIs
        return nothing
    end

    # ──  1. Tags mapping directly to KML types via TAG_TO_TYPE ──────────────────
    if haskey(TAG_TO_TYPE, sym)
        T = TAG_TO_TYPE[sym]
        o = T()
        add_attributes!(o, node)

        if T === Types.Snippet || T === Types.SimpleData
            if hasfield(T, :content) && fieldtype(T, :content) === String
                setfield!(o, :content, extract_text_content_fast(node))
            end
            # For Snippet, still process any element children
            if T === Types.Snippet
                @for_each_immediate_child node child_element_node begin
                    if XML.nodetype(child_element_node) === XML.Element
                        add_element!(o, child_element_node)
                    end
                end
            end
        elseif T === Types.Metadata
            # OGC 2.2 §6.7 declares Metadata as <any processContents="lax">.
            # We don't parse the subtree — just preserve raw XML.Node children
            # for callers who need to inspect them. Avoids spurious
            # "Unhandled tag" warnings for the (deprecated) inner content.
            @for_each_immediate_child node child_element_node begin
                if XML.nodetype(child_element_node) === XML.Element
                    push!(o.children, child_element_node)
                end
            end
        else
            # Generic parsing of child ELEMENTS for all other KMLElement types
            @for_each_immediate_child node child_element_node begin
                if XML.nodetype(child_element_node) === XML.Element
                    add_element!(o, child_element_node)
                end
            end
        end
        return o
    end

    # ──  2. Enums ───────────────────────────────────────────────────────────────
    if sym in ENUM_NAMES_SET
        text_content = extract_text_content_fast(node)
        if !isempty(text_content)
            # The field assignment of the parent converts the text, once: it warns and
            # leaves the field empty for a value outside the enumeration, or, for an
            # altitude mode, finds the value in the other enumeration.
            return nothing
        else
            # An empty enumeration: the field assignment warns once (`_assign_empty!`).
            return ""
        end
    end

    # ──  3. Simple leaf tags (handled if object() is called on them directly)
    if XML.is_simple(node)
        return extract_text_content_fast(node)
    end

    # ──  4. An element without content, such as <name/>: the field assignment decides
    #        whether its value may be empty (`_assign_empty!`).
    isempty(XML.children(node)) && return ""

    # ──  5. Fallback ─────────────────────────────────────────────────────────────
    return _object_slow(node)
end

# An element that the steps of `object` leave names no KML type: `TAG_TO_TYPE` holds every
# concrete KML type under its tag and its name, and the enumerations come before. Any other
# name, such as that of an abstract type like `Feature`, is not instantiated: the element
# is left out, with a warning, and the rest of the file is read.
function _object_slow(node::XMLAnyNode)
    original_tag_name = XML.tag(node)
    sym = tagsym(original_tag_name)
    @content_warn (:unhandled_tag, String(original_tag_name)) "Unhandled Tag: `'$original_tag_name'` (symbol: `:$sym`). This tag was not recognized."
    return nothing
end

# ─── Element addition ────────────────────────────────────────────────────────
function add_element!(parent::KMLElement, child_xml_node::XMLAnyNode)
    child_parsed_val = object(child_xml_node)

    if child_parsed_val isa KMLElement
        assign_complex_object!(parent, child_parsed_val, XML.tag(child_xml_node))
        return
    elseif child_parsed_val isa AbstractString
        field_name_sym = tagsym(XML.tag(child_xml_node))
        if isempty(child_parsed_val)
            _assign_empty!(parent, field_name_sym, XML.tag(child_xml_node))
        else
            assign_field!(parent, field_name_sym, child_parsed_val, XML.tag(child_xml_node))
        end
        return
    else
        # An enumeration, such as <gx:altitudeMode>, may go to a field of another name.
        field_name_sym = map_field_name(parent, tagsym(XML.tag(child_xml_node)))

        # Special handling for Polygon boundaries
        if parent isa Types.Polygon && (field_name_sym === :outerBoundaryIs || field_name_sym === :innerBoundaryIs)
            handle_polygon_boundary!(parent, child_xml_node, field_name_sym, object)
            return
        end

        # Check if it's a simple field that needs text extraction
        if get(typemap(typeof(parent)), field_name_sym, nothing) === String

            text_content_for_field = extract_text_content_fast(child_xml_node)
            assign_field!(parent, field_name_sym, text_content_for_field, XML.tag(child_xml_node))
            return

        elseif XML.is_simple(child_xml_node) && hasfield(typeof(parent), field_name_sym)
            text_content_for_field = extract_text_content_fast(child_xml_node)
            assign_field!(parent, field_name_sym, text_content_for_field, XML.tag(child_xml_node))
            return
        end

        @content_warn (:unhandled_child, field_name_sym, nameof(typeof(parent))) "Unhandled tag $field_name_sym (from XML <$(XML.tag(child_xml_node))>) for parent $(typeof(parent))"
    end
end

# An empty element, such as <name/>. The KML 2.2 schemas allow an empty string, URI or
# coordinate list: a string field keeps "", so that the element is written back, and the
# other fields stay empty. A boolean, a number or an enumeration cannot be empty: the
# element is left out, with a warning.
function _assign_empty!(parent::KMLElement, field_name_sym::Symbol, tag::AbstractString)
    field = map_field_name(parent, field_name_sym)
    if !hasfield(typeof(parent), field)
        @content_warn (:no_field, nameof(typeof(parent)), String(tag)) "No field named '$field_name_sym' (or mapped '$field') in $(typeof(parent)) for tag <$tag>"
        return
    end
    T = typemap(typeof(parent))[field]
    if T === String
        setfield!(parent, field, "")
    elseif T <: Union{Bool,Number,Enums.AbstractKMLEnum}
        @content_warn (:empty, String(tag)) "<$tag> is empty, which KML 2.2 does not allow for its value: it is left out"
    end
    return
end

# ─── Helper functions ────────────────────────────────────────────────────────

tagsym(x::XMLAnyNode) = tagsym(XML.tag(x))

function add_attributes!(o::KMLElement, source::XMLAnyNode)
    attr = XML.attributes(source)
    isnothing(attr) && return

    tm = typemap(o)
    for (k, v) in attr
        startswith(k, "xmlns") && continue
        sym = tagsym(k)
        haskey(tm, sym) || continue
        
        # Use the field assignment system for attributes
        assign_field!(o, sym, v, k)
    end
end

end # module XMLParsing