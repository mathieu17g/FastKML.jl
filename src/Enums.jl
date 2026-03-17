module Enums

export AbstractKMLEnum, @kml_enum
# Export all enum types
export altitudeMode, gx_altitudeMode, refreshMode, viewRefreshMode, shape, gridOrigin,
       displayMode, listItemType, units, itemIconState, styleState, colorMode, flyToMode

using XML

# ─── Abstract base type for all KML enums ────────────────────────────────────
abstract type AbstractKMLEnum end

Base.show(io::IO, o::AbstractKMLEnum) = print(io, typeof(o), ": ", repr(o.value))
Base.convert(::Type{T}, x::String) where {T<:AbstractKMLEnum} = T(x)
Base.string(o::AbstractKMLEnum) = o.value

# ─── Macro for defining KML enum types ───────────────────────────────────────
macro kml_enum(enum_name::Symbol, vals...)
    # enum_name is the symbol for the enum type, e.g., :altitudeMode
    # vals is a tuple of symbols for the valid values, e.g., (:clampToGround, :relativeToGround, :absolute)

    # Create a string version of the enum's name (e.g., "altitudeMode")
    enum_name_as_string = string(enum_name)

    # Create a tuple of strings for the valid enum values (e.g., ("clampToGround", "relativeToGround", "absolute"))
    # This tuple will be used for both the runtime check and the error message.
    valid_values_as_strings_tuple = map(string, vals)

    esc(
        quote
            struct $enum_name <: AbstractKMLEnum # AbstractKMLEnum is defined in the same Enums module
                value::String # The validated string value

                # Constructor that takes a String
                function $enum_name(input_string::String)
                    # Check if the input_string is one of the valid values
                    # $valid_values_as_strings_tuple is spliced in directly here
                    if !(input_string ∈ $valid_values_as_strings_tuple)
                        # Construct the error message using the pre-stringified components
                        # $enum_name_as_string and $valid_values_as_strings_tuple are spliced in
                        error_msg = string(
                            $enum_name_as_string,
                            " must be one of ",
                            $valid_values_as_strings_tuple, # This will show as ("val1", "val2", ...)
                            ", but got: '",
                            input_string,
                            "'",
                        )
                        error(error_msg)
                    end
                    new(input_string) # Store the validated string
                end

                # Convenience constructor for any AbstractString input (delegates to the String constructor)
                function $enum_name(input_abstract_string::AbstractString)
                    $enum_name(String(input_abstract_string))
                end
            end
        end,
    )
end

# ─── KML Enum Definitions ────────────────────────────────────────────────────

# Special handling for altitudeMode with normalization
struct altitudeMode <: AbstractKMLEnum
    value::String # Stores the KML standard-compliant value

    function altitudeMode(input_value::AbstractString)
        # Convert input to String for consistent processing
        input_str = String(input_value)

        # Normalize "clampedToGround" to "clampToGround"
        normalized_str = if input_str == "clampedToGround"
            "clampToGround"
        else
            input_str
        end

        # Define the standard valid options
        valid_options = ("clampToGround", "relativeToGround", "absolute")

        # Check if the normalized string is one of the valid options
        if !(normalized_str ∈ valid_options)
            error_message = string(
                "altitudeMode must be one of ",
                valid_options,
                ", but got original value: '",
                input_str, # Show the original value in the error
                "'",
            )
            error(error_message)
        end
        new(normalized_str) # Store the (potentially normalized) standard value
    end
end

# Define all other KML enums
@kml_enum gx_altitudeMode relativeToSeaFloor clampToSeaFloor
@kml_enum refreshMode onChange onInterval onExpire
@kml_enum viewRefreshMode never onStop onRequest onRegion
@kml_enum shape rectangle cylinder sphere
@kml_enum gridOrigin lowerLeft upperLeft
@kml_enum displayMode default hide
@kml_enum listItemType check checkOffOnly checkHideChildren radioFolder
@kml_enum units fraction pixels insetPixels
@kml_enum itemIconState open closed error fetching0 fetching1 fetching2
@kml_enum styleState normal highlight
@kml_enum colorMode normal random
@kml_enum flyToMode smooth bounce

end # module Enums