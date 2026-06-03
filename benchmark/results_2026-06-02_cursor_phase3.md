# Phase 3b — cursor-backed FastKML vs all baselines vs ArchGDAL (real files)

Initial 3-way run 2026-06-02; **refreshed 2026-06-03** to a single-epoch 5-config
table at `@benchmark seconds=10` (the 5 s run had ±~10% noise that flipped the
URL4 cursor-vs-ArchGDAL comparison). Julia 1.12.6, Darwin aarch64.

Configs, all measured fresh on the same machine/day:
- **v0.3.8 + #58 + #59 lazy** — FastKML `wip-xml-next-bang-adoption` (worktree) +
  XML `dev/XML.jl` (the `next!`/`prev!` DFS class; the only prior config that beat
  ArchGDAL on time 4/4). Fresh numbers match the 2026-05-11 run within noise.
- **v0.4 lazy / v0.4 eager** — FastKML `wip-xml-v0.4` + XML `dev/XML.jl-v0.4`
  (PR #54 head `e532a28`). (May-11's v0.4 numbers are stale — that was head
  `e7e21a7`, before the +10 commits incl. `children!()`; not used here.)
- **cursor** — `wip-xml-v0.4` + the bitstype-Token cursor (additive
  `CursorPlacemarkIterator`), XML `feature-cursor-bitstype-token`.
- **ArchGDAL** — from the v0.4 run (independent of FastKML's XML backend).

## Median time (ms) / allocated (MiB)

| file (rows) | v0.3.8+#58+#59 | v0.4 lazy | v0.4 eager | cursor | ArchGDAL |
|---|---|---|---|---|---|
| URL2 (5.4k) | 197 / 188 | 218 / 178 | 179 / 191 | 180 / 166 | 258 / 13 |
| URL4 (28.5k) | 257 / 480 | 448 / 155 | 422 / 296 | 311 / 92 | 303 / 25 |
| URL5 (114k) | 2284 / 1855 | 2673 / 1197 | 1803 / 1490 | 1676 / 966 | 2516 / 357 |
| URL6 (163k) | 1175 / 2316 | 2010 / 562 | 1797 / 998 | 1056 / 272 | 3348 / 155 |

(URL2 NY DEC enzones, URL4 Landsat WRS-2, URL5 USGS qfaults 8 folders, URL6 EPA
FRS 19k folders. `isequal(df_lazy, df_cursor)` holds on all four.)

## Findings (each verified against the table)

- **Cursor beats both v0.4 paths.** vs v0.4 lazy: faster AND leaner on 4/4. vs v0.4
  eager: leaner on 4/4; faster on 3/4 (tied on URL2, 180 vs 179). The cursor is the
  best FastKML path on these files.
- **Cursor recovers the v0.3.8+#58+#59 time class, and is far leaner than it.**
  Faster on time on 3/4; **slower only on URL4** (311 vs 257 — the flat 28k-polygon
  file, the least lazy-friendly profile). Memory is dramatically lower on 4/4:
  URL6 **272 vs 2316 MiB (×8.5)**, URL4 92 vs 480, URL5 966 vs 1855. So the
  bitstype-Token cursor matches the old fast class's speed at a fraction of its
  memory — the standout result.
- **Cursor vs ArchGDAL**: faster on time on 3/4 (URL2/5/6); **URL4 ~tied** (311 vs
  303, within run-to-run noise). NOT a 4/4 time win. ArchGDAL stays far lighter in
  memory (13–357 MiB) — inherent to its C++/GDAL core vs FastKML materializing
  Julia geometry structs + a DataFrame; orthogonal to the walk.

## Honest summary

The cursor is the best FastKML extraction path (beats v0.4 lazy and eager), and it
recovers the v0.3.8+#58+#59 ArchGDAL-beating *time* class while using far less
memory than any prior FastKML path — including that old class. The one weak spot is
URL4 (flat 28k polygons), where it is ~tied with ArchGDAL and slightly behind the
old class on time. The walk allocation is gone; the residual memory vs ArchGDAL is
struct + DataFrame materialization, not the walk.
