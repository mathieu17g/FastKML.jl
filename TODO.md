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
- [x] **URL4 (`WRS-2_bound_world_0.kml`) — resolved on
      `wip-xml-next-bang-adoption + dev-combined`.** With both XML.jl
      fixes (#58, #59) adopted, FastKML is now ~1.18× *faster* than
      ArchGDAL on this file (256 ms vs 301 ms; previously 14% slower
      on `main`). The slowdown was driven by per-call XML allocations
      that the upstream PRs eliminate. Profile-wise, the dominant
      remaining cost is **structural** (~4.8 M `next_no_xml_space`
      calls / ~12× the logical token count per Placemark) because
      FastKML walks each Placemark's subtree multiple times — once in
      `_collect_placemarks_optimized!`, once in
      `extract_placemark_fields_lazy`, plus extra inside
      `parse_geometry_lazy` and `extract_text_content_fast`. A
      single-pass refactor (one tree walk dispatching by tag/depth)
      would roughly halve traversal cost on wide-and-shallow files;
      see the deferred-perf list below — the original concern
      ("FastKML slower on URL4") is resolved so we don't need it now.

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
    - **Round 3 (upstream PRs against XML.jl)**: the round-2 review
      had identified ~30 MiB of `XML.LazyNode` allocations per `next`
      and ~60 MiB of `Bool[false]` ctx allocations per `next_no_xml_space`
      as the top remaining sites; both lend themselves to small
      upstream fixes. Two PR-sized changes prepared in
      `mathieu17g/XML.jl`:
        - `perf-share-default-ctx` branch (~6 LOC): when
          `next_no_xml_space` is reached the document has no
          `xml:space` attribute, so the per-node ctx is always
          `Bool[false]` and never mutated — share the parent's instead
          of allocating a fresh `[false]` per call. Saves ~60 MiB on
          URL2.
        - `feature-next-bang` branch (~54 LOC): add `next!` / `prev!`
          methods that mutate a `LazyNode` in place. Strictly additive,
          documented aliasing contract. FastKML adoption (on
          `wip-xml-next-bang-adoption` branch) switches
          `@for_each_immediate_child` to `next!` and snapshots `child`
          at the three Layers.jl callsites that retain references.
          Combined with PR #1, drops URL2 cumulative memory 444 → 193
          MiB (-57%) and wall-clock 213 → 190 ms (-11%); 234 tests
          green; iso comparison vs ArchGDAL still ✔.
        - **Submitted**: PR
          [JuliaComputing/XML.jl#58](https://github.com/JuliaComputing/XML.jl/pull/58)
          (ctx share) and [#59](https://github.com/JuliaComputing/XML.jl/pull/59)
          (next!/prev!) — awaiting review. KML.jl#14 has been closed with
          a pointer back to FastKML.jl as the home for this work. Once
          #58/#59 land in a XML.jl release, bump the FastKML `[compat]`
          entry, merge `wip-xml-next-bang-adoption` into main, and
          remove the temporary `[sources] XML = …` override from
          `benchmark/Project.toml` and the `dev/` entry from
          `.gitignore`.
    - **Residual hot sites after round 3 (still structural)**:
      `Parsers.Result` per parse (~38 MiB), `Vector{Float64}` payload
      (~13 MiB), final `Vector{SVector{3,Float64}}` (~23 MiB), the
      `Raw` struct return inside XML.jl's `next_no_xml_space` (~60 MiB,
      would need making `Raw` mutable — a more invasive upstream
      change). Further wins would require replacing Parsers.jl with a
      hand-rolled Float64 scanner in the Coordinates FSM, or a
      `Raw`-mutating variant upstream.
- [ ] Evaluate skipping the double materialization
      (`KMLFile` tree → `PlacemarkTable` → `DataFrame`) by going
      `LazyKMLFile` → `DataFrame` directly when DataFrames is the
      consumer.
- [ ] Multi-layer extraction in a single pass. Surfaced by the URL5
      benchmark fix (`bf64708`): when a KML exposes N top-level layers
      and a consumer wants every feature, the current public API forces
      N independent `DataFrame(file; layer = k)` calls, each of which
      walks the `LazyKMLFile` tree from the root to find layer k and
      then iterates its placemarks. ArchGDAL's `getlayer` shares the
      C++ dataset, so its per-layer cost is near-zero. On URL5
      (qfaults.kmz, 8 thematic Folders, 114 k features) FastKML ends
      up ~10–15% slower than ArchGDAL end-to-end despite being faster
      per-feature; on `wip-xml-next-bang-adoption` (with the upstream
      XML.jl fixes adopted) the 8-layer iteration overhead is the
      dominant slowdown. Possible designs: a `DataFrame(file)` /
      `PlacemarkTable(file)` overload that walks the document **once**
      and assigns each Placemark to its containing layer in a single
      pass, or expose an iterator that yields `(layer_idx, placemark)`
      pairs the consumer can group however it wants.
- [ ] Single-pass per-Placemark extraction. Surfaced by the URL4
      profile (Apr 2026): each Placemark's subtree is currently walked
      ~12× the logical token count, because
      `_collect_placemarks_optimized!`,
      `extract_placemark_fields_lazy`, `parse_geometry_lazy`, and
      `extract_text_content_fast` each re-tokenize the same XML
      bytes. On URL4 this explains 387 MiB of `Raw` allocations in
      `next_no_xml_space` (~4.8 M calls for 28 k Placemarks). A
      refactor where one outer walk dispatches by tag/depth and
      threads field extraction inline would roughly halve traversal
      cost on wide-and-shallow files. Not urgent now that FastKML
      already beats ArchGDAL on URL4 (1.18× faster after the upstream
      XML.jl fixes), but worth doing if perf becomes a competitive
      pressure later.

## Test coverage

Current global coverage: **54.53%** (was 22.49% at session start —
+32.04 points). Six target modules went from 0% (or near-zero) to
74-100%, plus two real bugs were caught and fixed along the way.

Done in this session:
- [x] `src/Layers.jl` — `get_num_layers`, `get_layer_names`,
      `get_layer_info`, `select_layer` (by index, by name, error
      branches), `list_layers` smoke test, both eager + lazy paths,
      single-layer (example.kml) + multi-layer (synthetic) fixtures.
      Covered: 0% → 63.8%.
- [x] `src/tables.jl` — `PlacemarkTable` construction from each input
      type, `Tables.istable / rowaccess / schema / rows`, all four
      `parse_geometry_lazy` branches (Point / LineString / Polygon /
      MultiGeometry), `simplify_single_parts` toggle. Covered: 0% →
      79.6%.
- [x] `src/utils.jl` — 10 exported helpers: `find_placemarks` (filters),
      `count_features`, `get_bounds` (Point / Polygon / LineString /
      container), `extract_path`, `extract_styles`, `get_metadata`,
      `haversine_distance` (NYC↔LA known distance), `path_length`,
      `unwrap_single_part_multigeometry` (all branches),
      `merge_kml_files`. Covered: 1.9% → 80.6%.
- [x] `ext/FastKMLDataFramesExt.jl` — both method overloads
      (`DataFrame(path; lazy)` with `lazy=true` and `lazy=false`,
      `DataFrame(KMLFile)`, `DataFrame(LazyKMLFile)`), `layer` and
      `simplify_single_parts` keyword forwarding. Covered: 0% → 100%.
- [x] `ext/FastKMLZipArchivesExt.jl` — KMZ round-trip with `doc.kml`
      at root (standard) and `data/inner.kml` (fallback branch),
      both eager (KMLFile) and lazy (LazyKMLFile) reads, end-to-end
      DataFrame on a `.kmz` path. Covered: 0% → 77.5%.
- [x] `src/time_parsing.jl` — `parse_iso8601` across date /
      datetime / datetime-with-TZ / week date / ordinal date forms
      (extended + basic), invalid-string fallback (with and without
      `warn=false`), `is_valid_iso8601`, plus an integration KML with
      `<TimeStamp>` and `<TimeSpan>`. Covered: 0% → 74.3%. **Caught
      a real bug**: `parse_week_date` shadowed `Dates.dayofweek` with
      a local variable, breaking every week-date input; fixed in the
      same commit by renaming the local to `wday`.
- [x] `src/validation.jl` — `validate_coordinates` (scalar + vector),
      `validate_geometry` for each geometry type (Point, LineString,
      LinearRing-with-unclosed-branch, Polygon, MultiGeometry),
      `validate_document_structure` for Document and Folder
      (including empty-features and nested-Document branches).
      Covered: 0% → 74.8%. **Caught a curry-direction trap**:
      `occursin(needle)` is `Base.Fix2(occursin, needle)`, the
      *opposite* of what one would intuit; `contains(needle)` is
      the right choice for `any(.., issues)` patterns. Documented
      inline.

Still to do (low ROI / deferred):
- [ ] `src/html_entities.jl` — currently 39.3% (the
      `decode_named_entities` body is fully covered). The remaining
      60% is the `_load_entities` cache-build path which runs once
      per session and isn't exercised because the cache is populated.
      Best left alone unless we want to add a test that wipes the
      Scratch cache and forces a network rebuild.
- [ ] `ext/FastKMLMakieExt.jl` (61 LOC) — heavy Makie dep tree
      (~60+ transitive packages). Skip in CI; if needed, add a
      minimal `Plots`/`Makie`-free smoke test that just verifies
      method dispatch resolves once Makie is loaded.
- [ ] `src/FastKML.jl` (45 LOC, currently 37.8%) and
      `src/navigation.jl` (127 LOC, 1.6%) — leftover paths in the
      module entry-point and the navigation helpers; lower priority
      since they're internal plumbing.
- [ ] `src/field_conversion.jl` (188 LOC, 43.1%) — already partially
      covered transitively. Could be pushed higher with KML fixtures
      exercising more attribute conversions, but it's a long tail of
      small branches.

Shortcut still to consider: extract the assertions from the benchmark's
correctness checks (name / description / WKT / coordinates equality vs
ArchGDAL on `ISO_GDAL_URLS`) into integration tests, gated behind a
network or `ENV` flag, so CI gets functional coverage of the parsing
pipeline without paying the benchmark's wall-clock cost.

## Code cleanup

- [ ] **Dead-code sweep across the package.** Surfaced when adding the
      Validation testset: the `outerBoundaryIs === nothing` check in
      `validate_geometry(::Polygon)` was provably unreachable because
      `Polygon.outerBoundaryIs` is typed `LinearRing` (no `Nothing` in
      the union). Removed in that commit. To check for similar cases
      systematically, three complementary techniques:

    1. **Type-driven (cheap, scriptable)**: for every `field === nothing`
       (or `field !== nothing`) check across `src/`, look up
       `fieldtype(T, :field)` and flag any case where `Nothing` is not
       in the union. The validation.jl sweep this session showed 6/7
       checks legitimate, 1 dead — same script can run over the other
       63 nothing-checks in `utils.jl`, `Layers.jl`, `tables.jl`, etc.

    2. **Static analysis with [JET.jl](https://github.com/aviatesk/JET.jl)**:
       JET's `report_package(FastKML)` flags unreachable branches via
       type-narrowing inference, plus other issues like type
       instabilities and undefined references. More powerful than the
       grep approach, catches branches hidden behind multi-step
       inference. Setup: add JET to `test/Project.toml`, write a
       `test/jet_test.jl` that asserts no errors above some baseline.

    3. **Coverage-driven**: lines that stay 0% after a representative
       test suite include both untested code AND unreachable code.
       Cross-reference with (1) and (2) to discriminate. Lower
       priority since coverage isn't the primary metric.

      Recommended order: (1) first (a few lines of Julia, exhaustive
      and quick), (2) when JET configuration warrants the time.

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
