# FastKML.jl

A high-performance KML/KMZ reader and writer for Julia.

FastKML.jl parses Google Earth's [KML format](https://developers.google.com/kml/documentation/kmlreference)
into native Julia structs, and writes them back out. It is derived from work
originally proposed as [`KML.jl#14`](https://github.com/JuliaComputing/KML.jl/pull/14),
now a standalone package: `KML.jl` continues on its own as a deliberately
lightweight library, while FastKML.jl hosts the performance work and extra
integrations that were out of scope upstream. It is built on top of
[`XML.jl`](https://github.com/JuliaComputing/XML.jl) — whose eager and lazy XML
node representations are what make `KMLFile` and `LazyKMLFile` possible.

## Highlights

- An [`Automa.jl`](https://github.com/BioJulia/Automa.jl)-based coordinate parser.
- Lenient handling of non-conformant inputs — see [Coordinate parsing](coordinate_parsing.md).
- A `LazyKMLFile` mode (powered by `XML.LazyNode`) that defers materialization for large files.
- KMZ (zipped KML) support via a `ZipArchives` weak-dependency extension.
- Multi-layer awareness (`Document` / `Folder` introspection).
- A [Tables.jl](https://github.com/JuliaData/Tables.jl) interface over
  Placemarks, plus opt-in `DataFrames`, `GeoInterface`, and `Makie`
  extensions.

## Installation

```julia
using Pkg
Pkg.add(url = "https://github.com/mathieu17g/FastKML.jl")
```

## Quickstart

```julia
using FastKML

file = read("path/to/file.kml", KMLFile)            # eager
lazy = read("path/to/file.kml", LazyKMLFile)        # deferred
```

For KMZ files, load `ZipArchives` first:

```julia
using ZipArchives, FastKML
file = read("archive.kmz", KMLFile)
```

Build a document programmatically:

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
FastKML.write("dc.kml", file)
```

## Where to go next

- [Coordinate parsing](coordinate_parsing.md) — how FastKML handles
  spec-conformant **and** non-conformant coordinate strings, with examples
  drawn from real-world KML files.
- [Eager vs lazy parsing](eager_vs_lazy.md) — what each parsing mode
  preserves vs skips, with `ExtendedData` (including the gx:Track
  per-coord arrays) as the headline example.
- [API reference](api.md) — the public API exported by `FastKML`.
