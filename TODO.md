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
