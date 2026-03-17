module TimeParsing

export parse_iso8601

# ─── base deps ────────────────────────────────────────────────────────────────
using Dates, TimeZones, Automa

# Define regex patterns for ISO 8601 formats
const digit = re"[0-9]"
const year = digit * digit * digit * digit
const month = re"[01][0-9]"  # 00-19, will need runtime validation for 01-12
const day = re"[0-3][0-9]"    # 00-39, will need runtime validation for 01-31
const week = re"W" * re"[0-5][0-9]"  # W00-W59, will need runtime validation for W01-W53
const weekday = re"[1-7]"
const ordinal = re"[0-3][0-9][0-9]"  # 000-399, will need runtime validation for 001-366

# Time components
const hour = re"[0-2][0-9]"   # 00-29, will need runtime validation for 00-23
const minute = re"[0-5][0-9]"  # 00-59
const second = re"[0-6][0-9]"  # 00-69, allows for leap seconds
const fraction = re"\." * digit * rep(digit)

# Timezone components
const tz_utc = re"Z"
const tz_offset = re"[+-]" * digit * digit * opt(re":") * digit * digit
const tz_name = re"[A-Za-z_]" * rep(re"[A-Za-z_]") * re"/" * re"[A-Za-z_]" * rep(re"[A-Za-z_]")

# Complete patterns (ordered by frequency)
# DateTime with timezone
const datetime_tz_extended = year * re"-" * month * re"-" * day * re"[T ]" * 
                             hour * re":" * minute * re":" * second * opt(fraction) * (tz_utc | tz_offset | tz_name)
const datetime_tz_basic = year * month * day * re"T" * hour * minute * second * opt(fraction) * (tz_utc | tz_offset)

# DateTime without timezone
const datetime_extended = year * re"-" * month * re"-" * day * re"[T ]" * 
                         hour * re":" * minute * re":" * second * opt(fraction)
const datetime_basic = year * month * day * re"T" * hour * minute * second * opt(fraction)

# Date only
const date_extended = year * re"-" * month * re"-" * day
const date_basic = year * month * day

# Week dates
const week_extended = year * re"-" * week * re"-" * weekday
const week_basic = year * week * weekday

# Ordinal dates
const ordinal_extended = year * re"-" * ordinal
const ordinal_basic = year * ordinal

# Generate validator functions for each format
@eval $(Automa.generate_buffer_validator(:is_datetime_tz_extended, datetime_tz_extended; goto=true))
@eval $(Automa.generate_buffer_validator(:is_datetime_tz_basic, datetime_tz_basic; goto=true))
@eval $(Automa.generate_buffer_validator(:is_datetime_extended, datetime_extended; goto=true))
@eval $(Automa.generate_buffer_validator(:is_datetime_basic, datetime_basic; goto=true))
@eval $(Automa.generate_buffer_validator(:is_date_extended, date_extended; goto=true))
@eval $(Automa.generate_buffer_validator(:is_date_basic, date_basic; goto=true))
@eval $(Automa.generate_buffer_validator(:is_week_extended, week_extended; goto=true))
@eval $(Automa.generate_buffer_validator(:is_week_basic, week_basic; goto=true))
@eval $(Automa.generate_buffer_validator(:is_ordinal_extended, ordinal_extended; goto=true))
@eval $(Automa.generate_buffer_validator(:is_ordinal_basic, ordinal_basic; goto=true))

# Performance optimization: Pre-check string length to avoid unnecessary validation
@inline function quick_format_check(s::AbstractString)
    len = length(s)
    if len < 8
        return :invalid
    elseif len == 8
        return :date_basic  # yyyymmdd
    elseif len == 10
        return :date_extended  # yyyy-mm-dd
    elseif len == 15
        return :datetime_basic  # yyyymmddTHHMMSS
    elseif len >= 19
        # Could be various datetime formats
        return :datetime_any
    else
        return :other
    end
end

# Cache for fixed timezone offsets to avoid recreating them
const TZ_CACHE = Dict{String, TimeZone}()
const TZ_CACHE_LOCK = ReentrantLock()

function get_cached_timezone(tz_str::AbstractString)
    # Fast path for common cases
    tz_str == "Z" && return tz"UTC"
    
    # Check cache first
    lock(TZ_CACHE_LOCK) do
        get!(TZ_CACHE, tz_str) do
            if startswith(tz_str, "+") || startswith(tz_str, "-")
                # Parse offset
                sign = tz_str[1] == '+' ? 1 : -1
                offset_str = tz_str[2:end]
                if contains(offset_str, ":")
                    hours, minutes = parse.(Int, split(offset_str, ":"))
                else
                    hours = parse(Int, offset_str[1:2])
                    minutes = parse(Int, offset_str[3:4])
                end
                offset_seconds = sign * (hours * 3600 + minutes * 60)
                FixedTimeZone("UTC" * tz_str, offset_seconds)
            else
                # Named timezone
                TimeZone(tz_str)
            end
        end
    end
end

# Optimized parsing functions using manual extraction for common cases
@inline function parse_date_extended_fast(s::AbstractString)
    # For "yyyy-mm-dd" format
    year = parse(Int, @view s[1:4])
    month = parse(Int, @view s[6:7])
    day = parse(Int, @view s[9:10])
    Date(year, month, day)
end

@inline function parse_date_basic_fast(s::AbstractString)
    # For "yyyymmdd" format
    year = parse(Int, @view s[1:4])
    month = parse(Int, @view s[5:6])
    day = parse(Int, @view s[7:8])
    Date(year, month, day)
end

"""
    parse_iso8601(s::AbstractString; warn::Bool=true) -> Union{ZonedDateTime, DateTime, Date, String}

Parse an ISO 8601 formatted string into the appropriate Julia type.
Returns the original string if the format is not recognized.

# Arguments
- `warn::Bool=true`: Whether to emit warnings when parsing fails
"""
function parse_iso8601(s::AbstractString; warn::Bool=true)
    # Quick length-based pre-check
    hint = quick_format_check(s)
    
    if hint == :invalid
        warn && @warn "Unable to parse as ISO 8601: string too short" input=s
        return String(s)
    end
    
    # Try most likely formats first based on length
    format = nothing
    
    if hint == :date_basic && is_date_basic(s) === nothing
        format = :date_basic
    elseif hint == :date_extended && is_date_extended(s) === nothing
        format = :date_extended
    elseif hint == :datetime_basic && is_datetime_basic(s) === nothing
        format = :datetime_basic
    else
        # Full format detection
        format = if is_datetime_tz_extended(s) === nothing
            :datetime_tz_extended
        elseif is_datetime_tz_basic(s) === nothing
            :datetime_tz_basic
        elseif is_datetime_extended(s) === nothing
            :datetime_extended
        elseif is_datetime_basic(s) === nothing
            :datetime_basic
        elseif is_date_extended(s) === nothing
            :date_extended
        elseif is_date_basic(s) === nothing
            :date_basic
        elseif is_week_extended(s) === nothing
            :week_extended
        elseif is_week_basic(s) === nothing
            :week_basic
        elseif is_ordinal_extended(s) === nothing
            :ordinal_extended
        elseif is_ordinal_basic(s) === nothing
            :ordinal_basic
        else
            nothing
        end
    end
    
    if format === nothing
        warn && @warn "Unable to parse as ISO 8601: format not recognized" input=s
        return String(s)
    end
    
    try
        return parse_by_format(s, format)
    catch e
        warn && @warn "Unable to parse as ISO 8601: parsing failed" input=s format=format exception=e
        return String(s)
    end
end

function parse_by_format(s::AbstractString, format::Symbol)
    if format == :datetime_tz_extended || format == :datetime_tz_basic
        return parse_datetime_with_timezone(s, format)
    elseif format == :datetime_extended || format == :datetime_basic
        return parse_datetime_without_timezone(s, format)
    elseif format == :date_extended
        # Use fast path for simple cases
        return length(s) == 10 ? parse_date_extended_fast(s) : Date(s, dateformat"yyyy-mm-dd")
    elseif format == :date_basic
        # Use fast path for simple cases
        return length(s) == 8 ? parse_date_basic_fast(s) : Date(s, dateformat"yyyymmdd")
    elseif format == :week_extended || format == :week_basic
        return parse_week_date(s, format)
    elseif format == :ordinal_extended || format == :ordinal_basic
        return parse_ordinal_date(s, format)
    else
        return String(s)
    end
end

# Pre-compiled regex for timezone extraction
const TZ_REGEX = r"(Z|[+-]\d{2}:?\d{2}|[A-Za-z_]+/[A-Za-z_]+)$"

function parse_datetime_with_timezone(s::AbstractString, format::Symbol)
    # Extract timezone part
    tz_match = match(TZ_REGEX, s)
    if tz_match === nothing
        throw(ArgumentError("No timezone found"))
    end
    
    tz_str = tz_match.captures[1]
    dt_str = @view s[1:tz_match.offset-1]
    
    # Parse the datetime part
    dt = if format == :datetime_tz_extended
        # Try most common format first
        try
            DateTime(dt_str, dateformat"yyyy-mm-ddTHH:MM:SS")
        catch
            # Try with fractional seconds
            if occursin(".", dt_str)
                DateTime(dt_str, dateformat"yyyy-mm-ddTHH:MM:SS.s")
            else
                # Try with space separator
                DateTime(dt_str, dateformat"yyyy-mm-dd HH:MM:SS")
            end
        end
    else  # basic format
        # Handle fractional seconds
        if occursin(".", dt_str)
            dot_pos = findfirst('.', dt_str)
            base_str = @view dt_str[1:dot_pos-1]
            frac_str = @view dt_str[dot_pos+1:end]
            base_dt = DateTime(base_str, dateformat"yyyymmddTHHMMSS")
            frac = parse(Float64, "0." * frac_str)
            base_dt + Millisecond(round(Int, frac * 1000))
        else
            DateTime(dt_str, dateformat"yyyymmddTHHMMSS")
        end
    end
    
    # Use cached timezone
    tz = get_cached_timezone(tz_str)
    
    return ZonedDateTime(dt, tz)
end

# Pre-compiled date formats
const DT_EXTENDED_T = dateformat"yyyy-mm-ddTHH:MM:SS"
const DT_EXTENDED_T_FRAC = dateformat"yyyy-mm-ddTHH:MM:SS.s"
const DT_EXTENDED_SPACE = dateformat"yyyy-mm-dd HH:MM:SS"
const DT_EXTENDED_SPACE_FRAC = dateformat"yyyy-mm-dd HH:MM:SS.s"
const DT_BASIC = dateformat"yyyymmddTHHMMSS"

function parse_datetime_without_timezone(s::AbstractString, format::Symbol)
    if format == :datetime_extended
        # Try most common format first
        try
            DateTime(s, DT_EXTENDED_T)
        catch
            if occursin(".", s)
                try
                    DateTime(s, DT_EXTENDED_T_FRAC)
                catch
                    DateTime(s, DT_EXTENDED_SPACE_FRAC)
                end
            else
                DateTime(s, DT_EXTENDED_SPACE)
            end
        end
    else  # basic format
        if occursin(".", s)
            dot_pos = findfirst('.', s)
            base_str = @view s[1:dot_pos-1]
            frac_str = @view s[dot_pos+1:end]
            base_dt = DateTime(base_str, DT_BASIC)
            frac = parse(Float64, "0." * frac_str)
            base_dt + Millisecond(round(Int, frac * 1000))
        else
            DateTime(s, DT_BASIC)
        end
    end
end

function parse_week_date(s::AbstractString, format::Symbol)
    if format == :week_extended
        # Manual extraction for performance
        year = parse(Int, @view s[1:4])
        week = parse(Int, @view s[7:8])
        dayofweek = parse(Int, @view s[10:10])
    else  # basic format
        year = parse(Int, @view s[1:4])
        week = parse(Int, @view s[6:7])
        dayofweek = parse(Int, @view s[8:8])
    end
    
    # Calculate the date
    # First day of year
    jan1 = Date(year, 1, 1)
    # Find the Monday of week 1
    dow_jan1 = dayofweek(jan1)
    days_to_monday = dow_jan1 == 1 ? 0 : 8 - dow_jan1
    week1_monday = jan1 + Day(days_to_monday)
    
    # Calculate the target date
    target_date = week1_monday + Week(week - 1) + Day(dayofweek - 1)
    
    return target_date
end

function parse_ordinal_date(s::AbstractString, format::Symbol)
    if format == :ordinal_extended
        year = parse(Int, @view s[1:4])
        dayofyear = parse(Int, @view s[6:8])
    else  # basic format
        year = parse(Int, @view s[1:4])
        dayofyear = parse(Int, @view s[5:7])
    end
    
    return Date(year) + Day(dayofyear - 1)
end

# Helper function to check if parsing was successful
function is_valid_iso8601(s::AbstractString)
    result = parse_iso8601(s, warn=false)
    return !(result isa String && result == s)
end

# Additional helper functions for convenience
matches_iso8601_format(s::AbstractString, format::Symbol) = begin
    validator = Symbol("is_", format)
    getfield(@__MODULE__, validator)(s) === nothing
end

end # module TimeParsing