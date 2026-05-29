# Synth walk-pattern re-bench against current PR #54 head — 2026-05-29

**Companion to `results_2026-05-19_decomposition.md`.** Re-measures the
v0.4 lazy-walk techniques against the **current PR #54 head `e532a28`**
(+10 commits past the `e7e21a7` pin that issue #61's numbers were taken
on), and adds **technique 7** — the new `children!()` buffer-reuse API
(the poolable-`LazyChildIterator` direction — labelled δ in
`streaming_parser_research.md`; #61 describes it in prose, without the
label) that joshday landed in commit `9d129b8`.

Run date: 2026-05-29
Julia 1.12.6, Darwin aarch64. `@benchmark` budget: 3 s per measurement.
N = 100 000 placemark-shaped elements (~20.7 MiB), same synthetic doc as
the companion file.

Measured same-session: technique 4 from `dev/XML.jl@dev-combined`
(v0.3.8 + #58 + #59); techniques 3 / 6 / 7 from `dev/XML.jl-v0.4`
checked out at `e532a28`.

## Why re-bench

The 10 commits between `e7e21a7` and `e532a28` include direct
lazy-path + tokenizer perf work (`findnext` scans, skip-unescape,
`has_entities` wiring) **and** a new `children!()` API. Issue #61's
quantitative claim (v0.4 lazy regresses vs PR #59's `next!()`) is
measured on `e7e21a7`, so it could have gone stale. Two questions:
(1) do the perf commits narrow the gap? (2) does `children!()` (δ)
recover the streaming-cursor class?

## Results — same-session apples-to-apples

| Technique | Config | Time | Memory | Total allocs | vs tech 4 |
|---|---|---|---|---|---|
| **4** — `next!()` DFS | v0.3.8 + #58 + #59 | **56.5 ms** | **122.9 MiB** | 1.9M | baseline |
| 3 — `eachchildnode` | v0.4 `e532a28` | 366.7 ms | 1174.9 MiB | 14.5M | ×6.5 / ×9.6 |
| 6 — raw `Tokenizer` + recursive `LazyNode` | v0.4 `e532a28` | 308.9 ms | 1037.6 MiB | 12.0M | ×5.5 / ×8.4 |
| **7 — `children!()` reused buffer (δ)** | v0.4 `e532a28` | **391.3 ms** | **1107.4 MiB** | 12.5M | **×6.9 / ×9.0** |

## Drift vs the `e7e21a7` pin (issue #61's numbers)

| Technique | `e7e21a7` (#61) | `e532a28` (now) | Δ |
|---|---|---|---|
| 4 — `next!()` | 57 ms / 123 MiB | 56.5 ms / 122.9 MiB | stable |
| 3 — `eachchildnode` | 351 ms / 1198 MiB | 367 ms / 1175 MiB | within noise |
| 6 — raw `Tokenizer` | 293 ms / 1038 MiB | 309 ms / 1038 MiB | within noise |

The 10 commits' perf work did **not** materially move the synthetic
walk-pattern numbers — techniques 3 and 6 are within run-to-run noise
of the `e7e21a7` measurements. **Issue #61's regression claim holds at
the current PR #54 head.**

## Technique 7 finding — `children!()` (δ) does not close the gap

`children!(buf, node)` collects a node's children into a caller-provided
`Vector{LazyNode}`, reused across sibling groups (one buffer per depth
level in this bench). vs the next-best v0.4 paths:

- vs `eachchildnode` (tech 3): −14% allocs (12.5M vs 14.5M), −6% memory
  (1107 vs 1175 MiB) — the buffer-reuse saves the per-call `Vector`
  allocation, as expected.
- but time is **not** improved (391 vs 367 ms — a second pass over the
  buffer costs more than the fused `eachchildnode` walk), and it remains
  **×6.9 slower / ×9.0 more memory than `next!()` (tech 4)**.

The dominant cost — **one `LazyNode` materialized per child** (~12.5M
allocations on N=100k) — is intrinsic to "yield a LazyNode per child"
and is left untouched by buffer reuse. This is direct empirical
confirmation of #61's point that a poolable `LazyChildIterator` "would
address only the wrapper allocation share and not the dominant per-event
cost; insufficient on its own" — now tested against the actual
`children!()` API joshday shipped, not a hypothetical.

`next!()` (tech 4) avoids the per-child cost by mutating a **single**
`LazyNode` across the whole walk (1 wrapper alloc total) — the
streaming-cursor class `children!()` does not reach.

## Note on the pin + script compat

- `dev/XML.jl-v0.4` was temporarily checked out to `e532a28` for this
  run, then **restored to the `e7e21a7` pin** (the documented bench
  baseline; `main` ref preserved it).
- `60725db` ("Namespace token kinds and document API") renamed the
  tokenizer kinds: `XMLTokenizer.TOKEN_OPEN_TAG` → `XMLTokenizer.TokenKinds.OPEN_TAG`
  (prefix dropped, namespaced). `walk_pattern.jl` and
  `decompose_techniques.jl` now use a small version adapter
  (`_kind(nm)`) so techniques 5/6 run against both the old and new API.
- Technique 7 is guarded by `isdefined(XML, :children!)` — skipped on
  versions predating `9d129b8`.

## Reproduction

```sh
# Re-pin the v0.4 clone to the current PR #54 head (then restore after):
git -C dev/XML.jl-v0.4 fetch origin && git -C dev/XML.jl-v0.4 checkout e532a28
julia --project=benchmark/walk_pattern_env \
    benchmark/walk_pattern_env/decompose_techniques.jl dev/XML.jl-v0.4   # tech 3/6/7
julia --project=benchmark/walk_pattern_env \
    benchmark/walk_pattern_env/decompose_techniques.jl dev/XML.jl        # tech 4
git -C dev/XML.jl-v0.4 checkout main   # restore the e7e21a7 pin
```
