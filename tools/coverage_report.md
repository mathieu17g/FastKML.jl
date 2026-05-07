# FastKML coverage audit — OGC KML 2.2 + Google extensions

_Generated 2026-05-08 by `tools/audit_kml_coverage.jl`._

Sources:
- OGC: <https://schemas.opengis.net/kml/2.2.0/ogckml22.xsd>
- Google: <https://developers.google.com/kml/schema/kml22gx.xsd>

## Summary

| Schema | Complex candidates | Modeled | Missing |
|---|---|---|---|
| OGC KML 2.2 | 58 | 55 | 3 |
| Google ext. (gx:) | 15 | 14 | 1 |

FastKML `TAG_TO_TYPE` entries: **80**

## OGC KML 2.2

**Stats**

- Element declarations (recursive): 269
  - Abstract / substitution groups: 124
  - Simple-typed leaves (handled as struct fields): 87
  - Complex-typed candidates: 58
    - **Modeled in `TAG_TO_TYPE`:** 55
    - **Missing:** 3

### Missing complex-typed elements

| name | type | kind |
|---|---|---|
| `Metadata` | `kml:MetadataType` | `true_complex` |
| `innerBoundaryIs` | `kml:BoundaryType` | `true_complex` |
| `outerBoundaryIs` | `kml:BoundaryType` | `true_complex` |

_Note: some elements may be intentionally unmodeled because they're_
_handled by special parsing paths (e.g. `<outerBoundaryIs>` /_
_`<innerBoundaryIs>` are routed through `Polygon` boundary fields)._

### Modeled elements (sanity check)

`Alias`, `BalloonStyle`, `Camera`, `Change`, `Create`, `Data`, `Delete`, `Document`, `ExtendedData`, `Folder`, `GroundOverlay`, `Icon`, `IconStyle`, `ImagePyramid`, `ItemIcon`, `LabelStyle`, `LatLonAltBox`, `LatLonBox`, `LineString`, `LineStyle`, `LinearRing`, `Link`, `ListStyle`, `Location`, `Lod`, `LookAt`, `Model`, `MultiGeometry`, `NetworkLink`, `NetworkLinkControl`, `Orientation`, `Pair`, `PhotoOverlay`, `Placemark`, `Point`, `PolyStyle`, `Polygon`, `Region`, `ResourceMap`, `Scale`, `Schema`, `SchemaData`, `ScreenOverlay`, `SimpleData`, `SimpleField`, `Snippet`, `Style`, `StyleMap`, `TimeSpan`, `TimeStamp`, `Update`, `Url`, `ViewVolume`, `kml`, `linkSnippet`

## Google extension (gx:)

**Stats**

- Element declarations (recursive): 43
  - Abstract / substitution groups: 4
  - Simple-typed leaves (handled as struct fields): 24
  - Complex-typed candidates: 15
    - **Modeled in `TAG_TO_TYPE`:** 14
    - **Missing:** 1

### Missing complex-typed elements

| name | type | kind |
|---|---|---|
| `ViewerOptions` | `gx:ViewerOptionsType` | `true_complex` |

_Note: some elements may be intentionally unmodeled because they're_
_handled by special parsing paths (e.g. `<outerBoundaryIs>` /_
_`<innerBoundaryIs>` are routed through `Polygon` boundary fields)._

### Modeled elements (sanity check)

`AnimatedUpdate`, `FlyTo`, `LatLonQuad`, `MultiTrack`, `Playlist`, `SimpleArrayData`, `SimpleArrayField`, `SoundCue`, `TimeSpan`, `TimeStamp`, `Tour`, `TourControl`, `Track`, `Wait`

## FastKML registry entries with no XSD counterpart

These are aliases (e.g. `<Url>` → `Link`), special structural tags, or
auto-populated names that don't correspond to a single XSD element.

- `AtomAuthor`
- `AtomLink`
- `StyleMapPair`
- `atom_author`
- `atom_link`

