# Re-bench 2026-07-03 — FastKML vs XML.jl v0.4 tip `6a23e51`

Re-run of the Phase 3b harness (`run_cursor_bench.jl` protocol: 4 real files × lazy/eager/cursor/ArchGDAL,
`@benchmark seconds = 10`, `isequal(df_lazy, df_cursor)` checked) after fast-forwarding `dev/XML.jl-v0.4`
from `024ce24` to the current `v0.4-dev` tip **`6a23e51`** (post fix-loop + follow-ups). Reference =
`results_2026-06-02_cursor_phase3.md` (XML @ `e532a28`-era configs, same protocol).

Machine comparability: sandboxed Apple M5 vs the reference's bare machine — anchored by **ArchGDAL**
(XML-independent): URL2 249 vs 258 ms, URL4 304 vs 303 (±3 % → directly comparable); URL5 −9 %, URL6 +15 %
(big-file anchor drift → use anchor-normalized deltas there).

FastKML full test suite: **green** against the new pin before benching
(`Testing FastKML tests passed`, XML v0.4.0 loaded from `dev/XML.jl-v0.4`).

## Median time (ms) / allocated (MiB)

| file (rows) | lazy | eager | cursor | ArchGDAL |
|---|---|---|---|---|
| URL2 (5 411)   | 198 / 178  | 178 / 191  | **161 / 166** | 249 / 13  |
| URL4 (28 557)  | 314 / 149  | 448 / 296  | **164 / 86**  | 304 / 25  |
| URL5 (114 037) | 2441 / 1197 | 1783 / 1490 | **1341 / 966** | 2298 / 357 |
| URL6 (163 426) | 1810 / 564 | 2241 / 998 | **709 / 273** | 3853 / 155 |

`cur==lazy: true` on all four files (content equivalence holds at the tip).

## vs the 2026-06-02 reference

- **Cursor improved everywhere**: URL2 −11 %, URL4 **−47 %** (311→164), URL5 −20 % (−12 % anchor-normalized),
  URL6 −33 % (**−42 % normalized**). Consistent with the fix-loop's single-pass `unescape` (touches the
  `is_simple_value` hot path) + tip-side improvements.
- **Lazy improved moderately**: −9 / −30 / −9 / −10 %.
- **Eager (Node) unchanged within noise**: ±8 % anchor-normalized (the harness's own documented noise is
  ~±10 %); allocations identical. The `:structural` default and fix-loop checks cost nothing measurable here.
- **Cursor now beats ArchGDAL 4/4** on time (the reference had URL4 narrowly lost, 311 vs 303) while
  allocating 2.7–13× more (ArchGDAL's C-side memory is invisible to Julia's tracker — as in the reference).

**Conclusion: no regression from the v0.4 fix loop — FastKML got *faster* on the lazy and cursor paths,
and the Node path is unchanged.** The Phase 6.8(3) "re-measure against v0.4-as-it-will-be" concern is
settled in the favorable direction.

Note (FastKML-side, orthogonal to XML): one `Coordinates` warning during the URL6 run —
`Parsed 1 numbers from ",,0…" … Returning empty coordinates` — the lenient coordinate parser hitting a
degenerate source string; worth a look someday, not an XML v0.4 artifact.
