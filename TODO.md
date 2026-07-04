# TODO

Active work, deferred decisions, lessons learned, and an archive of
completed milestones. For released changes, see
[`CHANGELOG.md`](CHANGELOG.md).

---

## Active items

> **RESUME HERE — 2026-07-03.** **XML.jl v0.4.0 est enregistré et publié**
> ([release](https://github.com/JuliaData/XML.jl/releases/tag/v0.4.0)) et la
> migration FastKML est **mergée dans `main`** (PR #1, 2026-07-03) : compat
> `XML = "0.4"` résolu depuis le registre (dev-pin `[sources]` supprimé),
> `CI.yml` en place, historique purgé de `notes/`, `benchmark/` élagué.
> Re-bench 07-03 : le chemin cursor bat ArchGDAL 4/4 —
> `benchmark/results_2026-07-03_xml-v04-tip_rebench.md`. Détail complet dans
> l'archive « Migration XML.jl v0.4 — SHIPPED ».
>
> **Next :**
> 1. Dérouler « Release readiness » (ci-dessous) — la pré-condition XML est levée.
> 2. Veille upstream : XML v0.5 (flat node store prototypé — build ~2× plus
>    rapide), `hash(::Node)` ([XML.jl#55](https://github.com/JuliaData/XML.jl/issues/55)),
>    XLSX v0.12.0 (adoption jumelle).

### Performance — pistes (deferred)

FastKML already beats ArchGDAL on all four benchmark URLs (see archive
below). These are remaining structural optimizations that would
recover the post-`next!` allocation residual; not urgent.

- [ ] **Piste 1 — Radical single-pass per-Placemark refactor.** The
      remaining tracked allocations after `_peek_text_content` are
      structural: ~14 MiB at `tables.jl:207` (outer walk in
      `extract_placemark_fields_lazy`) + ~5 MiB at `tables.jl:104`
      (Polygon walk in `parse_geometry_lazy`). Each
      `@for_each_immediate_child` allocates one `LazyNode` upfront via
      `XML.next(_node)`, scaled by placemark count (~28k on URL4 →
      14 MiB). Removing them requires **fusing** the walks: a single
      deep walk per Placemark dispatching by `(tag, depth)` and
      threading field extraction inline (instead of having
      `parse_geometry_lazy` re-walk Polygon's children, walk them as
      part of the outer pass and identify boundaries by depth=2
      inside a `Polygon` open at depth=1). Affects
      `extract_placemark_fields_lazy`, `parse_geometry_lazy`, and
      `parse_linear_ring_lazy`. Worth ~20 MiB tracked allocs on URL4
      (50% of post-`next!` residual), modest wall-clock gain (~3-5%).

- [ ] **Piste 2 — Hand-rolled Float64 scanner in the Coordinates
      FSM.** Top non-walk hot sites after `next!` +
      `_peek_text_content`: `Coordinates.jl:111` (7.2 MiB) and
      `Coordinates.jl:130` (4.8 MiB) — together ~12 MiB on URL4.
      Origin: `Parsers.Result{Float64}` allocated per parsed float
      (~38 MiB cumulative on URL2 per the round-3 analysis), plus
      `Vector{Float64}` payload growth. Replace
      `Parsers.parse(Float64, view(...))` with a hand-rolled scanner
      embedded directly in the Automa FSM that drives
      `parse_coordinates_automa`; write floats straight into the
      pre-`sizehint!`'d vector without `Parsers.Result` indirection.
      Trade-off: ~50 LOC of float parsing logic + Automa state
      machine grows. Defer until coordinate path becomes the dominant
      cost.

- [ ] **Skip double materialization?** The path `KMLFile` tree →
      `PlacemarkTable` → `DataFrame` is the eager route. Lazy goes
      `LazyKMLFile` → `PlacemarkTable` → `DataFrame` directly (no
      materialization overhead). Investigate whether the eager path
      can also be shortened, or whether this item is now subsumed by
      the lazy default. Lower priority — verify relevance first.

### Real-world fixture coverage

- [ ] **Exhaustive Google KML samples corpus.** Walk the reference
      index (https://developers.google.com/kml/documentation/kmlreference),
      extract every embedded KML snippet, save each as a fixture
      under `test/fixtures/google_kml_reference/<element>.kml`, add a
      parametric testset asserting each round-trips through eager +
      lazy paths without warnings or errors. Cross-cuts with the
      audit script: any snippet that produces an "Unhandled Tag"
      warning becomes a candidate to model.

### Test coverage — long tail (low ROI / deferred)

Current global coverage **~55%** (see archive for full breakdown).
Remaining low-priority modules:

- [ ] `src/html_entities.jl` (39%) — `_load_entities` cache-build path
      runs once per session and isn't exercised because the cache is
      populated. Best left alone unless we add a test that wipes the
      Scratch cache.
- [ ] `ext/FastKMLMakieExt.jl` (61 LOC) — heavy Makie dep tree (60+
      transitive packages). Skip in CI; if needed, a minimal
      Makie-free smoke test verifying method dispatch.
- [ ] `src/FastKML.jl` (45 LOC, 38%) and `src/navigation.jl` (127 LOC,
      1.6%) — module entry-point and navigation helpers; lower
      priority since they're internal plumbing.
- [ ] `src/field_conversion.jl` (188 LOC, 43%) — already partially
      covered transitively. Could be pushed higher with KML fixtures
      exercising more attribute conversions, but it's a long tail of
      small branches.

### Code quality

- [partial] **JET dead-code sweep — 11 reports deferred to triage.**
      One typo fixed (`Base.eltype(::EagerLazyPlacemarkIterator)`,
      commit `e1dab7a`). Remaining ~11 non-noise reports specific to
      FastKML:
      - 2× `FieldError` on `.value` access (Array / OrderedDict
        types) — likely in `field_conversion.jl` or attribute paths.
      - 6× `iterate(::Nothing)` / `length(::Nothing)` on
        `src/Layers.jl` paths — probably false positives where JET
        can't propagate an earlier `nothing`-guard to the iteration
        site; restructure or `@assert` may suffice.
      - 2× `convert(Bool, Tuple{})` inside `_iter_feat`
        (`src/tables.jl:204-214`) — empty-tuple `else` branch
        interacting with `&&`/`||` chains under broadcasting.
      - 1× `BoundsError` on `Tuple{Float64, Float64}[3]` — 2-tuple
        indexed at position 3; suspect Coord2/Coord3 confusion in a
        coordinate-access site.

      None caught by the current test suite (happy-path coverage).
      Each is either a guarded branch JET can't see through (false
      positive — annotate or restructure) or a latent bug like the
      typo above (real, dormant).

      Procedure to rerun:
      ```sh
      julia -e '
        using Pkg
        Pkg.activate(temp=true)
        Pkg.develop(path=".")
        Pkg.add("JET")
        using FastKML, JET
        report_package(FastKML)
      '
      ```

### Benchmark — diverging-file diagnostics

- [ ] After URL3/URL6, sweep across the improved diagnostics
      (`diff @ char N`, WKT `.val`) on any other diverging (non-iso)
      file we come across and decide row-by-row which interpretation
      is correct against the raw XML. Most current divergences are
      now resolved; this is a "keep eyes open" item rather than
      active work.

---

## Deferred decisions

### Fallthrough strategy — Option A vs Option B

Option A (filter `nothing` returns from `object()`, keep the warning)
shipped in Phase 1 of the OGC sweep. Option B (introduce an
`UnknownKMLElement{tag}` type that preserves the raw XML subtree for
user-side extraction) is **not** taken; revisit only if real-world
fixtures surface tags users want to inspect without us modeling them.

### Audit script CI wiring

`tools/audit_kml_coverage.jl` chose **(ii) one-shot tool, run manually**.
Re-evaluate to (i) "fail CI on regression" or (iii) "informational CI
warning" if drift between XSD and `TAG_TO_TYPE` becomes a recurring
problem.

### Release readiness — version bump 0.1.0 → 0.2.0?

Substantial unreleased work documented in `CHANGELOG.md`. Bump and
tag when the pre-conditions hold:

- [x] ~~Patching XML.jl from FastKML decided~~ — sans objet : XML v0.4.0 est
enregistré (2026-07-03) et le dev/ override supprimé (PR #1) ;
`Pkg.add("FastKML")` résout XML depuis General.
- [x] CHANGELOG.md current and reviewed — 2026-07-04 : entrée « XML.jl
      v0.4 adoption » ajoutée, section Performance réécrite sur le
      chemin cursor livré (table 07-03), Internal complété (CI, purge
      notes/, élagage benchmark/).
- [x] One last run of the full suite against the tagged tree —
      2026-07-04, verte (XML v0.4.0 du registre) ; benchmarks =
      `benchmark/results_2026-07-03_xml-v04-tip_rebench.md` (src
      identique au tag).
- [ ] Decide on registry submission (General registry, dedicated
      registry, or stay url-based). **Seul item restant — décision à
      prendre ; v0.2.0 taguée + GitHub Release en attendant.**

---

## Insights worth remembering

These are non-obvious lessons surfaced during development. Worth
keeping handy for similar future situations.

### Auto-populate mechanism for tag registration

`_populate_tag_to_type` in `src/types.jl:669-703` auto-registers every
concrete subtype of `KMLElement` by name. Adding a new modeled tag
costs essentially:

1. Define a `Base.@kwdef mutable struct NewTag <: …` somewhere.
2. The registry picks it up by name automatically.
3. Manual aliases (in the same function) only needed when XML name
   doesn't match struct name (e.g. `<Url>` → `Link`,
   `<atom:author>` → `AtomAuthor`, `<linkSnippet>` → `Snippet`).

So "modeling N more tags" scales linearly with N, no architectural
lift. Phase 5 of the OGC sweep added 3 types (`Metadata`,
`gx_ViewerOptions`, `gx_option`) in ~30 LOC of types.jl + 1 alias.

### Abstract-type field as dispatch

When a struct declares an abstract-type field (e.g.
`Camera.TimePrimitive ::TimePrimitive`), `assign_complex_object!`
pass 1 routes any subtype there via `child_type <: non_nothing_type`.
Phase 4 of the OGC sweep added `gx_TimeStamp` and `gx_TimeSpan` as
`TimePrimitive` subtypes and **didn't need to touch Camera/LookAt** —
the dispatch picked them up automatically. Future-proof for any
other-namespace TimePrimitive (e.g. an `xal:` extension) that wants
to ride the same field.

### Profile-driven decisions: hypotheses age fast

The "multi-layer iteration overhead is dominant" hypothesis (perf #2,
ca. April 2026) was overstated by the time we tried to act on it: the
upstream XML.jl fixes (PRs #58/#59, `next!` adoption) had already
displaced the bottleneck to per-Placemark walk depth. The `:all`
optimization shipped as an API improvement but didn't move the perf
needle as expected.

Lesson: **re-profile before optimizing**. A profile from 2-3 weeks
ago is suspect; one from 2-3 months ago is almost certainly stale.
Cost of profiling (~5 min with `@benchmark` + `Profile`) is trivial
relative to optimizing the wrong site.

### Outillage avant action

The XSD audit script (`tools/audit_kml_coverage.jl`) — written as
Phase 2, MIDWAY through the OGC sweep, not at the end — turned the
remaining phases from "guided by bugs" into "guided by spec". Without
it, Phase 5 (Metadata, gx:ViewerOptions) would likely never have
happened: those tags weren't hitting in any real-world fixture we
were testing. The audit revealed them as gaps. Cost of writing the
script (~30 min) was repaid in the same session by surfacing two
gaps that would have shipped as silent missing coverage.

### Aliasing contract in `next!` adoption

Switching `@for_each_immediate_child` from `XML.next` (allocates a
fresh `LazyNode` per step) to `XML.next!` (mutates one LazyNode
in place) gave a ~50% memory reduction on URL4. The trade-off: bodies
that **store** `child` into a longer-lived collection must explicitly
snapshot via `XML.LazyNode(child.raw)`, otherwise every stored
reference silently tracks the last iteration's position. Three
callsites in `Layers.jl` needed this fix. Document the contract on
the macro itself (done in `src/macros.jl`'s docstring).

---

## Done — milestones (archive)

### Migration XML.jl v0.4 — SHIPPED — 2026-07-03

L'item actif « Migration v0.4 — anticipée » (bannières 05-10 / 05-21, plan
Phase B/C, setup `dev/XML.jl-v0.4/`) a abouti : l'engagement upstream (issue
#61 + commentaires #54/#58/#59, puis le chantier v0.4 côté JuliaData) a livré
une **API streaming publique** (`Cursor`, Token isbits) qui récupère la classe
perf de FastKML — et **XML v0.4.0 est enregistré le 2026-07-03**
([release](https://github.com/JuliaData/XML.jl/releases/tag/v0.4.0), migration
guide). FastKML adopté via **PR #1** : compat `"0.4"`, dev-pin `[sources]`
supprimé, `CI.yml` ajouté (Julia 1 + lts), suite verte contre le registre
(locale + run `main` GitHub). Re-bench 4 corpus vs la baseline 06-02 : lazy
−9…−30 %, cursor −11…−47 % — **cursor devant ArchGDAL 4/4**
(`benchmark/results_2026-07-03_xml-v04-tip_rebench.md`). Ménage : historique
purgé de `notes/` (filter-repo, arbre byte-identique), labo
`benchmark/walk_pattern_env/` + docs de mai supprimés (conclusions shippées,
détail dans l'historique git), `dev/XML.jl-v0.4/` effacé. La décision différée
« Patching XML.jl from FastKML » (contourner la latence upstream) est devenue
sans objet.

### Upstream Phase C — issues posted — 2026-05-20

Opened [JuliaComputing/XML.jl#61](https://github.com/JuliaComputing/XML.jl/issues/61)
("A StAX-style streaming primitive for v0.4 — recovering FastKML's lazy
walk class without the LazyNode-as-cursor hack") + companion comments on
PRs #54, #58, #59.

Diverged from the Phase C plan in two ways worth recording:
- **One issue, not two.** The planned "Issue B" (children() regression vs
  PR #58) was folded into #61's body + the PR #58 comment rather than
  filed separately.
- **Reframed, not 4-open-options.** #61 argues a *two-layer StAX design*
  (iterator-based `Tokenizer` + cursor-based `CursorNode`) with a
  recommendation, informed by a SOTA survey of 9 streaming parsers
  (`notes/upstream_issues/streaming_parser_research.md`). The α/β/γ/δ
  open-questions framing and the failed-PoC narrative were dropped.
- Supporting artefacts on `wip-xml-v0.4`: `streaming_parser_research.md`,
  `benchmark/walk_pattern_env/` (synth bench + `decompose_techniques.jl`),
  `benchmark/rootcause_iterate_tuple_allocation_2026-05-11.md` (renamed
  from `poc_fastkml_raw_tokenizer_*`), `results_eager_vs_lazy_3way_*`.
- Cross-package signal: @TimG1964 (XLSX.jl) had flagged the `next`/`prev`
  removal on PR #54 in March 2026 — cited in #61 as an isomorphic use case.

Branches pushed public for the issue's permalinks: `wip-xml-v0.4` +
`wip-xml-next-bang-adoption` (FastKML), `dev-combined` (mathieu17g/XML.jl,
= v0.3.8 + #58 + #59).

### OGC 2.2 + Google `gx:` completeness sweep — closed 2026-05-08

5-phase sweep brought concrete-element coverage to **56/58 OGC** + 
**15/15 Google `gx:`**. The 2 missing OGC are `<outerBoundaryIs>` and
`<innerBoundaryIs>`, intentionally handled via `Polygon`'s special
parsing path.

- Phase 1: fallthrough hardening in `parse_kmlfile` (filter
  non-`KMLElement` returns from `object()`, the "Unhandled Tag"
  warning still fires).
- Phase 2: `tools/audit_kml_coverage.jl` XSD-based audit.
- Phase 3: `<NetworkLinkControl>` modeled.
- Phase 4: `gx_TimeStamp` / `gx_TimeSpan` on `<Camera>` / `<LookAt>`.
- Phase 5: `<Metadata>` (opaque preservation) +
  `<gx:ViewerOptions>` / `<gx:option>`.

See `CHANGELOG.md` ([Unreleased], "Added — KML element coverage")
for the per-element details.

### Performance milestone — FastKML beats ArchGDAL on 4/4 URLs (2026-05-08)

| URL | Time vs ArchGDAL | Memory vs `main` |
|---|---|---|
| URL2 enzone | +25% faster | -31% |
| URL4 WRS-2 | +20% faster | -53% |
| URL5 qfaults | +8% faster (was -15%) | -48% |
| URL6 national_frs | +62% faster | -54% |

Drivers (on `wip-xml-next-bang-adoption` + `dev/XML.jl/dev-combined`):
`XML.next!` adoption + `_peek_text_content` raw-level text extraction.
Headline: URL5 24pp swing (-15% → +8%). See `CHANGELOG.md`
([Unreleased], "Performance") for the full breakdown.

### Test coverage round — 22% → ~55% (2026-04 to 2026-05)

7 modules went from 0% / near-zero to 74-100%:
Layers, tables, utils, validation, time_parsing,
FastKMLDataFramesExt, FastKMLZipArchivesExt. Plus modeled-type
testsets covering all newly modeled OGC + `gx:` elements.

Two real bugs caught and fixed:
- `parse_week_date` shadowed `Dates.dayofweek` (broke ISO 8601 week-date inputs).
- `Base.eltype(::EagerLazyPlacemarkIterator)` referenced undefined `iter` (JET-found typo).

ArchGDAL parity integration tests extracted from the benchmark, gated
by `FASTKML_INTEGRATION=true`; run via
`FASTKML_INTEGRATION=true julia --project=. -e 'using Pkg; Pkg.test()'`.

### Benchmark URL investigations — all 4 closed

- **URL1 (`USEDO.kmz`)**: non-conformant comma-only-delimited
  coordinates from KMLer. FastKML lenient by design (recovers
  geometry); ArchGDAL strict (reduces ring to single point). Not a
  bug. Tested in `test/runtests.jl`, documented in
  `docs/src/coordinate_parsing.md`.
- **URL3 (`Aglim1.kmz`)**: same root cause as URL1.
- **URL4 (`WRS-2_bound_world_0.kml`)**: originally 14% slower than
  ArchGDAL; `next!` adoption + `_peek_text_content` flipped to 20%
  faster.
- **URL6 (`national_frs.kmz`)**: three findings —
  (i) `decode_named_entities` byte-slice bug fixed (`889a275`);
  (ii) layer-semantics divergence reconciled (concat all ArchGDAL
  leaf-folder layers; FastKML exposes 3 top-level layers, ArchGDAL
  flattens to 19 122 leaf folders);
  (iii) name normalization made symmetric (`strip + decode_named_entities`
  on both sides).
  Residual: row 48072 has malformed `<coordinates>,,0</coordinates>` —
  FastKML returns `Float64[]`, ArchGDAL substitutes `(0,0,0)`.
  Documented as accepted divergence.

### Memory allocation profile rounds

- **Round 1 (commit `4d9408e`)**: tracked allocations 240 → 123 MiB
  (-49%) on URL2 via `extract_text_content_fast` 0/1-fragment
  fast-path + `parse_coordinates_automa` heuristic `sizehint!`.
- **Round 2**: tested `Parsers.xparse` + `XML.LazyNode[]` array
  typing; neither moved the needle. `SubArray` was elided; the
  `@for_each_immediate_child` allocation was structural to
  `XML.next` (fixed in Round 3).
- **Round 3 (upstream)**: prepared two PRs against
  `mathieu17g/XML.jl` —
  [#58](https://github.com/JuliaComputing/XML.jl/pull/58) ctx-share
  (~6 LOC, ~60 MiB savings) and
  [#59](https://github.com/JuliaComputing/XML.jl/pull/59) `next!` /
  `prev!` (~54 LOC). Status 2026-04-30: joshday pointed at
  [XML.jl#54](https://github.com/JuliaComputing/XML.jl/pull/54), a
  major renovation; both held pending. Local working baseline:
  `dev/XML.jl/` checkout on `dev-combined` + the FastKML adaptation
  on `wip-xml-next-bang-adoption`. The
  `[sources] XML = …` override in `benchmark/Project.toml` and the
  `dev/` entry in `.gitignore` stay in place.

### Code cleanup

- JET dead-code sweep on 2026-04-30: 185 raw reports → 70 non-noise
  → ~12 specific to FastKML → 1 fixed (the
  `EagerLazyPlacemarkIterator` typo), 11 deferred (still in active
  list above).
- Benchmark scripts pruned: `cross_branch_benchmark.jl` →
  `scaling_benchmark.jl` (407 → 110 lines), `run_benchmarks.bat`
  deleted, JSON results dump removed.
