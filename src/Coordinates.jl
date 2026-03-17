module Coordinates

export parse_coordinates_automa, coordinate_string, Coord2, Coord3

using StaticArrays
using Automa
using Parsers
import ..Types: Coord2, Coord3

# ──────────────────────────────────────────────────────────────────────────────
# Coordinate string generation (for writing KML)
# ──────────────────────────────────────────────────────────────────────────────

coordinate_string(x::Tuple) = join(x, ',')
coordinate_string(x::StaticArraysCore.SVector) = join(x, ',')
coordinate_string(x::Vector) = join(coordinate_string.(x), '\n')
coordinate_string(::Nothing) = ""
coordinate_string(x::SVector{4, <:Union{Coord2, Coord3}}) = join(coordinate_string.(x), ' ')

# ──────────────────────────────────────────────────────────────────────────────
# Coordinate parsing using Automata.jl
# ──────────────────────────────────────────────────────────────────────────────

# Build the regular expression for coordinate parsing
const coord_number_re = rep1(re"[^\t\n\r ,]+") #? const coord_number_re = rep1(re"[0-9.+\-Ee]+") # Alternative
const coord_delim_re = rep1(re"[\t\n\r ,]+")

const _coord_number_actions = onexit!(onenter!(coord_number_re, :mark), :number)

const _coord_machine_pattern =
    opt(coord_delim_re) * opt(_coord_number_actions * rep(coord_delim_re * _coord_number_actions)) * opt(coord_delim_re)

const COORDINATE_MACHINE = compile(_coord_machine_pattern)

# Action table for the FSM
const PARSE_OPTIONS = Parsers.Options()
const AUTOMA_COORD_ACTIONS = Dict{Symbol,Expr}(
    # save the start position of a number
    :mark => :(current_mark = p),

    # convert the byte slice to Float64 and push!
    :number => quote
        push!(results_vector, Parsers.parse(Float64, view(data_bytes, current_mark:p-1), PARSE_OPTIONS))
    end,
)

# Generate the low-level FSM driver
let ctx = Automa.CodeGenContext(vars = Automa.Variables(data = :data_bytes), generator = :goto)
    eval(quote
        function __core_automa_parser(data_bytes::AbstractVector{UInt8}, results_vector::Vector{Float64})
            current_mark = 0

            $(Automa.generate_init_code(ctx, COORDINATE_MACHINE))

            p_end = sizeof(data_bytes)
            p_eof = p_end

            $(Automa.generate_exec_code(ctx, COORDINATE_MACHINE, AUTOMA_COORD_ACTIONS))

            return cs          # final machine state
        end
    end)
end

"""
    parse_coordinates_automa(txt::AbstractString)

Parse a KML/GeoRSS-style coordinate string and return a vector of
`SVector{3,Float64}` (if the list length is divisible by 3) **or**
`SVector{2,Float64}` (if divisible by 2).

# Examples

```julia
parse_coordinates_automa("0,0") # returns [SVector{2,Float64}(0.0, 0.0)]
parse_coordinates_automa("0,0,0") # returns [SVector{3,Float64}(0.0, 0.0, 0.0)]
parse_coordinates_automa("0,0 1,1") # returns [SVector{2,Float64}(0.0, 0.0), SVector{2,Float64}(1.0, 1.0)]
```
"""
function parse_coordinates_automa(txt::AbstractString)
    parsed_floats = Float64[]
    # sizehint!(parsed_floats, length(txt) ÷ 4)
    # sizehint! does not bring any speedup here
    final_state = __core_automa_parser(codeunits(txt), parsed_floats)
    # --- basic FSM state checks -------------------------------------------------
    if final_state < 0
        error("Coordinate string is malformed (FSM error state $final_state).")
    end
    #? Check below if the FSM ended in a valid state dropping garbage at the end the string
    #? This check is overly strict and is not done for now (May 2025)
    #// if final_state > 0 && !(final_state == COORDINATE_MACHINE.start_state && isempty(txt))
    #//     error("Coordinate string is incomplete or has trailing garbage (FSM state $final_state).")
    #// end

    # --- assemble SVectors ------------------------------------------------------
    len = length(parsed_floats)

    if len == 0
        return SVector{0,Float64}[]
    elseif len % 3 == 0
        n = len ÷ 3
        result = Vector{SVector{3,Float64}}(undef, n)
        @inbounds for i = 1:n
            off = (i - 1) * 3
            result[i] = SVector{3,Float64}(parsed_floats[off+1], parsed_floats[off+2], parsed_floats[off+3])
        end
        return result
    elseif len % 2 == 0
        n = len ÷ 2
        result = Vector{SVector{2,Float64}}(undef, n)
        @inbounds for i = 1:n
            off = (i - 1) * 2
            result[i] = SVector{2,Float64}(parsed_floats[off+1], parsed_floats[off+2])
        end
        return result
    else # len is not 0 and not a multiple of 2 or 3
        if !isempty(txt) && !all(isspace, txt)
            snippet = first(txt, min(50, lastindex(txt)))
            @warn "Parsed $len numbers from \"$snippet…\", which is not a multiple of 2 or 3. Returning empty coordinates." maxlog = 1
        end
        return SVector{0,Float64}[] # Return empty instead of erroring
    end
end

end # module Coordinates