<h1 align="center">FastKML.jl</h1>

**A high-performance KML/KMZ reader and writer for Julia.**

FastKML.jl parses Google Earth's [KML format](https://developers.google.com/kml/documentation/kmlreference)
into native Julia structs, and writes them back out. It is derived from work
originally proposed as [`KML.jl#14`](https://github.com/JuliaComputing/KML.jl/pull/14),
now a standalone package: `KML.jl` continues on its own as a deliberately
lightweight library, while FastKML.jl hosts the performance work and extra
integrations that were out of scope upstream. It is built on top of
[`XML.jl`](https://github.com/JuliaComputing/XML.jl) — whose eager and lazy XML
node representations are what make `KMLFile` and `LazyKMLFile` possible — with:

- An [`Automa.jl`](https://github.com/BioJulia/Automa.jl)-based coordinate parser.
- Lenient handling of non-conformant inputs — files produced by KMLer,
  MapGuide and similar generators (where tuples are joined by commas
  rather than the spec-mandated whitespace) are parsed correctly. See the
  [Coordinate parsing](docs/src/coordinate_parsing.md) chapter for details.
- A `LazyKMLFile` mode (powered by `XML.LazyNode`) that defers materialization for large files.
- KMZ (zipped KML) support via a `ZipArchives` weak-dependency extension.
- Multi-layer awareness (`Document` / `Folder` introspection).
- A [Tables.jl](https://github.com/JuliaData/Tables.jl) interface over Placemarks,
  plus opt-in `DataFrames`, `GeoInterface`, and `Makie` extensions.

<br>

## Quickstart

### Reading

```julia
using FastKML

path = download("https://developers.google.com/kml/documentation/KML_Samples.kml")

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

<br>

## Tables, DataFrames, GeoInterface

A `KMLFile` (or `LazyKMLFile`) exposes its Placemarks as a Tables.jl-compatible
table via `PlacemarkTable`:

```julia
using FastKML, DataFrames

df = DataFrame(read("cities.kml", LazyKMLFile))
```

Multi-layer files (more than one `Document`/`Folder`) can be inspected and
selected:

```julia
list_layers(file)        # detailed listing
get_layer_names(file)    # Vector{String}
get_num_layers(file)

DataFrame(file; layer = "Cities")
```

Geometry types implement the [GeoInterface.jl](https://github.com/JuliaGeo/GeoInterface.jl)
trait, so they interoperate with the broader Julia geospatial ecosystem
(plotting via Makie, conversion to GeometryBasics, spatial joins, etc.).

<br>

## KML Objects ↔ Julia structs

FastKML follows the same struct-per-element design pioneered by
[`KML.jl`](https://github.com/JuliaComputing/KML.jl), so it can be used
intuitively alongside [Google's KML Reference](https://developers.google.com/kml/documentation/kmlreference):

1. Every `Object` is constructed with keyword arguments only.
2. Keywords are the associated XML attributes and child elements.
   - E.g. `pt = Point(id="mypoint", coordinates=SVector(0.0, 1.0))` sets the
     `id` attribute and `coordinates` child element.
3. Every keyword has a default value (most often `nothing`), and fields can be
   set after construction.
   - E.g. `pt.coordinates = SVector(2.0, 3.0)`.
4. If a child element is itself an `Object`, the keyword matches the type name.
   - E.g. `pl = Placemark(); pl.Geometry = Point()`. A `Placemark` can hold any
     `Geometry` (abstract type); `Point` is one of its subtypes.
5. Some `Object`s can hold several children of the same type. Fields with
   plural names expect a `Vector`.
   - E.g. `mg = MultiGeometry(); mg.Geometries = [Point(), Polygon()]`.
6. Coordinates are `SVector{2,Float64}` or `SVector{3,Float64}` (aliased as
   `Coord2` and `Coord3`).
7. Enum types live in `FastKML.Enums`, but you rarely build them directly —
   conversion is handled and the error messages list the valid values:
   ```julia
   julia> pt.altitudeMode = "clamptoground"
   ERROR: altitudeMode ∉ clampToGround, relativeToGround, absolute
   ```
8. Google extensions (anything with `gx:` in the name) replace `:` with `_`.
   - E.g. `gx:altitudeMode` → `gx_altitudeMode`.

<br>

---

#### For a concrete example, examine the fields of a `FastKML.Document`:

```
Fields
≡≡≡≡≡≡≡≡

id                 :: Union{Nothing, String}
targetId           :: Union{Nothing, String}
name               :: Union{Nothing, String}
visibility         :: Union{Nothing, Bool}
open               :: Union{Nothing, Bool}
atom_author        :: Union{Nothing, String}
atom_link          :: Union{Nothing, String}
address            :: Union{Nothing, String}
xal_AddressDetails :: Union{Nothing, String}
phoneNumber        :: Union{Nothing, String}
Snippet            :: Union{Nothing, FastKML.Snippet}
description        :: Union{Nothing, String}
AbstractView       :: Union{Nothing, FastKML.AbstractView}    # Camera or LookAt
TimePrimitive      :: Union{Nothing, FastKML.TimePrimitive}   # TimeSpan or TimeMap
styleURL           :: Union{Nothing, String}
StyleSelector      :: Union{Nothing, FastKML.StyleSelector}   # Style or StyleMap
region             :: Union{Nothing, FastKML.Region}
ExtendedData       :: Union{Nothing, FastKML.ExtendedData}
Schemas            :: Union{Nothing, Vector{FastKML.Schema}}  # multiple Schemas allowed
Features           :: Union{Nothing, Vector{FastKML.Feature}} # multiple Features allowed
```
