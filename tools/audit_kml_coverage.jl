#!/usr/bin/env julia
# audit_kml_coverage.jl — static OGC 2.2 + Google extension coverage audit
#
# Downloads the canonical XSDs, walks every <xs:element> declaration, and
# reports which ones FastKML models in `TAG_TO_TYPE` and which are gaps.
#
# Usage:
#     julia --project=. tools/audit_kml_coverage.jl                # print to stdout
#     julia --project=. tools/audit_kml_coverage.jl out.md         # write to file
#     julia --project=. tools/audit_kml_coverage.jl --refresh      # bypass cache
#
# Caches the XSDs under `tools/.xsd_cache/` so re-runs are offline.

using Dates
using Downloads
using FastKML
import XML

const OGC_XSD_URL = "https://schemas.opengis.net/kml/2.2.0/ogckml22.xsd"
const GOOGLE_XSD_URL = "https://developers.google.com/kml/schema/kml22gx.xsd"
const CACHE_DIR = joinpath(@__DIR__, ".xsd_cache")

# ─── XSD fetch / cache ───────────────────────────────────────────────────────

function fetch_xsd(url::String, filename::String; refresh::Bool=false)::String
    isdir(CACHE_DIR) || mkpath(CACHE_DIR)
    path = joinpath(CACHE_DIR, filename)
    if refresh || !isfile(path)
        @info "Downloading $url"
        Downloads.download(url, path)
    end
    return path
end

# ─── XSD walking ─────────────────────────────────────────────────────────────

"""
Walk the XSD tree and collect every `<xs:element name="...">` declaration.
Returns a Vector of NamedTuples `(name, type, abstract, substitutionGroup)`.
"""
function collect_xsd_elements(root::XML.Node)
    elems = NamedTuple[]
    function walk(n)
        if XML.nodetype(n) === XML.Element
            tag = XML.tag(n)
            attrs = XML.attributes(n)
            if tag == "element" && attrs !== nothing && haskey(attrs, "name")
                push!(elems, (
                    name = attrs["name"],
                    type = get(attrs, "type", ""),
                    abstract = get(attrs, "abstract", "false") == "true",
                    substitutionGroup = get(attrs, "substitutionGroup", ""),
                ))
            end
            for c in XML.children(n)
                walk(c)
            end
        end
    end
    walk(root)
    return elems
end

"""
Walk the XSD tree and classify every named type definition.

Returns Dict{String,Symbol} mapping type name to one of:
- `:true_complex` — `<complexType>` with `<sequence>`, `<all>`, `<choice>`,
  or `<complexContent>`. The structured "elements have element children" case.
  Always a FastKML modeling candidate.
- `:simple_content` — `<complexType>` with `<simpleContent>` (a primitive
  extended with attributes, e.g. `<linkSnippet maxLines="3">text</linkSnippet>`).
  Also a FastKML modeling candidate (Snippet, SimpleData, etc.).
- `:simple` — `<simpleType>` (enums + restricted primitives). NOT a
  modeling candidate; these become Julia enums or struct field values.
"""
function collect_xsd_type_kinds(root::XML.Node)::Dict{String,Symbol}
    kinds = Dict{String,Symbol}()
    function walk(n)
        if XML.nodetype(n) === XML.Element
            tag = XML.tag(n)
            attrs = XML.attributes(n)
            if tag == "complexType" && attrs !== nothing && haskey(attrs, "name")
                name = attrs["name"]
                kind = :unknown
                for c in XML.children(n)
                    if XML.nodetype(c) === XML.Element
                        ctag = XML.tag(c)
                        if ctag in ("sequence", "complexContent", "all", "choice")
                            kind = :true_complex
                            break
                        elseif ctag == "simpleContent"
                            kind = :simple_content
                            break
                        end
                    end
                end
                kinds[name] = kind
            elseif tag == "simpleType" && attrs !== nothing && haskey(attrs, "name")
                kinds[attrs["name"]] = :simple
            end
            for c in XML.children(n)
                walk(c)
            end
        end
    end
    walk(root)
    return kinds
end

# Find <schema> root inside the XML document (skipping <?xml ... ?>).
function schema_root(doc::XML.Node)::XML.Node
    for c in XML.children(doc)
        XML.nodetype(c) === XML.Element && return c
    end
    error("no <schema> element in document")
end

# ─── Classification ──────────────────────────────────────────────────────────

"""
An element is a FastKML modeling candidate if its `type` references a kml:
complex type whose definition has element children (`:true_complex`) or a
simpleContent extension (`:simple_content`). Simple-typed elements
(xs:string / int / boolean, or kml: enum / restricted-primitive types) are
leaf field values handled implicitly by struct fields. Abstract elements
(substitution groups) are not directly instantiable.

Returns `(kind::Symbol, candidate::Bool)`.
"""
function classify_element(e::NamedTuple, type_kinds::Dict{String,Symbol})
    e.abstract && return (:abstract, false)
    # OGC and Google XSDs use the `Abstract*` naming convention for
    # substitution-group heads (e.g. `gx:AbstractTourPrimitive`). The XSD
    # doesn't always set `abstract="true"` on these, so use the name as a
    # fallback signal to avoid false-positive "missing" reports.
    startswith(e.name, "Abstract") && return (:abstract, false)
    isempty(e.type) && return (:unknown, false)
    # Accept both kml: (OGC) and gx: (Google ext) qualified type references —
    # the Google XSD uses both. Anything else is an XSD primitive (xs:string,
    # xs:double, …) or an unqualified name resolved against the default
    # namespace, which here is always xs: in OGC files.
    bare = if startswith(e.type, "kml:")
        e.type[5:end]
    elseif startswith(e.type, "gx:")
        e.type[4:end]
    else
        return (:primitive, false)
    end
    kind = get(type_kinds, bare, :external)
    if kind === :true_complex || kind === :simple_content
        return (kind, true)
    end
    return (kind, false)
end

# ─── Coverage diff ───────────────────────────────────────────────────────────

"""
Diff a set of XSD-declared elements against FastKML's TAG_TO_TYPE registry.
The `tag_prefix` is "" for OGC, "gx_" for the Google extension XSD (since
FastKML internally maps `<gx:Track>` to symbol `:gx_Track`).
"""
function coverage_diff(
    xsd_elems::Vector,
    type_kinds::Dict{String,Symbol},
    modeled::Set{String},
    tag_prefix::String,
)
    candidates = NamedTuple[]
    abstracts = NamedTuple[]
    leaves = NamedTuple[]
    seen_candidates = Set{String}()
    seen_abstracts = Set{String}()
    seen_leaves = Set{String}()
    # OGC XSD redeclares some elements (e.g. <Icon> appears with both
    # kml:LinkType and kml:BasicLinkType). Dedupe by name within each bucket
    # so the report doesn't double-count the same logical tag.
    for e in xsd_elems
        kind, is_candidate = classify_element(e, type_kinds)
        if e.abstract
            e.name in seen_abstracts && continue
            push!(seen_abstracts, e.name)
            push!(abstracts, e)
        elseif is_candidate
            e.name in seen_candidates && continue
            push!(seen_candidates, e.name)
            push!(candidates, merge(e, (kind = kind,)))
        else
            e.name in seen_leaves && continue
            push!(seen_leaves, e.name)
            push!(leaves, merge(e, (kind = kind,)))
        end
    end

    found = NamedTuple[]
    missing = NamedTuple[]
    # The prefixed form is the only valid match — `gx:TimeStamp` is a
    # genuinely distinct element from OGC `<TimeStamp>` even though they
    # share the same Type. Don't fall back to the bare name or the audit
    # would falsely credit Google extensions as modeled whenever the OGC
    # variant is registered.
    for e in candidates
        symname = tag_prefix * e.name
        if symname in modeled
            push!(found, e)
        else
            push!(missing, e)
        end
    end

    return (
        candidates = candidates,
        abstracts = abstracts,
        leaves = leaves,
        found = sort(found, by = e -> e.name),
        missing = sort(missing, by = e -> e.name),
    )
end

# ─── Markdown output ─────────────────────────────────────────────────────────

function format_table(rows::Vector{<:NamedTuple}, columns::Vector{Symbol})
    isempty(rows) && return "_(none)_\n"
    out = IOBuffer()
    print(out, "| ", join(string.(columns), " | "), " |\n")
    print(out, "|", repeat("---|", length(columns)), "\n")
    for r in rows
        cells = [haskey(r, c) ? string(getproperty(r, c)) : "" for c in columns]
        # Backtick-wrap non-empty
        cells = [isempty(s) ? "_(empty)_" : "`" * s * "`" for s in cells]
        print(out, "| ", join(cells, " | "), " |\n")
    end
    return String(take!(out))
end

function format_section_diff(diff, label::String)
    out = IOBuffer()
    println(out, "## $label")
    println(out)
    println(out, "**Stats**")
    println(out)
    println(out, "- Element declarations (recursive): $(length(diff.candidates) + length(diff.abstracts) + length(diff.leaves))")
    println(out, "  - Abstract / substitution groups: $(length(diff.abstracts))")
    println(out, "  - Simple-typed leaves (handled as struct fields): $(length(diff.leaves))")
    println(out, "  - Complex-typed candidates: $(length(diff.candidates))")
    println(out, "    - **Modeled in `TAG_TO_TYPE`:** $(length(diff.found))")
    println(out, "    - **Missing:** $(length(diff.missing))")
    println(out)
    println(out, "### Missing complex-typed elements")
    println(out)
    if isempty(diff.missing)
        println(out, "_(none — full coverage of concrete complex elements)_")
    else
        print(out, format_table(diff.missing, [:name, :type, :kind]))
        println(out)
        println(out, "_Note: some elements may be intentionally unmodeled because they're_")
        println(out, "_handled by special parsing paths (e.g. `<outerBoundaryIs>` /_")
        println(out, "_`<innerBoundaryIs>` are routed through `Polygon` boundary fields)._")
    end
    println(out)
    println(out, "### Modeled elements (sanity check)")
    println(out)
    if isempty(diff.found)
        println(out, "_(none)_")
    else
        names = ["`$(e.name)`" for e in diff.found]
        println(out, join(names, ", "))
    end
    println(out)
    return String(take!(out))
end

function generate_report(; refresh::Bool=false)
    ogc_path = fetch_xsd(OGC_XSD_URL, "ogckml22.xsd"; refresh)
    google_path = fetch_xsd(GOOGLE_XSD_URL, "kml22gx.xsd"; refresh)

    ogc_root = schema_root(XML.read(ogc_path, XML.Node))
    google_root = schema_root(XML.read(google_path, XML.Node))

    ogc_elems = collect_xsd_elements(ogc_root)
    google_elems = collect_xsd_elements(google_root)

    # Type-kind classification is per-XSD; the Google XSD imports kml: types
    # so we merge the two maps to resolve cross-namespace references.
    type_kinds = merge(
        collect_xsd_type_kinds(google_root),
        collect_xsd_type_kinds(ogc_root),
    )

    fk_tags = Set(string.(keys(FastKML.TAG_TO_TYPE)))

    ogc_diff = coverage_diff(ogc_elems, type_kinds, fk_tags, "")
    google_diff = coverage_diff(google_elems, type_kinds, fk_tags, "gx_")

    # Tags FastKML registers that the XSDs don't declare — aliases / internals.
    all_xsd_names = Set{String}()
    for e in ogc_elems
        push!(all_xsd_names, e.name)
    end
    for e in google_elems
        push!(all_xsd_names, "gx_" * e.name)
        push!(all_xsd_names, e.name)  # also accept un-prefixed match
    end
    extra_in_fk = sort!(collect(setdiff(fk_tags, all_xsd_names)))

    out = IOBuffer()
    println(out, "# FastKML coverage audit — OGC KML 2.2 + Google extensions")
    println(out)
    println(out, "_Generated $(today()) by `tools/audit_kml_coverage.jl`._")
    println(out)
    println(out, "Sources:")
    println(out, "- OGC: <$OGC_XSD_URL>")
    println(out, "- Google: <$GOOGLE_XSD_URL>")
    println(out)
    println(out, "## Summary")
    println(out)
    println(out, "| Schema | Complex candidates | Modeled | Missing |")
    println(out, "|---|---|---|---|")
    println(out, "| OGC KML 2.2 | $(length(ogc_diff.candidates)) | $(length(ogc_diff.found)) | $(length(ogc_diff.missing)) |")
    println(out, "| Google ext. (gx:) | $(length(google_diff.candidates)) | $(length(google_diff.found)) | $(length(google_diff.missing)) |")
    println(out)
    println(out, "FastKML `TAG_TO_TYPE` entries: **$(length(fk_tags))**")
    println(out)

    print(out, format_section_diff(ogc_diff, "OGC KML 2.2"))
    print(out, format_section_diff(google_diff, "Google extension (gx:)"))

    println(out, "## FastKML registry entries with no XSD counterpart")
    println(out)
    println(out, "These are aliases (e.g. `<Url>` → `Link`), special structural tags, or")
    println(out, "auto-populated names that don't correspond to a single XSD element.")
    println(out)
    if isempty(extra_in_fk)
        println(out, "_(none)_")
    else
        for name in extra_in_fk
            println(out, "- `$name`")
        end
    end
    println(out)

    return String(take!(out))
end

# ─── Entry point ─────────────────────────────────────────────────────────────

function main(args::Vector{String})
    refresh = "--refresh" in args
    out_path = nothing
    for a in args
        a == "--refresh" && continue
        startswith(a, "--") && continue
        out_path = a
    end

    report = generate_report(; refresh)
    if out_path === nothing
        print(report)
    else
        write(out_path, report)
        @info "Report written to $out_path ($(length(report)) bytes)"
    end
end

main(ARGS)
