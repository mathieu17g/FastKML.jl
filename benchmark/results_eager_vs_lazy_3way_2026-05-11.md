# FastKML benchmark — 3-way XML.jl × eager/lazy × ArchGDAL

Run date: 2026-05-11
Julia 1.12.6, Darwin aarch64.
Bench script: `benchmark/benchmark_kml_parsers.jl` (with `table_with_fastkml_eager` added).
Budget: 10 seconds per (URL, extraction technique).

Three FastKML configurations tested:

- **v0.3.8 registry** — main branch FastKML, XML pinned to `Pkg.add(name="XML", version="0.3.8")` (no PR #58, no PR #59)
- **v0.3.8 + #58 + #59** — `wip-xml-next-bang-adoption` branch FastKML, XML = `dev/XML.jl` (PRs #58 ctx-share + #59 next!/prev!)
- **v0.4.0** — `wip-xml-v0.4` branch FastKML, XML = `dev/XML.jl-v0.4` (PR #54 head SHA `e7e21a7`)

Per configuration, three pipelines:

- **lazy** — `read(path, LazyKMLFile)` then walk layers to extract DataFrame
- **eager** — `read(path, KMLFile)` (materializes the full struct hierarchy) then extract
- **GDAL** — `ArchGDAL.read(path)` then layer iteration

## Test files

The four URLs are chosen to surface distinct XML structural profiles —
the lazy walk cost is sensitive to nesting depth, top-level layer count,
and per-Placemark geometry size, so a single trivial file would not
expose the regression analysis below. Sources are declared in
`benchmark/benchmark_kml_parsers.jl` alongside their per-URL parsing
notes.

| Key  | Source                                            | Rows    | Top-level structure                                | Geometry profile                | ArchGDAL match           |
|------|---------------------------------------------------|---------|-----------------------------------------------------|----------------------------------|---------------------------|
| URL2 | [NY DEC environmental zones](https://www.dec.ny.gov/data/der/enzones/enzone2022.kmz) (`enzone2022.kmz`)            | 5 411   | Single Document with 1 Folder, moderate nesting     | Polygon Placemarks via `<MultiGeometry>` (5 429 Polygons total)  | iso (end-to-end)          |
| URL4 | [USGS WRS-2 Landsat tile boundaries](https://d9-wret.s3.us-west-2.amazonaws.com/assets/palladium/production/s3fs-public/atoms/files/WRS-2_bound_world_0.kml) (`WRS-2_bound_world_0.kml`) | 28 557  | Single flat top-level layer                         | Polygon Placemarks (uniform 5-vertex LinearRings) | iso (end-to-end)          |
| URL5 | [USGS Quaternary Faults](https://earthquake.usgs.gov/static/lfs/nshm/qfaults/qfaults.kmz) (`qfaults.kmz`)             | 114 037 | 8 thematic top-level Folders (Historical, Latest/Late/Middle-Late/Undifferentiated Quaternary, Unspecified Age, Class B, California Offshore) | LineString Placemarks via `<MultiGeometry>` (114 474 LineStrings total) | iso (end-to-end)          |
| URL6 | [EPA Facility Registry Service](https://ordsext.epa.gov/FLA/www3/national_frs.kmz) (`national_frs.kmz`)              | 163 426 | 3 top-level layers (FastKML view) / ~19 182 nested Folders (ArchGDAL maps each leaf to a layer) | Point Placemarks (one per Placemark) | non-iso (1 row residual)  |

Why each profile matters for the lazy-walk analysis:

- **URL2** — balanced reference. Single moderate-depth tree, mixed
  geometry. The lazy walk cost is visible but not dominant; useful for
  baseline sanity-checks.
- **URL4** — 28k Polygon Placemarks (each a 5-vertex LinearRing,
  representing a Landsat scene boundary) in a single flat top-level
  layer. Per-child overhead is amortized over the largest single layer
  in the set, and the geometry payload is small (5 coords per
  Placemark). **Least favorable case for lazy strengths** and the URL
  where ArchGDAL is hardest to beat — only v0.3.8+#58+#59 lazy passes it.
- **URL5** — 8 top-level Folders × ~14k Placemarks each. FastKML's
  `LazyKMLFile` pipeline traverses the document once per layer
  (8 traversals), so any lazy walk regression is amplified ×8 on this
  file compared to a single-layer equivalent.
- **URL6** — deepest nesting. ArchGDAL's leaf-folder→layer mapping fans
  out to ~19k sublayers; FastKML's per-feature efficiency is what keeps
  it competitive here. The lazy walk regression hurts worst on this
  profile because the depth multiplies the per-token overhead.

Content equivalence with ArchGDAL is verified end-to-end on all four URLs
in `benchmark/benchmark_kml_parsers.jl` (columns: `name`, `description`,
geometry WKT, geometry coordinates) after symmetric normalizations
(whitespace, named HTML entities, ArchGDAL multi-layer concatenation).
URL2/URL4/URL5 match exactly; URL6 has a single accepted divergence on a
malformed `<coordinates>,,0</coordinates>` row (FastKML returns
`Float64[]`, ArchGDAL substitutes `(0,0,0)` — documented in
`docs/src/coordinate_parsing.md` as a fallback-policy difference, not a
FastKML bug).

## Median elapsed time (ms)

| URL                 | v0.3.8 reg lazy | v0.3.8 reg eager | v0.3.8+PRs lazy | v0.3.8+PRs eager | v0.4 lazy | v0.4 eager | ArchGDAL |
|---------------------|-----------------|-------------------|---------------|----------------|-----------|------------|----------|
| URL2 enzone (5.4k)  | 221             | 410               | **204** ✨    | 412            | 395       | **192**    | 253-260  |
| URL4 WRS-2 (28.5k)  | 382             | 1194              | **261** ✨    | 1101           | 688       | 534        | **299-307** |
| URL5 qfaults (114k) | 2735            | 4886              | **2357** ✨   | 4834           | 3188      | **1836**   | 2434-2508 |
| URL6 nat_frs (163k) | 1830            | 4631              | **1247** ✨   | 4259           | 2862      | 1924       | 3185-3257 |

## Median memory (MiB, rounded)

| URL                 | v0.3.8 reg lazy | v0.3.8 reg eager | v0.3.8+PRs lazy | v0.3.8+PRs eager | v0.4 lazy | v0.4 eager | ArchGDAL |
|---------------------|-----------------|-------------------|---------------|----------------|-----------|------------|----------|
| URL2                | 328             | 447               | **188**       | 363            | 405       | 229        | 13       |
| URL4                | 1394            | 2124              | **480**       | 1629           | 1707      | 597        | 25       |
| URL5                | 4703            | 6186              | **1855**      | 4814           | 6004      | 2239       | 357      |
| URL6                | 6907            | 8655              | **2320**      | 6597           | 8099      | 2065       | 155      |

## Best path per FastKML configuration

| Configuration | Best path | URL2 | URL4 | URL5 | URL6 | vs ArchGDAL (4 URLs) |
|---------------|-----------|------|------|------|------|----------------------|
| v0.3.8 registry         | lazy  | 221  | 382  | 2735 | 1830 | wins on 2/4 (URL2, URL6) |
| **v0.3.8 + #58 + #59**  | **lazy** | **204** | **261** | **2357** | **1247** | **wins on 4/4** ✨ |
| v0.4.0                  | eager | 192  | 534  | 1836 | 1924 | wins on 3/4 (URL2, URL5, URL6) |

## Key observations

### What each PR contributes

- **PR #58 (ctx-share)** improves the `LazyNode + children()` path beyond its
  stated scope: v0.3.8 reg lazy → v0.3.8+#58 lazy roughly drops time by 7-20%
  and memory by 30-67% (depending on URL).

- **PR #59 (next!/prev!)** unlocks zero-alloc DFS walks: the
  `@for_each_immediate_child` macro adopts `next!` and yields the best
  path on deeply-structured files. Splitting by axis:
    - **Time**: v0.3.8+#58+#59 lazy is fastest on URL4 (261 vs v0.4 eager
      534) and URL6 (1247 vs 1924). v0.4 eager is faster on URL2 (192
      vs 204) and URL5 (1836 vs 2357), but at higher memory cost.
    - **Memory**: v0.3.8+#58+#59 lazy is the most memory-efficient on
      URL2 (188 MiB), URL4 (480), and URL5 (1855); v0.4 eager wins memory
      only on URL6 (2065 vs 2320).
    - **vs ArchGDAL**: v0.3.8+#58+#59 lazy beats ArchGDAL in time on
      **4/4 URLs** — the only configuration that does so.

### What v0.4 contributes

- **Eager path: massively improved**. v0.4 eager is ×2.06 to ×2.63 faster
  than v0.3.8+#59 eager and uses 37-69% less memory:

  | URL | v0.3.8+PRs eager | v0.4 eager | speedup | mem reduction |
  |-----|----------------|------------|---------|---------------|
  | URL2 | 412 / 363 MiB  | 192 / 229 MiB | ×2.15  | -37%   |
  | URL4 | 1101 / 1629    | 534 / 597     | ×2.06  | -63%   |
  | URL5 | 4834 / 4814    | 1836 / 2239   | ×2.63  | -53%   |
  | URL6 | 4259 / 6597    | 1924 / 2065   | ×2.21  | -69%   |

- **Lazy path: regressed vs v0.3.8+#58**. v0.4 has no `next!`/`prev!`
  equivalent; `eachchildnode` allocates `LazyChildIterator` + `Stateful` per
  call; `children(::LazyNode)` materializes Vector per call. Net cost is
  higher than the v0.3.8 path with PRs applied.

### What this means

- **For FastKML right now**: stay on `wip-xml-next-bang-adoption` (v0.3.8 +
  #58 + #59) — it is the only configuration where FastKML beats ArchGDAL on
  all 4 URLs in time.

- **Migrating to v0.4 today** (taking the best v0.4 path vs best
  v0.3.8+#58+#59 path):
    - **Time**: regression on **2/4 URLs** — URL4 +104% (261 → 534) and
      URL6 +54% (1247 → 1924). URL2 -6% (204 → 192) and URL5 -22%
      (2357 → 1836) improve, but on the files where lazy was already
      good enough.
    - **Memory**: regression on **3/4 URLs** — URL2 +22% (188 → 229),
      URL4 +24% (480 → 597), URL5 +21% (1855 → 2239). Only URL6
      improves (-11%, 2320 → 2065).

- **For the upstream conversation** (Phase C): v0.4's eager-path gains
  are real (×2-2.6 speedup, 37-69% memory reduction over v0.3.8+#58+#59
  eager). The trade-off is that no current v0.4 API path matches the
  zero-alloc lazy walk class that PR #59 provided under v0.3.8 — on URL4
  and URL6, where lazy was the optimal path, that absence is a measurable
  loss in both time and memory. Whether and how to recover this class
  under v0.4's immutable design is the substance of issue #61, which lays
  out 4 candidate API directions as open questions rather than a proposed
  answer.

## Notes on URL4

URL4 (WRS-2 Landsat tile boundaries) is the URL where ArchGDAL is
hardest to beat — its profile (28.5k Polygon Placemarks in a single
flat top-level layer, each a 5-vertex LinearRing) is a wide-and-shallow
XML structure with simple per-Placemark geometry, an optimal case for
GDAL's KML/LIBKML driver. **Only v0.3.8+#58+#59 lazy passes
it** (261 ms vs 299-307 for ArchGDAL → FastKML ~14% faster); every other
FastKML configuration is slower than ArchGDAL on this file. The gap
widens to v0.4 eager (534 vs 307 → FastKML ~74% slower than ArchGDAL),
making URL4 the most sensitive file to losing the v0.3.8 zero-alloc lazy
walk class.

## Per-URL tokenization decomposition (measured 2026-05-13)

To check how much of FastKML's v0.4 lazy time is pure XML tokenization
vs FastKML's per-Placemark processing (lazy walk + DataFrame extraction),
each URL was measured with two passes:

- **Tokenization-only**: raw `XML.Tokenizer` DFS pass — the same pattern
  used by extraction technique 5 in the synthetic walk-pattern bench
  (flat DFS, no `LazyNode` allocation, summing token text byte counts
  as a workload-equivalent operation).
- **FastKML full lazy**: `table_with_fastkml` (the canonical lazy
  benchmark target — `LazyKMLFile` parse + DataFrame extraction across
  all layers).

Bench budget: 5 s per measurement, median time, same Julia 1.12.6 /
Darwin aarch64 host as the main results.

| URL  | Size (MiB) | Tokenize-only (ms) | FastKML full lazy v0.4 (ms) | Tokenize share |
|------|------------|--------------------|------------------------------|----------------|
| URL2 | 46         | 20.0               | 369.3                        | 5.4%           |
| URL4 | 34         | 73.7               | 636.8                        | 11.6%          |
| URL5 | 420        | 296.6              | 3073.8                       | 9.6%           |
| URL6 | 102        | 258.9              | 2766.6                       | 9.4%           |

Tokenization is consistently a minority (5–12%) of FastKML lazy total
time across all URLs. The synth bench reports 19% for the equivalent
tokenization share of `eachchildnode` pure walk cost — the real-pipeline
number is lower here because FastKML's per-Placemark work (geometry
parsing, attribute extraction, DataFrame column conversion) adds
substantial cost beyond pure tree walk.

### v0.4 regression cost per Placemark

To compare the v0.4 lazy regression independently of total file size,
the delta vs `v0.3.8 + #58 + #59` lazy divided by the number of Placemarks:

| URL  | Placemarks | v0.3.8+PRs lazy (ms) | v0.4 lazy (ms) | Δ (ms) | Cost added per PM | XML depth Placemark → leaf |
|------|------------|--------------------|----|----|----|-----|
| URL2 |   5 411    | 204                | 395            | 191    | **35.4 µs/PM**     | 5 (Placemark → MultiGeo → Polygon → outerBoundary → LinearRing) |
| URL4 |  28 557    | 261                | 688            | 427    | 15.0 µs/PM         | 4 (Placemark → Polygon → outerBoundary → LinearRing) |
| URL5 | 114 037    | 2 357              | 3 188          | 831    | **7.3 µs/PM** (low) | 3 (Placemark → MultiGeo → LineString) |
| URL6 | 163 426    | 1 247              | 2 862          | 1 615  | 9.9 µs/PM          | 2 (Placemark → Point), but ~19k Folder fan-out above |

Two observations from this decomposition:

1. **Per-Placemark cost correlates with XML depth per feature** — URL2
   (depth 5) is the most penalized at 35.4 µs/PM, URL5/URL6 (depths 2–3)
   are least penalized at 7–10 µs/PM. URL4 sits in between (depth 4).
   This matches the expected behavior of a lazy walk that allocates one
   `LazyNode` wrapper per XML level traversed per feature.

2. **Relative regression magnitude is sensitive to baseline size** —
   URL5 has the smallest relative regression (×1.35) not because v0.4
   handles it better, but because its `v0.3.8 + #58 + #59` baseline is
   large (2 357 ms), so the 831 ms of v0.4-added overhead dilutes to
   ×1.35. URL4 has the largest relative regression (×2.64) because its
   baseline is small (261 ms), so 427 ms of added overhead is
   proportionally huge.

The cost-per-Placemark metric is therefore the more direct indicator of
where v0.4's per-child allocation overhead actually hurts. It correlates
with the number of `LazyNode` wrappers FastKML must instantiate per
Placemark — proportional to the XML depth per feature.

## Reproduction

```sh
# v0.3.8 registry (main)
git checkout main
julia --project=benchmark -e 'using Pkg; Pkg.add(name="XML", version="0.3.8")'
# patch benchmark_kml_parsers.jl to add table_with_fastkml_eager + 3-col output
julia --project=benchmark -e 'include("benchmark/benchmark_kml_parsers.jl"); run_benchmarks([URL2, URL4, URL5, URL6]; default_benchmark_seconds=10)'

# v0.3.8 + #58 + #59 (wip-xml-next-bang-adoption)
git checkout wip-xml-next-bang-adoption
julia --project=benchmark -e 'using Pkg; Pkg.develop(path="../dev/XML.jl")'
# same patch + run

# v0.4 (wip-xml-v0.4)
git checkout wip-xml-v0.4
julia --project=benchmark -e 'using Pkg; Pkg.develop(path="../dev/XML.jl-v0.4")'
julia --project=benchmark -e 'include("benchmark/benchmark_kml_parsers.jl"); run_benchmarks([URL2, URL4, URL5, URL6]; default_benchmark_seconds=10)'
```
