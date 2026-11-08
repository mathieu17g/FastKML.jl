module TimeParsing

export parse_iso8601

# ─── base deps ────────────────────────────────────────────────────────────────
using Dates, TimeZones, Automa
using ..ContentWarnings: @content_warn
using ..Types: PartialDate

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

# A date, a year or a year and a month with a time zone, which `xsd:date`, `xsd:gYear` and
# `xsd:gYearMonth` allow, and which no Julia type holds
const zoned_date = (year | year * re"-" * month | year * re"-" * month * re"-" * day) * (tz_utc | tz_offset)

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
@eval $(Automa.generate_buffer_validator(:is_zoned_date, zoned_date; goto=true))

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

# A year, `yyyy`, or a year and a month, `yyyy-mm` (`xsd:gYear`, `xsd:gYearMonth`), as a
# `PartialDate`. A month out of range gives the `ArgumentError` that `Date` throws, which
# `Dates.validargs` returns without the cost of an exception; any other text, `nothing`.
function read_partial_date(s::AbstractString)
    n = ncodeunits(s)
    isdigit_at(i) = UInt8('0') <= codeunit(s, i) <= UInt8('9')
    (n == 4 || n == 7) && all(isdigit_at, 1:4) || return nothing
    n == 4 && return PartialDate(digits_at(s, 1, 4))
    codeunit(s, 5) == UInt8('-') && isdigit_at(6) && isdigit_at(7) || return nothing
    y, m = digits_at(s, 1, 4), digits_at(s, 6, 7)
    err = Dates.validargs(Date, y, m, Int64(1))
    return err === nothing ? PartialDate(y, m) : err
end

"""
    parse_iso8601(s::AbstractString; warn::Bool=true) -> Union{ZonedDateTime, DateTime, Date, PartialDate, String}

Parse an ISO 8601 formatted string into the appropriate Julia type.
Returns the original string if the format is not recognized.

# Arguments
- `warn::Bool=true`: Whether to emit warnings when parsing fails
"""
function parse_iso8601(s::AbstractString; warn::Bool=true)
    # Quick length-based pre-check
    hint = quick_format_check(s)
    
    if hint == :invalid
        # A year or a year and a month (`xsd:gYear`, `xsd:gYearMonth`) is shorter than any
        # other form
        value = read_partial_date(s)
        value isa PartialDate && return value
        if value isa Exception
            warn && @content_warn (:iso8601, :failed) "Unable to parse as ISO 8601: parsing failed" input=s format=:partial_date exception=value example=s
        elseif is_zoned_date(s) === nothing
            warn && @content_warn (:iso8601, :zoned_date) "Unable to parse as ISO 8601: time zone on a date not read" input=s example=s
        else
            warn && @content_warn (:iso8601, :too_short) "Unable to parse as ISO 8601: string too short" input=s example=s
        end
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
        if is_zoned_date(s) === nothing
            warn && @content_warn (:iso8601, :zoned_date) "Unable to parse as ISO 8601: time zone on a date not read" input=s example=s
        else
            warn && @content_warn (:iso8601, :format) "Unable to parse as ISO 8601: format not recognized" input=s example=s
        end
        return String(s)
    end
    
    # A value that no format reads, such as a 30 February, comes back as the error that says
    # why, without the cost of an exception.
    value = try
        parse_by_format(s, format)
    catch e
        e   # a time zone that the TimeZones package does not know, for one
    end
    value isa Exception || return value
    warn && @content_warn (:iso8601, :failed) "Unable to parse as ISO 8601: parsing failed" input=s format=format exception=value example=s
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
    
    tz_str = something(tz_match.captures[1])
    dt = read_datetime(@view(s[1:tz_match.offset-1]), format == :datetime_tz_basic)
    dt isa DateTime || return dt

    # Use cached timezone
    tz = get_cached_timezone(tz_str)
    
    return ZonedDateTime(dt, tz)
end

parse_datetime_without_timezone(s::AbstractString, format::Symbol) =
    read_datetime(s, format == :datetime_basic)

# A date-time without its time zone, of a form that a validator found, so that each field
# is made of digits at its place: `yyyymmddTHHMMSS`, or `yyyy-mm-ddTHH:MM:SS` with a T or a
# space, then maybe a fraction of second. The fraction is rounded to the nearest
# millisecond, the precision of a `DateTime`: the fourth digit decides, 5 or more rounding
# up, and 1000 carries to the next second. A field out of range, such as a 30 February, an
# hour 25 or 24:00:00 with a fraction, gives the `ArgumentError` that `DateTime` throws,
# which `Dates.validargs` returns without the cost of an exception.
function read_datetime(s::AbstractString, basic::Bool)
    y, m, d = basic ? (digits_at(s, 1, 4), digits_at(s, 5, 6), digits_at(s, 7, 8)) :
                      (digits_at(s, 1, 4), digits_at(s, 6, 7), digits_at(s, 9, 10))
    H, M, S = basic ? (digits_at(s, 10, 11), digits_at(s, 12, 13), digits_at(s, 14, 15)) :
                      (digits_at(s, 12, 13), digits_at(s, 15, 16), digits_at(s, 18, 19))
    ms = fraction_milliseconds(s, basic ? 17 : 21)
    err = Dates.validargs(DateTime, y, m, d, H, M, S, min(ms, Int64(999)))
    err === nothing || return err
    return DateTime(y, m, d, H, M, S) + Millisecond(ms)
end

# The number that the digits of `s` from `a` to `b` write
@inline function digits_at(s::AbstractString, a::Int, b::Int)
    v = Int64(0)
    for i in a:b
        v = 10v + Int64(codeunit(s, i) - UInt8('0'))
    end
    return v
end

# The fraction of second whose digits run from `i` to the end of `s`, rounded to the nearest
# millisecond; 0 without a fraction
@inline function fraction_milliseconds(s::AbstractString, i::Int)
    n = ncodeunits(s)
    ms = Int64(0)
    i > n && return ms
    for j in i:i+2
        ms = 10ms + (j <= n ? Int64(codeunit(s, j) - UInt8('0')) : Int64(0))
    end
    return i + 3 <= n && codeunit(s, i + 3) >= UInt8('5') ? ms + 1 : ms
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