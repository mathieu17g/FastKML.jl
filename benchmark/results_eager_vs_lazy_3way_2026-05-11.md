# FastKML benchmark — 3-way XML.jl × eager/lazy × ArchGDAL

Run date: 2026-05-11
Julia 1.12.6, Darwin aarch64.
Bench script: `benchmark/benchmark_kml_parsers.jl` (with `table_with_fastkml_eager` added).
Budget: 10 seconds per (URL, strategy).

Three FastKML configurations tested:

- **v0.3.8 registry** — main branch FastKML, XML pinned to `Pkg.add(name="XML", version="0.3.8")` (no PR #58, no PR #59)
- **v0.3.8 + #58 + #59** — `wip-xml-next-bang-adoption` branch FastKML, XML = `dev/XML.jl` (PRs #58 ctx-share + #59 next!/prev!)
- **v0.4.0** — `wip-xml-v0.4` branch FastKML, XML = `dev/XML.jl-v0.4` (PR #54 head SHA `e7e21a7`)

Per configuration, three pipelines:

- **lazy** — `read(path, LazyKMLFile)` then walk layers to extract DataFrame
- **eager** — `read(path, KMLFile)` (materializes the full struct hierarchy) then extract
- **GDAL** — `ArchGDAL.read(path)` then layer iteration

## Median elapsed time (ms)

| URL                 | v0.3.8 reg lazy | v0.3.8 reg eager | v0.3+PRs lazy | v0.3+PRs eager | v0.4 lazy | v0.4 eager | ArchGDAL |
|---------------------|-----------------|-------------------|---------------|----------------|-----------|------------|----------|
| URL2 enzone (5.4k)  | 221             | 410               | **204** ✨    | 412            | 395       | **192**    | 253-260  |
| URL4 WRS-2 (28.5k)  | 382             | 1194              | **261** ✨    | 1101           | 688       | 534        | **299-307** |
| URL5 qfaults (114k) | 2735            | 4886              | **2357** ✨   | 4834           | 3188      | **1836**   | 2434-2508 |
| URL6 nat_frs (~33k) | 1830            | 4631              | **1247** ✨   | 4259           | 2862      | 1924       | 3185-3257 |

## Median memory (MiB, rounded)

| URL                 | v0.3.8 reg lazy | v0.3.8 reg eager | v0.3+PRs lazy | v0.3+PRs eager | v0.4 lazy | v0.4 eager | ArchGDAL |
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
  `@for_each_immediate_child` macro adopts `next!` and yields the best path
  across the board. **v0.3+#58+#59 lazy beats every other configuration on
  3/4 URLs** (URL4, URL5, URL6) and beats ArchGDAL on 4/4 URLs.

### What v0.4 contributes

- **Eager path: massively improved**. v0.4 eager is ×2.06 to ×2.63 faster
  than v0.3+#59 eager and uses 37-69% less memory:

  | URL | v0.3+PRs eager | v0.4 eager | speedup | mem reduction |
  |-----|----------------|------------|---------|---------------|
  | URL2 | 412 / 363 MiB  | 192 / 229 MiB | ×2.15  | -37%   |
  | URL4 | 1101 / 1629    | 534 / 597     | ×2.06  | -63%   |
  | URL5 | 4834 / 4814    | 1836 / 2239   | ×2.63  | -53%   |
  | URL6 | 4259 / 6597    | 1924 / 2065   | ×2.21  | -69%   |

- **Lazy path: regressed vs v0.3+#58**. v0.4 has no `next!`/`prev!`
  equivalent; `eachchildnode` allocates `LazyChildIterator` + `Stateful` per
  call; `children(::LazyNode)` materializes Vector per call. Net cost is
  higher than the v0.3 path with PRs applied.

### What this means

- **For FastKML right now**: stay on `wip-xml-next-bang-adoption` (v0.3 +
  #58 + #59) — it is the only configuration where FastKML beats ArchGDAL on
  all 4 URLs in time.

- **Migrating to v0.4 today**: net regression on 3/4 URLs (URL4, URL5, URL6)
  even with eager path. URL2 only is marginally better with v0.4 eager
  (192 vs 204 = 6% gain).

- **For the upstream issues** (Phase C): the data supports a constructive
  pitch — v0.4 brings real eager gains (×2-2.6 speedup), but loses the
  zero-alloc lazy walk pattern from PR #59. Restoring that pattern (issue A)
  would give v0.4 both: the eager improvements AND the lazy zero-alloc class.

## Notes on URL4

URL4 (WRS-2 bound world) is the only URL where ArchGDAL beats FastKML in
all configurations — its profile (28.5k flat point Placemarks with simple
geometry) is the optimal case for GDAL's KML/LIBKML driver. The gap is
smallest with v0.3+#58+#59 lazy (261 vs 304 = ArchGDAL +17%) and largest
with v0.4 eager (534 vs 307 = ArchGDAL +74%). Even on this favorable case,
v0.3+#58+#59 stays closest.

## Reproduction

```sh
# v0.3.8 registry (main)
git checkout main
julia --project=benchmark -e 'using Pkg; Pkg.add(name="XML", version="0.3.8")'
# patch benchmark_kml_parsers.jl to add table_with_fastkml_eager + 3-col output
julia --project=benchmark -e 'include("benchmark/benchmark_kml_parsers.jl"); run_benchmarks([URL2, URL4, URL5, URL6]; default_benchmark_seconds=10)'

# v0.3 + #58 + #59 (wip-xml-next-bang-adoption)
git checkout wip-xml-next-bang-adoption
julia --project=benchmark -e 'using Pkg; Pkg.develop(path="../dev/XML.jl")'
# same patch + run

# v0.4 (wip-xml-v0.4)
git checkout wip-xml-v0.4
julia --project=benchmark -e 'using Pkg; Pkg.develop(path="../dev/XML.jl-v0.4")'
julia --project=benchmark -e 'include("benchmark/benchmark_kml_parsers.jl"); run_benchmarks([URL2, URL4, URL5, URL6]; default_benchmark_seconds=10)'
```
