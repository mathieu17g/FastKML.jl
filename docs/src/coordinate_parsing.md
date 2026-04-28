# Coordinate parsing

FastKML's coordinate parser is intentionally **lenient**: any run of
whitespace or commas is treated as a single delimiter, and the resulting
flat sequence of numbers is grouped into 3-tuples (preferred) or 2-tuples.
This page explains what the KML specification requires, where real-world
files deviate from it, and how FastKML chooses to recover useful geometry
from non-conformant inputs.

## What the spec says

The KML reference is explicit on the format expected inside a
`<coordinates>` element:

> Specifies one or more coordinate tuples, with each tuple consisting of
> decimal values for geographic longitude, latitude, and altitude. The
> altitude component is optional. **The coordinate separator is a comma,
> but tuple separator is a single space.**
>
> — [Google KML Reference](https://developers.google.com/kml/documentation/kmlreference)

So a strictly conformant payload looks like:

```xml
<coordinates>
  -122.0822035425683,37.42228990140251,0
  -122.0822035425683,37.42230498731635,0
  -122.0822035425683,37.42231998732351,0
</coordinates>
```

Newlines (or any whitespace) between tuples; commas only inside a tuple.

## What real-world files do

A surprisingly large fraction of KML files generated in the wild deviate
from this format in the same way: they emit comma-only delimiters with
**no whitespace at all between tuples**. Concrete examples we have
encountered:

- **`USEDO.kmz`** (European Soil Database, ESDAC) — produced by KMLer.
  The first feature alone packs 421 vertices into a single `<coordinates>`
  payload of the form `lon1,lat1,0,lon2,lat2,0,…,lonN,latN,0` on a single
  line.
- **MapGuide Open Source** — see the upstream
  [bug #1096](https://trac.osgeo.org/mapguide/ticket/1096) tracking the
  generated `<coordinates>` not following the KML spec.

Strict spec-following parsers handle these inputs as a single malformed
tuple. Google Earth and (older versions of) GDAL fall in this camp. The
practical outcome is data loss: a multi-vertex polygon ring becomes a
degenerate one-point ring.

## What FastKML does

FastKML treats the inter-tuple separator (whitespace) and the intra-tuple
separator (comma) as one and the same delimiter class:

```julia
# src/Coordinates.jl
const coord_number_re = rep1(re"[^\t\n\r ,]+")
const coord_delim_re  = rep1(re"[\t\n\r ,]+")
```

The Automa-generated state machine extracts every number it sees and pushes
it into a flat `Vector{Float64}`. Once the input is exhausted, the
collected floats are grouped into `SVector{3,Float64}` if the count is a
multiple of three (the preferred case for KML, where the third component
is altitude), otherwise into `SVector{2,Float64}` if the count is a
multiple of two. Anything else triggers a one-shot warning and an empty
result rather than a hard error.

This is the same leniency policy adopted by NASA World Wind's
[`KMLCoordinateTokenizer`](https://worldwind.arc.nasa.gov/java/v2.1.0/javadoc/gov/nasa/worldwind/ogc/kml/KMLCoordinateTokenizer.html):

> "This tokenizer attempts to be lenient with whitespace handling. **If a
> tuple ends with a comma, the tokenizer considers the next token in the
> input stream to be part of the same coordinate**, not the start of a new
> coordinate."

## Examples

```julia
using FastKML.Coordinates: parse_coordinates_automa

# spec-conformant
parse_coordinates_automa("0,0")
# → 1-element Vector{SVector{2,Float64}}: [SVector(0.0, 0.0)]

parse_coordinates_automa("0,0,0")
# → 1-element Vector{SVector{3,Float64}}: [SVector(0.0, 0.0, 0.0)]

parse_coordinates_automa("1,2,3 4,5,6")
# → 2-element Vector{SVector{3,Float64}}:
#   [SVector(1.0, 2.0, 3.0), SVector(4.0, 5.0, 6.0)]

# arbitrary whitespace and tabs are fine
parse_coordinates_automa("  1.5 , 2.5  \n  3.5 , 4.5  ")
# → [SVector(1.5, 2.5), SVector(3.5, 4.5)]

# non-conformant: comma-only delimiter, no whitespace between tuples
parse_coordinates_automa("28.25,69.06,0,28.26,69.07,0,28.27,69.08,0")
# → [SVector(28.25, 69.06, 0.0),
#    SVector(28.26, 69.07, 0.0),
#    SVector(28.27, 69.08, 0.0)]

# 2D fall-back: even count not divisible by 3
parse_coordinates_automa("1,2,3,4")
# → [SVector(1.0, 2.0), SVector(3.0, 4.0)]
```

## Trade-offs

The lenient policy has a deliberate cost: an input whose **intent** was a
single `(longitude, latitude, altitude)` triple but with a stray comma
appended (e.g. `1,2,3,`) will be parsed as the same triple plus an
ignorable run of delimiter, which is fine. A more pathological case — a
truly malformed payload with five numbers — will fall back to
`SVector{2}` pairs (`[(1,2),(3,4)]`) or, if the count is neither a
multiple of 2 nor 3, return empty with a warning. We chose this over
hard failure because real-world data is messy and a permissive parser is
strictly more useful than a strict one for the common malformations
documented above.

If your use case requires strict spec validation, you can post-process
the output of `parse_coordinates_automa` and reject anything you consider
malformed; the parser does not lose information that strict mode would
have observed.

## Further reading

- [GDAL ticket #5140](https://trac.osgeo.org/gdal/ticket/5140) — KML with
  space around tuples separator considered invalid.
- [MapGuide ticket #1096](https://trac.osgeo.org/mapguide/ticket/1096) —
  generated `<coordinates>` does not follow spec.
- [MITRE — KML Best Practices for Interoperability (Mathews, 2011)](https://www.mitre.org/sites/default/files/pdf/11_3295.pdf).
- [Google KML Reference](https://developers.google.com/kml/documentation/kmlreference).
- [NASA World Wind `KMLCoordinateTokenizer`](https://worldwind.arc.nasa.gov/java/v2.1.0/javadoc/gov/nasa/worldwind/ogc/kml/KMLCoordinateTokenizer.html).
