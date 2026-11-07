module TimeParsing

export parse_iso8601

# ─── base deps ────────────────────────────────────────────────────────────────
using Dates, TimeZones, Automa
using ..ContentWarnings: @content_warn

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

# Optimized parsing functions using manual extraction for common cases. A field out of
# range, such as a 30 February, gives the `ArgumentError` that `Date` throws, without the
# cost of an exception: `Date` itself checks its fields by `Dates.validargs`.
@inline function parse_date_extended_fast(s::AbstractString)
    # For "yyyy-mm-dd" format
    year = parse(Int, @view s[1:4])
    month = parse(Int, @view s[6:7])
    day = parse(Int, @view s[9:10])
    date_or_error(year, month, day)
end

@inline function parse_date_basic_fast(s::AbstractString)
    # For "yyyymmdd" format
    year = parse(Int, @view s[1:4])
    month = parse(Int, @view s[5:6])
    day = parse(Int, @view s[7:8])
    date_or_error(year, month, day)
end

function date_or_error(year::Integer, month::Integer, day::Integer)
    err = Dates.validargs(Date, Int64(year), Int64(month), Int64(day))
    return err === nothing ? Date(year, month, day) : err
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
        warn && @content_warn (:iso8601, :too_short) "Unable to parse as ISO 8601: string too short" input=s example=s
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
        warn && @content_warn (:iso8601, :format) "Unable to parse as ISO 8601: format not recognized" input=s example=s
        return String(s)
    end
    
    # A value that no format reads, such as a 30 February, comes back as the error that says
    # why, or as `nothing` when there is none to give, without the cost of an exception.
    value = try
        parse_by_format(s, format)
    catch e
        e   # a time zone that the TimeZones package does not know, for one
    end
    if value isa Exception
        warn && @content_warn (:iso8601, :failed) "Unable to parse as ISO 8601: parsing failed" input=s format=format exception=value example=s
    elseif value === nothing
        warn && @content_warn (:iso8601, :failed) "Unable to parse as ISO 8601: parsing failed" input=s format=format example=s
    else
        return value
    end
    return String(s)
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
    
    # Parse the datetime part. `tryparse` gives `nothing` for a format that does not read
    # it, rather than an exception.
    dt = if format == :datetime_tz_extended
        # Try most common format first
        dt_t = tryparse(DateTime, dt_str, dateformat"yyyy-mm-ddTHH:MM:SS")
        if dt_t !== nothing
            dt_t
        elseif occursin(".", dt_str)
            # Try with fractional seconds
            tryparse(DateTime, dt_str, dateformat"yyyy-mm-ddTHH:MM:SS.s")
        else
            # Try with space separator
            tryparse(DateTime, dt_str, dateformat"yyyy-mm-dd HH:MM:SS")
        end
    else  # basic format
        # Handle fractional seconds
        if occursin(".", dt_str)
            dot_pos = findfirst('.', dt_str)
            base_str = @view dt_str[1:dot_pos-1]
            frac_str = @view dt_str[dot_pos+1:end]
            base_dt = tryparse(DateTime, base_str, dateformat"yyyymmddTHHMMSS")
            frac = parse(Float64, "0." * frac_str)
            base_dt === nothing ? nothing : base_dt + Millisecond(round(Int, frac * 1000))
        else
            tryparse(DateTime, dt_str, dateformat"yyyymmddTHHMMSS")
        end
    end
    dt === nothing && return datetime_error(dt_str, format == :datetime_tz_basic)

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
    # `tryparse` gives `nothing` for a format that does not read `s`, rather than an
    # exception
    dt = if format == :datetime_extended
        # Try most common format first
        dt_t = tryparse(DateTime, s, DT_EXTENDED_T)
        if dt_t !== nothing
            dt_t
        elseif occursin(".", s)
            dt_frac = tryparse(DateTime, s, DT_EXTENDED_T_FRAC)
            dt_frac !== nothing ? dt_frac : tryparse(DateTime, s, DT_EXTENDED_SPACE_FRAC)
        else
            tryparse(DateTime, s, DT_EXTENDED_SPACE)
        end
    else  # basic format
        if occursin(".", s)
            dot_pos = findfirst('.', s)
            base_str = @view s[1:dot_pos-1]
            frac_str = @view s[dot_pos+1:end]
            base_dt = tryparse(DateTime, base_str, DT_BASIC)
            frac = parse(Float64, "0." * frac_str)
            base_dt === nothing ? nothing : base_dt + Millisecond(round(Int, frac * 1000))
        else
            tryparse(DateTime, s, DT_BASIC)
        end
    end
    return dt === nothing ? datetime_error(s, format == :datetime_basic) : dt
end

# Why no format reads a date-time of a valid form, without the cost of an exception: the
# `ArgumentError` that `DateTime` throws for a field out of range, such as a 30 February or
# an hour 25 (`DateTime` itself checks its fields by `Dates.validargs`); one for a fraction
# of second finer than a millisecond, the precision of a `DateTime`, which `Dates` does not
# read; or else `nothing`.
function datetime_error(s::AbstractString, basic::Bool)
    field(a, b) = parse(Int64, @view s[a:b])
    y, m, d = basic ? (field(1, 4), field(5, 6), field(7, 8)) : (field(1, 4), field(6, 7), field(9, 10))
    H, M, S = basic ? (field(10, 11), field(12, 13), field(14, 15)) : (field(12, 13), field(15, 16), field(18, 19))
    err = Dates.validargs(DateTime, y, m, d, H, M, S, Int64(0))
    err === nothing || return err
    dot = findfirst('.', s)
    dot === nothing && return nothing
    digits = @view s[nextind(s, dot):end]
    # Digits after the third that are not all zeros: finer than a millisecond
    any(!=('0'), Iterators.drop(digits, 3)) || return nothing
    return ArgumentError("Fraction of second .$digits is finer than a millisecond, the precision of DateTime")
end

function parse_week_date(s::AbstractString, format::Symbol)
    # Note: the local for the parsed weekday is named `wday` (not `dayofweek`)
    # to avoid shadowing `Dates.dayofweek`, which is called below — the
    # shadow turned the function call into an Int "call" and broke parsing.
    if format == :week_extended
        year = parse(Int, @view s[1:4])
        week = parse(Int, @view s[7:8])
        wday = parse(Int, @view s[10:10])
    else  # basic format
        year = parse(Int, @view s[1:4])
        week = parse(Int, @view s[6:7])
        wday = parse(Int, @view s[8:8])
    end

    # First day of year, then find the Monday of ISO week 1
    jan1 = Date(year, 1, 1)
    dow_jan1 = dayofweek(jan1)
    days_to_monday = dow_jan1 == 1 ? 0 : 8 - dow_jan1
    week1_monday = jan1 + Day(days_to_monday)

    # Target date
    return week1_monday + Week(week - 1) + Day(wday - 1)
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