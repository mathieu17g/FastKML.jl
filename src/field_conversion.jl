module FieldConversion

export convert_field_value, assign_field!, assign_complex_object!, handle_polygon_boundary!, FieldConversionError

using Parsers
using TimeZones
using Dates
using StaticArrays  # For StaticArray type checking
import ..Types
import ..Types: Coord2, Coord3, tagsym
import ..Enums
import ..Coordinates: parse_coordinates_automa
import ..TimeParsing: parse_iso8601
import XML
import ..Macros: @find_immediate_child, @for_each_immediate_child, @count_immediate_children

# ─── Field Conversion Error ──────────────────────────────────────────────────
struct FieldConversionError <: Exception
    field_name::Symbol
    target_type::Type
    value::String
    message::String
end

# ─── Field Conversion Logic ──────────────────────────────────────────────────
"""
Convert a string value to the target type for a specific field.
Handles all KML field type conversions including coordinates, dates, enums, etc.
"""
function convert_field_value(value::String, target_type::Type, field_name::Symbol, parent_type::Type=Nothing)
    # Handle empty strings for optional fields
    if isempty(value) && Nothing <: target_type
        return nothing
    end
    
    # Get the non-nothing type for conversion
    actual_type = Base.nonnothingtype(target_type)
    
    try
        # String types
        if actual_type === String
            return value
            
        # Numeric types
        elseif actual_type <: Integer
            return isempty(value) ? zero(actual_type) : Parsers.parse(actual_type, value)
            
        elseif actual_type <: AbstractFloat
            return isempty(value) ? zero(actual_type) : Parsers.parse(actual_type, value)
            
        # Boolean types
        elseif actual_type <: Bool
            return parse_boolean(value)
            
        # Enum types
        elseif actual_type <: Enums.AbstractKMLEnum
            return isempty(value) && Nothing <: target_type ? nothing : actual_type(value)
            
        # Coordinate types
        elseif field_name === :coordinates || field_name === :gx_coord
            return convert_coordinates(value, actual_type, target_type, parent_type)
            
        # Time primitive types
        elseif is_time_primitive_type(actual_type)
            return parse_iso8601(value)
            
        else
            throw(FieldConversionError(field_name, target_type, value, 
                "Unhandled field type: $actual_type"))
        end
        
    catch e
        if e isa FieldConversionError
            rethrow(e)
        else
            throw(FieldConversionError(field_name, target_type, value, 
                "Conversion failed: $(e)"))
        end
    end
end

"""
Convert a string value for a vector field element.
"""
function convert_field_value_vector(value::String, element_type::Type, field_name::Symbol)
    # Handle empty strings for optional elements
    if isempty(value) && Nothing <: element_type
        return nothing
    end
    
    actual_type = Base.nonnothingtype(element_type)
    
    # For vector elements, use the same conversion logic
    return convert_field_value(value, actual_type, field_name)
end

# ─── Field Assignment Logic ──────────────────────────────────────────────────
"""
Assign a converted string value to a field in the parent object.
Handles both scalar and vector fields.
"""
function assign_field!(parent::Types.KMLElement, field_name::Symbol, value::AbstractString, original_tag::String)
    # Handle special field name mappings
    true_field_name = map_field_name(parent, field_name)
    
    if !hasfield(typeof(parent), true_field_name)
        @warn "No field named '$field_name' (or mapped '$true_field_name') in $(typeof(parent)) for tag <$original_tag>"
        return
    end
    
    # Get field type information
    field_type = fieldtype(typeof(parent), true_field_name)
    non_nothing_type = Types.typemap(typeof(parent))[true_field_name]
    
    # Convert to String if needed (for SubString support)
    value_str = String(value)
    
    # Special handling for coordinate fields - they should ALWAYS use convert_field_value
    # and never go through the vector element parsing path
    if true_field_name === :coordinates || true_field_name === :gx_coord
        try
            converted_value = convert_field_value(value_str, field_type, true_field_name, typeof(parent))
            setfield!(parent, true_field_name, converted_value)
        catch e
            if e isa FieldConversionError
                @warn "Failed to convert coordinate field $true_field_name: $(e.message)" value=value_str
                if Nothing <: field_type
                    setfield!(parent, true_field_name, nothing)
                end
            else
                rethrow(e)
            end
        end
        return
    end
    
    # Check if it's a vector field (but not coordinates)
    if non_nothing_type <: AbstractVector && is_simple_vector_type(non_nothing_type)
        assign_vector_element!(parent, true_field_name, field_type, non_nothing_type, value_str, original_tag)
    else
        # Scalar field
        try
            converted_value = convert_field_value(value_str, field_type, true_field_name)
            setfield!(parent, true_field_name, converted_value)
        catch e
            if e isa FieldConversionError
                @warn "Failed to convert value for field $true_field_name: $(e.message)" value=value_str
                # Set to nothing if optional, otherwise use fallback
                if Nothing <: field_type
                    setfield!(parent, true_field_name, nothing)
                elseif non_nothing_type === String
                    setfield!(parent, true_field_name, value_str)  # Fallback to string
                end
            else
                rethrow(e)
            end
        end
    end
end

"""
Assign a complex KML object to the appropriate field in the parent.
"""
function assign_complex_object!(parent::Types.KMLElement, child_object::Types.KMLElement, original_tag::String)
    child_type = typeof(child_object)
    assigned = false
    parent_type = typeof(parent)
    
    # Try to find a compatible field
    for field_name in fieldnames(parent_type)
        field_type = fieldtype(parent_type, field_name)
        non_nothing_type = Types.typemap(parent_type)[field_name]
        
        # Direct type match
        if child_type <: non_nothing_type
            setfield!(parent, field_name, child_object)
            assigned = true
            break
        # Vector field match
        elseif non_nothing_type <: AbstractVector && child_type <: eltype(non_nothing_type)
            vec = getfield(parent, field_name)
            if vec === nothing
                setfield!(parent, field_name, eltype(non_nothing_type)[])
                vec = getfield(parent, field_name)
            end
            push!(vec, child_object)
            assigned = true
            break
        end
    end
    
    if !assigned
        @warn "Could not assign $(child_type) (from <$original_tag>) to any field in $(parent_type)"
    end
end

"""
Special handler for Polygon boundary elements.
The object_fn parameter should be the object parsing function from the parsing module.
"""
function handle_polygon_boundary!(polygon, boundary_node::XML.AbstractXMLNode, boundary_type::Symbol, object_fn)
    # If object_fn not provided, we can't parse LinearRing nodes
    if object_fn === nothing
        @warn "object function not provided to handle_polygon_boundary!"
        return
    end
    
    if boundary_type === :outerBoundaryIs
        lr_node = @find_immediate_child boundary_node c begin
            XML.nodetype(c) === XML.Element && tagsym(XML.tag(c)) === :LinearRing
        end
        
        if lr_node !== nothing
            lr_obj = object_fn(lr_node)
            if lr_obj isa Types.LinearRing
                setfield!(polygon, :outerBoundaryIs, lr_obj)
            else
                @warn "<outerBoundaryIs> LinearRing didn't parse correctly"
            end
        else
            # Count children for better error message
            element_count = @count_immediate_children boundary_node c (XML.nodetype(c) === XML.Element)
            @warn "<outerBoundaryIs> expected <LinearRing>, found $element_count element(s)"
        end
        
    elseif boundary_type === :innerBoundaryIs
        if getfield(polygon, :innerBoundaryIs) === nothing
            setfield!(polygon, :innerBoundaryIs, Types.LinearRing[])
        end
        
        rings_processed = 0
        element_count = 0
        
        @for_each_immediate_child boundary_node lr_node begin
            if XML.nodetype(lr_node) === XML.Element
                element_count += 1
                if tagsym(XML.tag(lr_node)) === :LinearRing
                    lr_obj = object_fn(lr_node)
                    if lr_obj isa Types.LinearRing
                        push!(getfield(polygon, :innerBoundaryIs), lr_obj)
                        rings_processed += 1
                    else
                        @warn "LinearRing in <innerBoundaryIs> didn't parse correctly"
                    end
                else
                    @warn "<innerBoundaryIs> contained non-LinearRing element: <$(XML.tag(lr_node))>"
                end
            end
        end
        
        if element_count == 0
            @warn "<innerBoundaryIs> contained no elements"
        elseif element_count > 1 && rings_processed > 0
            @info "Processed $rings_processed LinearRing(s) from <innerBoundaryIs>" maxlog=1
        end
    end
end

# ─── Helper Functions ────────────────────────────────────────────────────────

function parse_boolean(value::String)::Bool
    len = length(value)
    if len == 1
        return value[1] == '1'
    elseif len == 4 && uppercase(value) == "TRUE"
        return true
    elseif len == 5 && uppercase(value) == "FALSE"
        return false
    else
        return false  # Default for invalid values
    end
end

function convert_coordinates(value::String, actual_type::Type, original_type::Type, parent_type::Type=Nothing)
    
    # Handle empty string early
    if isempty(value)
        if Nothing <: original_type
            return nothing
        elseif actual_type <: SVector{4}
            # Return default 4 coordinates for gx:LatLonQuad
            return SVector{4}(fill(SVector(0.0, 0.0), 4))
        elseif actual_type <: AbstractVector
            return actual_type()
        else
            return nothing
        end
    end
    
    parsed_coords = parse_coordinates_automa(value)
    
    if isempty(parsed_coords)
        if Nothing <: original_type
            return nothing
        elseif actual_type <: AbstractVector
            return actual_type()
        elseif actual_type <: SVector{4}
            # Return default 4 coordinates for gx:LatLonQuad
            return SVector{4}(fill(SVector(0.0, 0.0), 4))
        else
            return nothing
        end
    end
    
    # Special handling for SVector{4, Coord2} (gx:LatLonQuad)
    if actual_type <: SVector{4}
        if length(parsed_coords) != 4
            throw(FieldConversionError(:coordinates, actual_type, value,
                "gx:LatLonQuad requires exactly 4 coordinates, got $(length(parsed_coords))"))
        end
        return SVector{4}(parsed_coords)
    end
    
    # Single coordinate types (Point)
    if actual_type <: Union{Coord2, Coord3}
        if length(parsed_coords) == 1
            return convert(actual_type, parsed_coords[1])
        else
            # Take first coordinate with warning
            @warn "Expected 1 coordinate, got $(length(parsed_coords)). Using first."
            return convert(actual_type, parsed_coords[1])
        end
    # Vector coordinate types (LineString, LinearRing)
    elseif actual_type <: AbstractVector
        return convert(actual_type, parsed_coords)
    else
        throw(FieldConversionError(:coordinates, actual_type, value,
            "Unhandled coordinate type: $actual_type"))
    end
end

function is_time_primitive_type(T::Type)
    T == Union{TimeZones.ZonedDateTime, Dates.Date, String} ||
    T == Union{Dates.Date, TimeZones.ZonedDateTime, String} ||
    T == Union{TimeZones.ZonedDateTime, String, Dates.Date} ||
    T == Union{String, TimeZones.ZonedDateTime, Dates.Date} ||
    T == Union{Dates.Date, String, TimeZones.ZonedDateTime} ||
    T == Union{String, Dates.Date, TimeZones.ZonedDateTime}
end

function map_field_name(parent, field_name::Symbol)::Symbol
    # Special mappings for specific types
    if parent isa Types.TimeSpan
        if field_name === :begin
            return :begin_
        elseif field_name === :end
            return :end_
        end
    end
    return field_name
end

function is_simple_vector_type(vec_type::Type)
    if !(vec_type <: AbstractVector)
        return false
    end
    
    el_type = eltype(vec_type)
    actual_el_type = Base.nonnothingtype(el_type)
    
    # Exclude coordinate types - they need special parsing
    if actual_el_type <: Union{Coord2, Coord3}
        return false
    end
    
    # Exclude StaticArrays (which are often used for coordinates)
    if actual_el_type <: StaticArrays.StaticArray
        return false
    end
    
    return actual_el_type === String ||
           actual_el_type <: Integer ||
           actual_el_type <: AbstractFloat ||
           actual_el_type <: Bool ||
           actual_el_type <: Enums.AbstractKMLEnum ||
           is_time_primitive_element_type(el_type)
end

function is_time_primitive_element_type(T::Type)
    T == Union{TimeZones.ZonedDateTime, Dates.Date, String} ||
    T == Union{Dates.Date, TimeZones.ZonedDateTime, String} ||
    T == Union{TimeZones.ZonedDateTime, String, Dates.Date} ||
    T == Union{String, TimeZones.ZonedDateTime, Dates.Date} ||
    T == Union{Dates.Date, String, TimeZones.ZonedDateTime} ||
    T == Union{String, Dates.Date, TimeZones.ZonedDateTime}
end

function assign_vector_element!(parent, field_name::Symbol, field_type::Type, vec_type::Type,
                               value::String, original_tag::String)
    el_type = eltype(vec_type)
    
    try
        converted_value = convert_field_value_vector(value, el_type, field_name)
        
        # Get or initialize the vector
        current_vector = getfield(parent, field_name)
        if current_vector === nothing
            new_vector = el_type[]
            setfield!(parent, field_name, new_vector)
            current_vector = new_vector
        end
        
        # Push the converted element
        if converted_value !== nothing || Nothing <: el_type
            push!(current_vector, converted_value)
        elseif !isempty(value)
            @warn "Could not push non-empty value '$value' to vector field $field_name"
        end
        
    catch e
        if e isa FieldConversionError
            @warn "Failed to convert vector element for field $field_name: $(e.message)" value=value
        else
            rethrow(e)
        end
    end
end

end # module FieldConversion