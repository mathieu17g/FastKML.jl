module XMLParsing

export object, extract_text_content_fast

using TimeZones
using Dates
import XML
import ..Types: KMLElement, TAG_TO_TYPE, typemap, KMLFile, NoAttributes, tagsym
import ..Types  # Import all types
import ..Enums
import ..FieldConversion: assign_field!, assign_complex_object!, handle_polygon_boundary!
import ..Macros: @for_each_immediate_child, @find_immediate_child, @count_immediate_children
import ..Coordinates: coordinate_string

# ─── Text extraction ─────────────────────────────────────────────────────────

"""
    extract_text_content_fast(node::XML.AbstractXMLNode) -> String

Extracts and concatenates the text content from the immediate children of a given XML node.

This function iterates only through the direct children of `node`. If a child is an
XML Text (`XML.Text`) or CData (`XML.CData`) node, its string value is collected.
All collected text values are then joined together. If no text content is found
among the immediate children, or if all text values are `nothing`, an empty string is returned.
"""
function extract_text_content_fast(node::XML.AbstractXMLNode)
    texts = String[]
    @for_each_immediate_child node child begin
        if XML.nodetype(child) === XML.Text || XML.nodetype(child) === XML.CData
            text_value = XML.value(child)
            if text_value !== nothing
                push!(texts, text_value)
            end
        end
    end
    return isempty(texts) ? "" : join(texts)
end

# ─── Parse KMLFile from XML document ─────────────────────────────────────────
function parse_kmlfile(doc::XML.AbstractXMLNode)
    kml_element = @find_immediate_child doc x (XML.nodetype(x) === XML.Element && XML.tag(x) == "kml")
    isnothing(kml_element) && error("No <kml> tag found in file.")
    
    # Only process element nodes
    kml_children = Vector{Union{XML.AbstractXMLNode,KMLElement}}()
    @for_each_immediate_child kml_element child_node begin
        if XML.nodetype(child_node) === XML.Element
            push!(kml_children, object(child_node))
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
const ENUM_NAMES_SET = Set(names(Enums; all = true))

"""
Main entry point for parsing XML nodes into KML objects.
"""
function object(node::XML.AbstractXMLNode)
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
            return getproperty(Enums, sym)(text_content)
        else
            @warn "Enum tag <$(XML.tag(node))> did not contain text content."
            return nothing
        end
    end

    # ──  3. Simple leaf tags (handled if object() is called on them directly)
    if XML.is_simple(node)
        text_content = extract_text_content_fast(node)
        return isempty(text_content) ? nothing : text_content
    end

    # ──  4. Fallback ─────────────────────────────────────────────────────────────
    return _object_slow(node)
end

const KML_NAMES_SET = let
    # Collect all names from Types module
    all_names = Set{Symbol}()
    for name in names(Types; all = true, imported = false)
        if !startswith(string(name), "_") && name != :Types
            push!(all_names, name)
        end
    end
    all_names
end

function _object_slow(node::XML.AbstractXMLNode)
    original_tag_name = XML.tag(node)
    sym = tagsym(original_tag_name)

    @debug "Entered _object_slow for tag: '$original_tag_name' (symbol: :$sym)"

    # Path 1: Is it an Enum that was perhaps missed by the main object() check?
    if sym in ENUM_NAMES_SET
        @debug "Tag '$original_tag_name' (symbol :$sym) is being parsed as an Enum by `_object_slow`"
        return getproperty(Enums, sym)(extract_text_content_fast(node))
    end

    # Path 2: Is it a KML type defined in the KML module but somehow missed by TAG_TO_TYPE?
    if sym in KML_NAMES_SET || sym == :Pair
        @warn begin
            "Performance Hint: KML type `:$sym` (from tag `'$original_tag_name'`) is being instantiated " *
            "via reflection in `_object_slow`. This is a fallback and less efficient.\n" *
            "ACTION: To improve performance and maintainability, ensure that the tag `'$original_tag_name'` " *
            "correctly maps to the Julia type in the `TAG_TO_TYPE` dictionary."
        end

        # Object instantiation logic - need to find the type in the Types module
        T = if hasproperty(Types, sym)
            getproperty(Types, sym)
        else
            error("Type $sym not found in Types module")
        end
        
        o = T()
        add_attributes!(o, node)
        @for_each_immediate_child node child_xml_node begin
            add_element!(o, child_xml_node)
        end
        return o
    end

    # Path 3: Fallthrough - truly unhandled or unrecognized tag
    @warn "Unhandled Tag: `'$original_tag_name'` (symbol: `:$sym`). This tag was not recognized."
    return nothing
end

# ─── Element addition ────────────────────────────────────────────────────────
function add_element!(parent::KMLElement, child_xml_node::XML.AbstractXMLNode)
    child_parsed_val = object(child_xml_node)

    if child_parsed_val isa KMLElement
        assign_complex_object!(parent, child_parsed_val, XML.tag(child_xml_node))
        return
    elseif child_parsed_val isa AbstractString
        field_name_sym = tagsym(XML.tag(child_xml_node))
        assign_field!(parent, field_name_sym, child_parsed_val, XML.tag(child_xml_node))
        return
    else
        field_name_sym = tagsym(XML.tag(child_xml_node))

        # Special handling for Polygon boundaries
        if parent isa Types.Polygon && (field_name_sym === :outerBoundaryIs || field_name_sym === :innerBoundaryIs)
            handle_polygon_boundary!(parent, child_xml_node, field_name_sym, object)
            return
        end

        # Check if it's a simple field that needs text extraction
        if hasfield(typeof(parent), field_name_sym) &&
           Base.nonnothingtype(fieldtype(typeof(parent), field_name_sym)) === String

            text_content_for_field = extract_text_content_fast(child_xml_node)
            assign_field!(parent, field_name_sym, text_content_for_field, XML.tag(child_xml_node))
            return

        elseif XML.is_simple(child_xml_node) && hasfield(typeof(parent), field_name_sym)
            text_content_for_field = extract_text_content_fast(child_xml_node)
            assign_field!(parent, field_name_sym, text_content_for_field, XML.tag(child_xml_node))
            return
        end

        @warn "Unhandled tag $field_name_sym (from XML <$(XML.tag(child_xml_node))>) for parent $(typeof(parent))"
    end
end

# ─── Helper functions ────────────────────────────────────────────────────────

tagsym(x::XML.AbstractXMLNode) = tagsym(XML.tag(x))

function add_attributes!(o::KMLElement, source::XML.AbstractXMLNode)
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