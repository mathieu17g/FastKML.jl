<h1 align="center">FastKML.jl</h1>

**A high-performance KML/KMZ reader and writer for Julia.**

FastKML.jl parses Google Earth's [KML format](https://developers.google.com/kml/documentation/kmlreference) into native Julia structs, and writes them back out. It is derived from work originally proposed as [`KML.jl#14`](https://github.com/JuliaComputing/KML.jl/pull/14), now a standalone package: `KML.jl` continues on its own as a deliberately lightweight library, while FastKML.jl hosts the performance work and extra integrations that were out of scope upstream. It is built on top of [`XML.jl`](https://github.com/JuliaData/XML.jl) — whose eager and lazy XML node representations are what make `KMLFile` and `LazyKMLFile` possible — with:

- An [`Automa.jl`](https://github.com/BioJulia/Automa.jl)-based coordinate parser.
- Lenient handling of non-conformant inputs — files produced by KMLer, MapGuide and similar generators (where tuples are joined by commas rather than the spec-mandated whitespace) are parsed correctly. See the [Coordinate parsing](docs/src/coordinate_parsing.md) chapter for details.
- A `LazyKMLFile` mode (powered by `XML.LazyNode`) that defers materialization for large files.
- KMZ (zipped KML) support via a `ZipArchives` weak-dependency extension.
- Multi-layer awareness (`Document` / `Folder` introspection), with a `layer = :all` mode that reads every layer in one pass.
- A [Tables.jl](https://github.com/JuliaData/Tables.jl) interface over Placemarks, plus opt-in `DataFrames`, `GeoInterface`, and `Makie` extensions.
- Times read as Julia values: `ZonedDateTime`, `DateTime`, `Date`, and `PartialDate` for a year or a month.
- Problems in a file reported as warnings, once per kind, without stopping the read.

<br>

## Installation

FastKML.jl is not in the General registry yet. Install it from its repository:

```julia
using Pkg
Pkg.add(url = "https://github.com/mathieu17g/FastKML.jl")
```

<br>

## Quickstart

### Reading

```julia
using FastKML, Downloads

path = Downloads.download("https://developers.google.com/kml/documentation/KML_Samples.kml")

file = read(path, KMLFile)             # fully materialized
lazy = read(path, LazyKMLFile)         # XML kept lazy, parsed on demand
```

For KMZ files, load `ZipArchives` first:

```julia
using ZipArchives, FastKML

file = read("archive.kmz", KMLFile)
```

### Writing

```julia
FastKML.write(filename::AbstractString, kml_file)  # write to file
FastKML.write(io::IO, kml_file)                    # write to an IO stream
FastKML.write(kml_file)                            # write to stdout
```

### Building a document programmatically

```julia
using FastKML, StaticArrays

file = KMLFile(
    Document(
        Features = [
            Placemark(
                name = "Washington, D.C.",
                Geometry = Point(coordinates = SVector(-77.0369, 38.9072)),
            ),
        ],
    ),
)
```

```xml
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document>
    <Placemark>
      <name>Washington, D.C.</name>
      <Point>
        <coordinates>-77.0369,38.9072</coordinates>
      </Point>
    </Placemark>
  </Document>
</kml>
```

### With XML.jl

XML.jl exports a `Document` too: the node type of a whole XML document. After `using FastKML, XML`, import FastKML's `Document`, the KML element, by name. `children` needs nothing: FastKML adds its methods to `XML.children`, which works on KML objects and on XML nodes alike.

```julia
using FastKML, XML
using FastKML: Document

file = read(path, KMLFile)
doc = only(children(file))
doc isa Document   # true
```

<br>

## Tables, DataFrames, GeoInterface

A `KMLFile` (or `LazyKMLFile`) exposes its Placemarks as a Tables.jl-compatible table via `PlacemarkTable`:

```julia
using FastKML, DataFrames

df = DataFrame(read("cities.kml", LazyKMLFile))
```

Multi-layer files (more than one `Document`/`Folder`) can be inspected and selected. Without a `layer`, a table reads the first layer, with a warning. `layer = :all` reads every layer in one pass, and tags each row with `layer_idx` and `layer_name`:

```julia
list_layers(file)        # detailed listing
get_layer_names(file)    # Vector{String}
get_num_layers(file)

DataFrame(file; layer = "Placemarks")   # by name, or by number
DataFrame(file; layer = :all)           # every layer
```

With `GeoInterface` loaded, geometry types implement the [GeoInterface.jl](https://github.com/JuliaGeo/GeoInterface.jl) traits, so they interoperate with the broader Julia geospatial ecosystem (plotting via Makie, conversion to GeometryBasics, spatial joins, etc.). `GeoInterface.crs` gives `EPSG:4326`, WGS 84 with the longitude first, as the KML standard defines.

<br>

## KML Objects ↔ Julia structs

FastKML follows the same struct-per-element design pioneered by [`KML.jl`](https://github.com/JuliaComputing/KML.jl), so it can be used intuitively alongside [Google's KML Reference](https://developers.google.com/kml/documentation/kmlreference):

1. Every `Object` is constructed with keyword arguments only.
2. Keywords are the associated XML attributes and child elements.
   - E.g. `pt = Point(id="mypoint", coordinates=SVector(0.0, 1.0))` sets the `id` attribute and `coordinates` child element.
3. Every keyword has a default value (most often `nothing`), and fields can be set after construction.
   - E.g. `pt.coordinates = SVector(2.0, 3.0)`.
4. If a child element is itself an `Object`, the keyword matches the type name.
   - E.g. `pl = Placemark(); pl.Geometry = Point()`. A `Placemark` can hold any `Geometry` (abstract type); `Point` is one of its subtypes.
5. Some `Object`s can hold several children of the same type. Fields with plural names expect a `Vector`.
   - E.g. `mg = MultiGeometry(); mg.Geometries = [Point(), Polygon()]`.
6. Coordinates are `SVector{2,Float64}` or `SVector{3,Float64}` (aliased as `Coord2` and `Coord3`).
7. Enum types live in `FastKML.Enums`, but you rarely build them directly — a string is converted, and an invalid one gives an error that lists the valid values:
   ```julia
   julia> pt.altitudeMode = "clamptoground"
   ERROR: altitudeMode must be one of ("clampToGround", "relativeToGround", "absolute"), but got original value: 'clamptoground'
   ```
   In a file, such a value is left out, with a warning.
8. Google extensions (anything with `gx:` in the name) replace `:` with `_`.
   - E.g. `gx:balloonVisibility` → `gx_balloonVisibility`.
   - One exception: `<gx:altitudeMode>` shares the place of `<altitudeMode>` in KML 2.2, and its field, `altitudeMode`, which takes an `Enums.altitudeMode` or an `Enums.gx_altitudeMode`.
9. Times (`<when>`, `<begin>`, `<end>`) are a `ZonedDateTime`, a `DateTime` without a time zone, a `Date`, or a `PartialDate` for a year or a year and a month, such as `1997-07`: `dates(d)` gives the days it covers. A time that FastKML cannot read stays text, with a warning.
   - To place a time `t` in a `PartialDate`, compare its day: `Date(t) ∈ dates(d)`, or `first(dates(b)) ≤ Date(t) ≤ last(dates(e))` for a span from `b` to `e`. A `DateTime` compared with a `Date` stands for its midnight, and a `ZonedDateTime` does not compare with one.

<br>

---

#### For a concrete example, examine the fields of a `FastKML.Document`:

```
Fields
≡≡≡≡≡≡

id                   :: Union{Nothing, String}
targetId             :: Union{Nothing, String}
name                 :: Union{Nothing, String}
visibility           :: Union{Nothing, Bool}
open                 :: Union{Nothing, Bool}
atom_author          :: Union{Nothing, AtomAuthor}
atom_link            :: Union{Nothing, AtomLink}
address              :: Union{Nothing, String}
xal_AddressDetails   :: Union{Nothing, String}
phoneNumber          :: Union{Nothing, String}
Snippet              :: Union{Nothing, Snippet}
description          :: Union{Nothing, String}
AbstractView         :: Union{Nothing, AbstractView}            # Camera or LookAt
TimePrimitive        :: Union{Nothing, TimePrimitive}           # TimeStamp or TimeSpan
styleUrl             :: Union{Nothing, String}
StyleSelectors       :: Union{Nothing, Vector{StyleSelector}}   # Style or StyleMap elements
Region               :: Union{Nothing, Region}
ExtendedData         :: Union{Nothing, ExtendedData}
Metadata             :: Union{Nothing, Metadata}
gx_balloonVisibility :: Union{Nothing, Bool}
gx_rank              :: Union{Nothing, Float64}
Schemas              :: Union{Nothing, Vector{Schema}}          # several Schemas allowed
Features             :: Union{Nothing, Vector{Feature}}         # several Features allowed
```

<br>

## Warnings about a file

A problem in a file, such as an element that FastKML does not know or a value that it cannot convert, does not stop the read: FastKML reports it as a warning and reads the rest.

On Julia 1.11 and later, `read`, `parse`, `write` and `DataFrame` gather the warnings of one kind and give it once when they end, with the number of elements. When the elements differ in the value that the warning shows, it also gives the number of distinct values and the first three. On Julia 1.10, each kind is shown once per session.

<br>

## Limits

- A table (`PlacemarkTable`, `DataFrame`) has the name, the description and the geometry of each placemark. Read from a `LazyKMLFile`, a `gx:Track` keeps its times and coordinates only: [Eager vs lazy parsing](docs/src/eager_vs_lazy.md) lists what each mode keeps.
- An element that FastKML does not model is left out, with a warning.
- Writing gives KML 2.2. An older form that FastKML reads, such as `<color>` in a `<BalloonStyle>`, is written in its KML 2.2 form, and a Feature that has both `<Metadata>` and `<ExtendedData>` is written with its `<ExtendedData>` only, with a warning.
