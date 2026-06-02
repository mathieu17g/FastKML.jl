# Phase 3b — cursor-backed FastKML vs LazyNode vs ArchGDAL (real files)

Date: 2026-06-02. Julia 1.12.6, Darwin aarch64. `@benchmark seconds=5` medians.
XML.jl @ `mathieu17g/XML.jl@feature-cursor-bitstype-token` (bitstype Token + cursor).
FastKML @ `wip-xml-v0.4` with the additive `CursorPlacemarkIterator` (commit 2d3447e).
Runner: `benchmark/run_cursor_bench.jl`. Path: `table_with_fastkml{,_cursor}` →
`DataFrame` per layer.

| File | rows | curs==lazy | lazy (ms/MiB) | cursor (ms/MiB) | ArchGDAL (ms/MiB) |
|------|-----:|:----------:|:-------------:|:---------------:|:-----------------:|
| URL2 | 5 411 | ✓ | 220 / 178 | **207 / 166** | 262 / 13 |
| URL4 | 28 557 | ✓ | 449 / 155 | **307 / 92** | 316 / 25 |
| URL5 | 114 037 | ✓ | 2696 / 1197 | **1724 / 966** | 2574 / 357 |
| URL6 | 163 426 | ✓ | 1982 / 562 | **1069 / 272** | 3278 / 155 |

(URL2 enzone2022, URL4 WRS-2 bounds, URL5 USGS qfaults 8 folders, URL6 EPA
national_frs 19k folders.)

## Findings

- **Content**: `isequal(df_lazy, df_cursor)` holds on all 4 (full DataFrame
  equality incl. the `Union{Missing,Geometry}` column). The cursor path is a
  drop-in for the LazyNode path.
- **Cursor vs LazyNode**: faster on 4/4 (×1.06 URL2 → ×1.85 URL6) and leaner on
  4/4 (×1.07 → ×2.07). The gain grows with structural depth/repetition — URL6's
  19k-folder hierarchy roughly halves both time and memory, because that is where
  the LazyNode path's per-visited-node re-tokenize + allocation dominated. Flat
  URL2 barely moves. Confirms the #61 thesis (per-token allocation was the lazy
  walk's cost) and that bitstype Token + single-cursor removes it.
- **Cursor vs ArchGDAL — beats it on TIME 4/4** (207<262, 307<316, 1724<2574,
  1069<3278): re-attains and (URL4/5/6) exceeds the old v0.3.8+#59 ArchGDAL-beating
  class (old wins URL2 204/188, URL4 261/480, URL5 2357/1855, URL6 1247/2320 — the
  cursor matches/beats time and is far leaner: URL6 272 vs 2320 MiB).
- **Memory vs ArchGDAL**: ArchGDAL still uses much less (13–357 MiB) — inherent to
  its C++/GDAL core vs FastKML materializing Julia geometry structs + a DataFrame.
  Orthogonal to the walk; the cursor closes FastKML's *self* gap (halves URL6),
  not the struct-materialization gap.

## Next

Promote the cursor path to the default LazyKMLFile extraction (thread a flag /
swap `_placemark_iterator`) so the win lands in the public `DataFrame(file)` API;
the 577-test suite validates (cursor == lazy). Gated on user go-ahead.
