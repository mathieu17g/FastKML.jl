# Eager vs lazy parsing

FastKML.jl offers two read modes plus a dedicated tabular extraction
path, each making a different cost/completeness trade-off:

| Mode                                       | What you get                                                                       |
| ------------------------------------------ | ---------------------------------------------------------------------------------- |
| `read(path, KMLFile)`                      | Full struct hierarchy — every KML element materialized as a typed Julia object     |
| `read(path, LazyKMLFile)`                  | An `XML.LazyNode` tree — no parsing into Julia structs until you walk it           |
| `DataFrame(path)` / `PlacemarkTable(path)` | Fast extraction over the lazy tree — only `name`, `description`, `geometry`        |

This page documents the **most surprising** practical consequence of
that split: `ExtendedData` is **only populated on the eager path**.

## What `ExtendedData` carries

A KML `<ExtendedData>` element holds metadata that the spec-level
geometry doesn't directly capture: custom fields, schema-typed arrays,
per-Track auxiliary data, etc. It can appear at two levels:

- **`Placemark.ExtendedData`** — standard KML.
- **`gx_Track.ExtendedData`** — Google extension. Used by `<gx:Track>`
  to carry per-coord arrays (heart rate, cadence, power, …) via
  `<SchemaData>` + `<gx:SimpleArrayData>`.

## Eager path — full materialization

`read(path, KMLFile)` walks the entire tree and instantiates every
element, including `ExtendedData` at every level:

```julia
using FastKML

file = read("track.kml", KMLFile)
pm   = first(FastKML.Utils.find_placemarks(file))

# Standard KML, populated if the source has it
pm.ExtendedData

# Google extension: gx_Track carries its own ExtendedData
track = pm.Geometry::FastKML.gx_Track
track.ExtendedData                       # populated
sd = track.ExtendedData.children[1]      # SchemaData
sd.gx_SimpleArrayDatas                   # Vector{gx_SimpleArrayData}
sd.gx_SimpleArrayDatas[1].gx_value       # Vector{String} — one value per Track point
```

## Lazy DataFrame path — narrow extraction

`DataFrame(path)` (and the underlying `PlacemarkTable`) deliberately
skip `ExtendedData` to keep extraction fast and the table narrow:

```julia
using FastKML, DataFrames

df = DataFrame("track.kml")              # 3 columns: name, description, geometry
track = df.geometry[1]::FastKML.gx_Track
track.ExtendedData                       # === nothing
```

The returned `gx_Track` has its `when` and `gx_coord` fields populated,
but `ExtendedData`, `Model`, `Icon`, and `gx_angles` are left at default
(`nothing`). The `Placemark.ExtendedData` field isn't surfaced either,
because `PlacemarkTable`'s schema is fixed at `(name, description,
geometry)` — extra Placemark fields don't become extra columns.

The same pattern holds for any geometry type, not just `gx_Track`:

```julia
df = DataFrame("placemarks.kml")
df.geometry[1]                           # Point, LineString, Polygon, …
# `Placemark.ExtendedData` is not in the table; the geometry itself
# carries no ExtendedData since standard geometries don't have one.
```

## Manual lazy walk — full control

`read(path, LazyKMLFile)` returns an `XML.LazyNode` tree without parsing
anything into Julia structs. You can walk it yourself and pick out only
the elements you care about — `ExtendedData` included — without paying
the cost of materializing the rest of the file:

```julia
using FastKML
import XML

lazy = read("track.kml", LazyKMLFile)

# Walk the tree manually; call `FastKML.object(node)` to materialize
# any sub-tree as a typed Julia value when you reach a region of interest.
```

This path is useful for very large files where you need a few specific
fields beyond the canonical three columns and don't want to pay for full
materialization.

## When to choose which

| Situation                                                                                  | Use                              |
| ------------------------------------------------------------------------------------------ | -------------------------------- |
| Geometry-only extraction, into a DataFrame                                                 | `DataFrame(path)`                |
| You need `ExtendedData` (custom fields, schema arrays, per-Track aux data, …)              | `read(path, KMLFile)` — eager    |
| Custom traversal — pick a few extra fields out of a huge file                              | `read(path, LazyKMLFile)`        |

If you started with `DataFrame(path)` and later realize you need
`ExtendedData`, just re-read the file as `KMLFile`. The eager path
returns a typed `gx_Track` (or `Polygon`, `LineString`, …) with
`.ExtendedData` already populated — no need to walk the source XML by
hand.
