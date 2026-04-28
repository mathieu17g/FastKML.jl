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
- [ ] **URL3 (`Aglim1.kmz`) — pending.** Same upstream domain (ESDAC,
      KMLer-generated) and same WIP note as URL1, so very likely the
      same root cause. Verify once and either remove from the diverging
      list or document as a known shared case.
- [ ] **URL6 (`national_frs.kmz`) — pending.** Diverges on **row count**
      rather than per-row geometry; the WIP note even suggests ArchGDAL
      itself struggles on this file. Different category from URL1/URL3
      and worth a fresh look.
- [ ] After URL3/URL6, sweep across the improved diagnostics
      (`diff @ char N`, WKT `.val`) on any other anisotropic file we
      come across and decide row-by-row which interpretation is correct
      against the raw XML.
- [ ] Investigate URL4 (`WRS-2_bound_world_0.kml`, 28k flat Placemarks):
      FastKML is ~14% slower than ArchGDAL there, while it is 25–99%
      faster on URL2 and URL5. Likely a hot path in `xml_parsing.jl` for
      very wide-and-shallow files.

## Performance

- [ ] Profile memory allocations with `julia --track-allocation=user` on
      URL2 or URL5 (`*.mem` files); identify hot sites in `tables.jl`,
      `Layers.jl`, `xml_parsing.jl`. FastKML allocates 35–58× more than
      ArchGDAL on the iso URLs benchmarked so far (cumulative
      `BenchmarkTools.memory`, not peak RSS — but still very high).
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
