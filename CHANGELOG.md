# Changelog

All notable changes to FastKML.jl will be documented in this file.

The format follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

## [0.2.0] — 2026-07-04

Substantial pre-release work since the initial commit — headlined by the
migration to **XML.jl v0.4** and the cursor-backed extraction path that
now beats the ArchGDAL baseline on all four benchmark corpora. The
package is not yet on the Julia registry.

### Changed — XML.jl v0.4 adoption

- **`[compat] XML = "0.4"`**, resolved from the General registry (the
  local `dev/` source pin is gone; `Pkg.add` on a clone just works).
  The lazy-iteration and parsing internals moved off the removed 0.3
  streaming API (`next`/`prev` era) onto v0.4's immutable `LazyNode`
  and the new `Cursor` (StAX-style) API, with a cursor-backed placemark
  fast path. Cursor/lazy content equivalence
  (`isequal(df_lazy, df_cursor)`) holds on all four benchmark corpora —
  see Performance below.

### Added — Public API

- **`DataFrame(file; layer = :all)` / `PlacemarkTable(file; layer = :all)`**
  — single-pass multi-layer extraction. Walks the document once and
  yields every placemark across every layer, returning a 5-column
  schema `(layer_idx, layer_name, name, description, geometry)`. The
  index disambiguates duplicate layer names (common in real-world
  feeds where sibling `<Folder>`s share a `<name>`). Replaces the
  manual `[DataFrame(file; layer=k) for k in 1:n]; vcat(...; cols=:union)`
  pattern that loses layer attribution.

### Added — KML element coverage

Five-phase OGC 2.2 + Google `gx:` extension completeness sweep,
closed 2026-05-08. Final coverage per `tools/audit_kml_coverage.jl`:
**56/58 OGC** concrete candidates (the two missing are `<outerBoundaryIs>`
and `<innerBoundaryIs>`, intentionally handled via `Polygon`'s special
parsing path); **15/15 Google `gx:`** candidates (full).

- `<NetworkLinkControl>` — top-level KML 2.2 §12.2 element with all 10
  fields (`minRefreshPeriod`, `maxSessionLength`, `cookie`, `message`,
  `linkName`, `linkDescription`, `linkSnippet`, `expires`, `Update`,
  `AbstractView`). `linkSnippet` aliased to the existing `Snippet`
  struct.
- `<Metadata>` — deprecated container (OGC 2.2 §6.7, replaced by
  `<ExtendedData>` in newer files but still in the schema for legacy
  compat). Modeled with an opaque `children::Vector{XML.AbstractXMLNode}`
  field; the subtree is preserved verbatim instead of routed through
  `add_element!` (which would warn on the `<any processContents="lax">`
  content).
- `<gx:TimeStamp>` / `<gx:TimeSpan>` — Google extension on `<Camera>`
  and `<LookAt>` (the `<AbstractView>` group). Modeled as
  `TimePrimitive` subtypes; routed onto the existing
  `Camera.TimePrimitive` / `LookAt.TimePrimitive` field via
  abstract-type dispatch in `assign_complex_object!` (no field added
  to those structs).
- `<gx:ViewerOptions>` and `<gx:option>` — Google extension for tour
  viewer behavior. `gx_option` carries `name` + `enabled` attributes
  alongside inherited `id`/`targetId`. Field on `<Camera>` /
  `<LookAt>`.
- `<gx:Track>` end-to-end (eager + lazy paths) with
  `<gx:SimpleArrayField>` / `<gx:SimpleArrayData>` per-coord auxiliary
  arrays (heart rate, cadence, power) routed through `Schema` /
  `ExtendedData` / `SchemaData`.

### Added — Tooling

- `tools/audit_kml_coverage.jl` — XSD-based static audit script.
  Downloads OGC and Google extension XSDs (cached under
  `tools/.xsd_cache/`, gitignored), classifies element types as
  `:true_complex` / `:simple_content` / `:simple`, and diffs against
  `TAG_TO_TYPE` after `using FastKML`. Outputs `tools/coverage_report.md`
  (versioned). Run via
  `julia --project=. tools/audit_kml_coverage.jl [out.md] [--refresh]`.

### Added — Documentation

- `docs/src/index.md` — landing page with highlights, installation,
  quickstart (eager / lazy / multi-layer / programmatic build).
- `docs/src/eager_vs_lazy.md` — explains the three parsing modes
  (eager `KMLFile`, lazy `LazyKMLFile`, narrow
  `DataFrame`/`PlacemarkTable`), their cost/completeness trade-offs,
  the `ExtendedData`-on-eager-only contract, and the `layer = :all`
  multi-layer mode.
- `docs/src/coordinate_parsing.md` — design rationale for lenient
  coordinate parsing (real-world ESDAC files use comma-only
  delimiters, FastKML recovers, ArchGDAL doesn't).
- `docs/src/api.md` — auto-generated API reference from public
  module docstrings.

### Added — Tests

Module coverage went from 0% / near-zero to 74-100% across:

- `Layers.jl` (single + multi-layer paths, eager + lazy)
- `tables.jl` (PlacemarkTable construction, Tables.jl interface,
  all four `parse_geometry_lazy` branches)
- `utils.jl` (10 exported helpers)
- `validation.jl` (all geometry types + document structure)
- `time_parsing.jl` (ISO 8601 across date / datetime / week date /
  ordinal date, extended + basic forms)
- `FastKMLDataFramesExt` (100% — both method overloads)
- `FastKMLZipArchivesExt` (KMZ round-trip with `doc.kml` at root and
  `data/inner.kml` fallback)

Modeled-type testsets exhaustively cover the new elements:
NetworkLinkControl (22 assertions), Metadata (6), gx:Track parsing
(37), gx:TimeStamp/gx:TimeSpan in AbstractView (11),
gx:ViewerOptions/gx:option (13), `layer = :all` extraction (17), and
"Unmodeled top-level tags are skipped, not fatal" (4 — Phase 1
hardening regression). The `Empty Constructors` testset extended from
`Object` to all `KMLElement` subtypes (264 → 288 generated assertions).

`test/integration_archgdal_test.jl` (gated behind
`FASTKML_INTEGRATION=true`) downloads URL2 / URL4 / URL5 from
benchmark URLs and asserts parity with ArchGDAL after symmetric
`strip + decode_named_entities` / `\s+` normalizations.

### Changed

- `parse_kmlfile` now filters non-`KMLElement` returns from `object()`
  (was previously crashing with MethodError when an unmodeled
  top-level tag like `<NetworkLinkControl>` returned `nothing`). The
  "Unhandled Tag" warning still fires from `_object_slow` as the
  single source of unknown-tag feedback.
- `assign_complex_object!` rewritten as a two-pass dispatcher:
  pass 1 = direct type match across all fields (order-independent);
  pass 2 = vector fields, skipping Any-eltype Union vectors. Fixes
  gx:Track `ExtendedData` mis-routing where Union-vector eltype
  widening would silently swallow children into `gx_coord`.
- `assign_field!` accumulates on `:gx_coord` siblings instead of
  overwriting (was: only the last `<gx:coord>` retained per Track).
- Dependency `JSON3` (deprecated) replaced with `JSON` v1.

### Fixed

- `decode_named_entities` sliced on character index instead of byte
  index, crashing on multi-byte UTF-8 next to entities. Hit in the
  wild by EPA's `national_frs.kmz` non-breaking spaces (U+00A0,
  2 bytes in UTF-8) adjacent to `&AMP;` entities.
- `parse_week_date` shadowed `Dates.dayofweek` with a local variable,
  breaking every ISO 8601 week-date input. Renamed local to `wday`.
- `Schema`, `SimpleField`: missing defaults on `id` / `type` / `name`
  attributes broke eager parse of `<Schema>` blocks. Added `= ""`.
- `_is_layer_tag(::Nothing)` and `_is_container_tag(::Nothing)`
  methods added so layer enumeration handles non-Element children
  (comments, text, processing instructions) without
  `MethodError`.
- `Base.eltype(::Type{EagerLazyPlacemarkIterator})` referenced an
  undefined `iter` (copy-paste typo from the instance overload).
  Found by JET. Fixed via
  `fieldtype(EagerLazyPlacemarkIterator, :placemarks)`.
- `validate_geometry(::Polygon)`: removed unreachable
  `outerBoundaryIs === nothing` check (the field is typed
  `LinearRing`, no `Nothing` in the union).

### Performance

Round 1 memory profiling (commit `4d9408e`): DataFrame-extraction
tracked allocations dropped 240 MiB → 123 MiB (-49%) on URL2 via
`extract_text_content_fast` 0/1-fragment fast path +
`Coordinates.parse_coordinates_automa` heuristic `sizehint!`.

Full milestone (2026-07-03, shipped on `main` via the XML v0.4 cursor
path — median time ms / allocated MiB, `@benchmark seconds = 10`):

| URL (rows) | cursor | lazy | ArchGDAL |
|---|---|---|---|
| URL2 enzone (5.4k) | **161 / 166** | 198 / 178 | 249 / 13 |
| URL4 WRS-2 (28.5k) | **164 / 86** | 314 / 149 | 304 / 25 |
| URL5 qfaults (114k) | **1341 / 966** | 2441 / 1197 | 2298 / 357 |
| URL6 national_frs (163k) | **709 / 273** | 1810 / 564 | 3853 / 155 |

**The cursor path beats ArchGDAL on time on all four** (ArchGDAL's
C++/GDAL core stays leaner in Julia-visible memory — orthogonal to the
walk). Full sheets: `benchmark/results_2026-06-02_cursor_phase3.md`
(baseline + configs) and
`benchmark/results_2026-07-03_xml-v04-tip_rebench.md` (this table).

The May `XML.next!`/`prev!` experiment
(`wip-xml-next-bang-adoption`, never merged) is retired: its findings
drove the *upstream* streaming API instead
([XML.jl#61](https://github.com/JuliaData/XML.jl/issues/61) → v0.4's
`Cursor`), and the cursor path recovers that experiment's speed class
while allocating a fraction of its memory (e.g. URL6: 273 vs
2316 MiB).

### Internal

- `benchmark/scaling_benchmark.jl` (renamed from
  `cross_branch_benchmark.jl`, pruned 407 → 110 lines): synthetic
  Point-only KML generator + read benchmark + DataFrame benchmark +
  console summary table.
- Dead-code sweep via JET.jl on 2026-04-30: 1 typo fix shipped, ~11
  reports deferred for future triage (see `TODO.md`).
- CI workflow added (`.github/workflows/CI.yml` — Julia 1 + lts,
  ubuntu, dependency caching).
- Repo hygiene: git history purged of the `notes/` coordination-scratch
  directory (`filter-repo`, code tree byte-identical); the May
  investigation era pruned from `benchmark/` (its conclusions shipped
  upstream in XML v0.4).

## [0.1.0] — 2026-04-25

Initial commit. FastKML.jl established as a standalone package
derived from work originally proposed as
[`KML.jl#14`](https://github.com/JuliaComputing/KML.jl/pull/14) but
standalone (not a fork). KML.jl continues independently as a
deliberately lightweight library; FastKML.jl hosts the performance
work and extra integrations (DataFrames, GeoInterface, Makie,
ZipArchives weak-dep extensions) that were out of scope upstream.
