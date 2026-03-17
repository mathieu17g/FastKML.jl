module IO

export _read_kmz_file_from_path_error_hinter, KMZ_KMxFileType, _read_file_from_path, _read_lazy_file_from_path

# Don't import read, write, parse - just extend them directly
using Base: splitext, lowercase, hasmethod, error, stdout, ErrorException, occursin, 
            printstyled, println
import XML
import ..Types: KMLFile, LazyKMLFile, KMLElement
import ..XMLParsing: parse_kmlfile
import ..XMLSerialization: Node

# ──────────────────────────────────────────────────────────────────────────────
#  KMx File Types
# ──────────────────────────────────────────────────────────────────────────────
abstract type KMxFileType end
struct KML_KMxFileType <: KMxFileType end
struct KMZ_KMxFileType <: KMxFileType end

# ──────────────────────────────────────────────────────────────────────────────
#  Writable union for XML.write
# ──────────────────────────────────────────────────────────────────────────────
const Writable = Union{KMLFile,KMLElement,XML.Node}

# ──────────────────────────────────────────────────────────────────────────────
#  KMLFile reading - materializes all KML objects
# ──────────────────────────────────────────────────────────────────────────────

# Read from any IO stream - use Base.IO to refer to the type
function Base.read(io::Base.IO, ::Type{KMLFile})
    return XML.read(io, XML.Node) |> parse_kmlfile
end

# Internal helper for KMLFile reading from file path
function _read_file_from_path(::KML_KMxFileType, path::AbstractString)
    return XML.read(path, XML.Node) |> parse_kmlfile
end

# Read from KML or KMZ file path
function Base.read(path::AbstractString, ::Type{KMLFile})
    file_ext = lowercase(splitext(path)[2])
    if file_ext == ".kmz"
        # Check if extension is loaded
        if !hasmethod(_read_file_from_path, Tuple{KMZ_KMxFileType, AbstractString})
            error("KMZ support requires the KMLZipArchivesExt extension. Please load ZipArchives.jl first.")
        end
        return _read_file_from_path(KMZ_KMxFileType(), path)
    elseif file_ext == ".kml"
        return _read_file_from_path(KML_KMxFileType(), path)
    else
        error("Unsupported file extension: $file_ext. Only .kml and .kmz are supported.")
    end
end

# Parse KMLFile from string
Base.parse(::Type{KMLFile}, s::AbstractString) = parse_kmlfile(XML.parse(s, XML.Node))

# ─────────────────────────────────────────────────────────────────────────────
#  LazyKMLFile reading - just store the XML without materializing KML objects
# ─────────────────────────────────────────────────────────────────────────────

# Read LazyKMLFile from IO stream
function Base.read(io::Base.IO, ::Type{LazyKMLFile})
    return XML.read(io, XML.LazyNode) |> LazyKMLFile
end

# Internal helper for LazyKMLFile reading from file path
function _read_lazy_file_from_path(::KML_KMxFileType, path::AbstractString)
    doc = XML.read(path, XML.LazyNode)
    return LazyKMLFile(doc)
end

# Read LazyKMLFile from file path
function Base.read(path::AbstractString, ::Type{LazyKMLFile})
    file_ext = lowercase(splitext(path)[2])
    if file_ext == ".kmz"
        # Check if extension is loaded
        if !hasmethod(_read_lazy_file_from_path, Tuple{KMZ_KMxFileType, AbstractString})
            error("KMZ support for LazyKMLFile requires the KMLZipArchivesExt extension. Please load ZipArchives.jl first.")
        end
        return _read_lazy_file_from_path(KMZ_KMxFileType(), path)
    elseif file_ext == ".kml"
        return _read_lazy_file_from_path(KML_KMxFileType(), path)
    else
        error("Unsupported file extension: $file_ext. Only .kml and .kmz are supported.")
    end
end

# Parse LazyKMLFile from string
Base.parse(::Type{LazyKMLFile}, s::AbstractString) = LazyKMLFile(XML.parse(s, XML.LazyNode))

# ─────────────────────────────────────────────────────────────────────────────
#  Write back out (XML.write)
# ─────────────────────────────────────────────────────────────────────────────

function Base.write(io::Base.IO, o::Writable; kw...)
    XML.write(io, Node(o); kw...)
end

function Base.write(path::AbstractString, o::Writable; kw...)
    XML.write(path, Node(o); kw...)
end

Base.write(o::Writable; kw...) = Base.write(stdout, o; kw...)

# ─────────────────────────────────────────────────────────────────────────────
#  KMZ reading error hinter
# ─────────────────────────────────────────────────────────────────────────────

function _read_kmz_file_from_path_error_hinter(io, exc, argtypes, kwargs)
    # Check if this is a KMZ-related error
    if exc isa ErrorException && occursin("KMZ support", exc.msg)
        printstyled("\nKMZ support not available.\n"; color = :yellow, bold = true)
        printstyled("  - To enable KMZ support, you need to install and load the ZipArchives package:\n"; color = :yellow)
        println("    In the Julia REPL: ")
        printstyled("      1. "; color = :cyan)
        println("`using Pkg`")
        printstyled("      2. "; color = :cyan)
        println("`Pkg.add(\"ZipArchives\")` (if not already installed)")
        printstyled("      3. "; color = :cyan)
        println("`using ZipArchives` (before `using FastKML` or ensure it's in your project environment)")
        printstyled("  - If you don't need KMZ support, this warning can be ignored.\n"; color = :yellow)
    end
end

end # module IO