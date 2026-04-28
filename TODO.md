# TODO

Open items accumulated during development. Add to it; tick off as you go.

## Benchmark — investigation

- [x] **URL1 (`USEDO.kmz`) — resolved.** Source is non-conformant KML:
      coordinates use comma-only delimiters with no whitespace between
      tuples (`lon1,lat1,0,lon2,lat2,0,…`). FastKML's parser is lenient
      by design and recovers the correct geometry; ArchGDAL is strict
      and reduces each ring to a single point. Not a FastKML bug.
      Documented in `docs/src/coordinate_parsing.md` and tested in
      `test/runtests.jl`.
- [x] **URL3 (`Aglim1.kmz`) — resolved.** Same root cause as URL1: ESDAC /
      KMLer-generated, comma-only-delimited coordinates with no
      whitespace between tuples. Verified directly on the raw XML
      (first `<coordinates>` starts with the same byte sequence as
      USEDO.kmz, suggesting ESDAC re-uses the same geometry across
      products). Side observation: rows where the source has a nested
      `<MultiGeometry>` containing only `<Polygon>` children round-trip
      as `MULTIPOLYGON Z (...)` via FastKML and as `GEOMETRYCOLLECTION
      Z (POLYGON Z (...))` via ArchGDAL — both are valid OGC Simple
      Features WKT representations of the same data, but downstream
      consumers that branch on geometry type will see them as distinct.
- [x] **URL6 (`national_frs.kmz`) — resolved.** Three distinct findings:
      (i) FastKML had a real bug in `decode_named_entities` (sliced on
      char index instead of byte index, crashing on multi-byte UTF-8
      next to entities) — fixed in 889a275, with regression tests;
      (ii) the row count mismatch (FastKML 163k vs ArchGDAL 4) was a
      **layer-semantics divergence**, not a bug. FastKML exposes 3
      top-level Document/Folder layers (the first contains all 163k
      placemarks recursively); ArchGDAL flattens to 19 122 leaf-folder
      layers (one per city), so `getlayer(dataset, 0)` only sees the
      first city. Updated `table_with_archgdal` to concatenate ALL
      ArchGDAL layers by default. Also extended the description
      normalization to `\s+` (was `[\r\n]+`) so tab-run differences in
      EPA's HTML descriptions aren't reported as content mismatches.
      (iii) After (i)+(ii), 49 small name-column diffs remained: one
      with a leading whitespace (FastKML preserves; ArchGDAL strips) and
      48 with `&AMP;` vs `&` (the source uses the non-conformant
      uppercase HTML5 entity; FastKML decodes via `NAMED_HTML_ENTITIES`,
      ArchGDAL preserves raw). Resolved by symmetric name-column
      normalization in the benchmark: `strip` + `decode_named_entities`
      on both sides. Plus one residual: row 48072 has malformed
      `<coordinates>,,0</coordinates>` — FastKML returns `Float64[]`,
      ArchGDAL substitutes `(0,0,0)`. This is a genuine fallback-policy
      difference on invalid input; documented as accepted divergence.
- [ ] After URL3/URL6, sweep across the improved diagnostics
      (`diff @ char N`, WKT `.val`) on any other diverging (non-iso)
      file we come across and decide row-by-row which interpretation is
      correct against the raw XML.
- [ ] Investigate URL4 (`WRS-2_bound_world_0.kml`, 28k flat Placemarks):
      FastKML is ~14% slower than ArchGDAL there, while it is 25–99%
      faster on URL2 and URL5. Likely a hot path in `xml_parsing.jl` for
      very wide-and-shallow files.

## Performance

- [partial] Memory allocation profile.
    - Tooling: `benchmark/profile_memory.jl` (FastKML) and
      `benchmark/profile_memory_archgdal.jl` (ArchGDAL baseline) drive
      the hot path on a representative file with
      `--track-allocation=user`. Analyze the resulting `*.mem` files
      with `Coverage.analyze_malloc`.
    - **Round 1 (commit `4d9408e`)**: tracked allocations 240 MiB →
      123 MiB (-49%) on URL2. End-to-end benchmark cumulative memory
      444 MiB → 327 MiB (-27%). Time unchanged. Fixes:
        - `xml_parsing.extract_text_content_fast`: fast-path the common
          0/1-fragment case to skip `Vector{String}` + `join` per call
          (108 MiB → 3 MiB on this site).
        - `Coordinates.parse_coordinates_automa`: enable a heuristic
          `sizehint!` on the floats vector (~12 MiB win on URL2).
    - **ArchGDAL baseline**: 0.66 MiB tracked Julia allocations on the
      same file. ~190× lower than FastKML, but the comparison is
      misleading because GDAL does the XML parsing and geometry
      construction in C++ (invisible to Julia's allocation tracker).
      Realistic target for FastKML's tracked allocations is on the
      order of the data payload (DataFrame columns + parsed floats +
      String contents), not 1 MiB.
    - **Round 2**: tested two hypotheses, neither moved the needle on
      URL2:
        - Replacing `Parsers.parse(Float64, view(data_bytes, …))` with
          `Parsers.xparse(Float64, data_bytes, pos, len, …)` to avoid
          per-call SubArray allocation. Identical bytes attributed
          (50.5 MiB) — the SubArray was being elided. The remaining
          ~38 MiB is `Parsers.Result{Float64}` allocated per parsed
          float; the rest is the Vector{Float64} storage. Reverted.
        - Typing `features = []` as `XML.LazyNode[]` in
          `Layers._lazy_top_level_features` — saved only ~50 bytes.
          The ~9 MiB attributed to those `@for_each_immediate_child`
          callsites is from `XML.next(_current)` allocating a fresh
          `LazyNode` per traversal step (~1 M nodes for a 47 MiB KML),
          not from boxing pushes. Kept the change for correctness, but
          no perf impact. Real fix would need XML.jl-side support for
          a non-allocating iterator.
    - **Residual hot sites are structural**: `Parsers.Result` per parse
      (~38 MiB), `Vector{Float64}` payload (~13 MiB), final
      `Vector{SVector{3,Float64}}` (~23 MiB), `XML.LazyNode` allocation
      per `XML.next` call across ~1 M nodes (~30 MiB). Further wins
      require either replacing Parsers.jl with a hand-rolled Float64
      scanner (custom code), or upstreaming a non-allocating iterator
      to XML.jl.
- [ ] Evaluate skipping the double materialization
      (`KMLFile` tree → `PlacemarkTable` → `DataFrame`) by going
      `LazyKMLFile` → `DataFrame` directly when DataFrames is the
      consumer.

## Test coverage

Current global coverage: ~22%. Modules currently at 0%:

- [ ] `src/Layers.jl` — `list_layers`, `get_layer_names`, `select_layer`,
      multi-layer detection.
- [ ] `src/tables.jl` — `PlacemarkTable`, Tables.jl interface.
- [ ] `src/time_parsing.jl` — needs a fixture KML containing `TimeStamp`
      and `TimeSpan`.
- [ ] `src/utils.jl`, `src/validation.jl`, `src/html_entities.jl`.
- [ ] `ext/FastKMLDataFramesExt.jl` — add `DataFrames` to the test env
      and a `DataFrame(read(file, KMLFile))` smoke test.
- [ ] `ext/FastKMLZipArchivesExt.jl` — add a small `.kmz` fixture and a
      KMZ roundtrip test.
- [ ] `ext/FastKMLMakieExt.jl` — at minimum a smoke test (optional given
      the size of the Makie dep tree in CI).

Shortcut to consider: extract the assertions from the benchmark's
correctness checks (name / description / WKT / coordinates equality vs
ArchGDAL on `ISO_GDAL_URLS`) into integration tests, gated behind a
network or `ENV` flag, so CI gets functional coverage of the parsing
pipeline without paying the benchmark's wall-clock cost.

## Code cleanup

- [ ] Prune `benchmark/cross_branch_benchmark.jl`: drop the
      `detect_features` cascade, `extract_placemarks_manual`, and the
      branch-vs-branch framing. With a single FastKML repo these features
      always exist; the script can just be a "scaling benchmark" on
      synthetic Point-only KMLs.
- [ ] Decide: keep or delete `benchmark/run_benchmarks.bat`. Windows-only
      and hardcodes `..\dev\KML` + the `parsing_perf_enhancement` branch
      — obsolete in the new repo.
- [ ] Add `benchmark/benchmark_results_*.json` to `.gitignore`. The
      `Manifest.toml` for the benchmark env is already covered by the
      existing `*Manifest.toml` pattern.
