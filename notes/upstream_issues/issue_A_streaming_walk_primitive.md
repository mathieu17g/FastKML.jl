# Issue A — Streaming walk primitive for `LazyNode` in v0.4

**Status: draft — pending validation before opening on github.com/JuliaComputing/XML.jl**

---

## Title

Streaming walk primitive for `LazyNode`: recovering zero-allocation deep walks under v0.4's immutable design

## Body

Hi @joshday, congrats on the v0.4 rewrite — the tokenizer is genuinely elegant, and the eager-parse improvements are real. I'm reporting a use case where I haven't been able to recover an allocation pattern that worked in v0.3, and I'd appreciate your thinking on a few design directions.

### Context

I maintain [FastKML.jl](https://github.com/mathieu17g/FastKML.jl), an OGC KML reader/writer built on `XML.jl`. The package supports two read modes:

- **Eager** (`read(path, KMLFile)`): materializes the entire KML hierarchy as typed Julia structs (Document → Folder → Placemark → Geometry → …)
- **Lazy** (`read(path, LazyKMLFile)`): keeps an `XML.LazyNode` tree and walks it on-demand for tabular extraction (DataFrame)

The lazy path is critical for files like USGS qfaults (114k placemarks, 1+ GB materialized) where eager would exhaust memory.

### What works well in v0.4

The eager path improved substantially. On four reference URLs ([benchmark setup](#reproduction)):

| URL                 | eager v0.3.8+#58+#59 | eager v0.4.0  | speedup |
|---------------------|----------------------|----------------|---------|
| URL2 enzone (5.4k)  | 412 ms / 363 MiB     | 192 ms / 229 MiB | **×2.15** |
| URL4 WRS-2 (28.5k)  | 1101 ms / 1629 MiB   | 534 ms / 597 MiB | **×2.06** |
| URL5 qfaults (114k) | 4834 ms / 4814 MiB   | 1836 ms / 2239 MiB | **×2.63** |
| URL6 nat_frs (~33k) | 4259 ms / 6597 MiB   | 1924 ms / 2065 MiB | **×2.21** |

That's a ×2-2.6 wall-clock improvement and 37-69% memory reduction on the eager path. Excellent.

### Where the lazy path regressed

The same four URLs, lazy mode:

| URL  | lazy v0.3.8+#58+#59 | lazy v0.4.0 | slowdown |
|------|---------------------|--------------|----------|
| URL2 | 204 ms / 188 MiB    | 395 ms / 405 MiB | ×1.94 |
| URL4 | 261 ms / 480 MiB    | 688 ms / 1707 MiB | ×2.64 |
| URL5 | 2357 ms / 1855 MiB  | 3188 ms / 6004 MiB | ×1.35 |
| URL6 | 1247 ms / 2320 MiB  | 2862 ms / 8099 MiB | ×2.30 |

So the v0.3+#58+#59 lazy path beats the v0.4 eager path on URL4/URL5/URL6 — meaning we can't migrate to v0.4 without a net loss.

### Where the gap comes from

I wrote a [self-contained synthetic benchmark](https://github.com/mathieu17g/FastKML.jl/blob/wip-xml-v0.4/benchmark/walk_pattern_env/walk_pattern.jl) (no FastKML dep, only XML + BenchmarkTools) that walks an N-placemark document with six strategies, tested across three XML.jl configurations. On N=100k:

| Strategy                                | v0.3.8 registry | v0.3.8 + #58 + #59 | v0.4.0       |
|-----------------------------------------|-----------------|---------------------|--------------|
| `Node + children()`                     | 32 ms / 0 KiB             | 25 ms / 0 KiB              | 21 ms / 0 KiB               |
| `LazyNode + children()`                 | 278 ms / 1180 MiB         | 202 ms / 872 MiB           | 378 ms / 1280 MiB           |
| `LazyNode + eachchildnode()`            | n/a                       | n/a                        | 370 ms / 1197 MiB           |
| `LazyNode + next!() DFS` (PR #59)       | n/a                       | **61 ms / 123 MiB**         | n/a                        |
| `raw Tokenizer DFS` (private, **no LazyNode**) | n/a                | n/a                        | **72 ms / 281 MiB**         |
| `raw Tokenizer + recursive LazyNode`    | n/a                       | n/a                        | 309 ms / 1062 MiB           |

The lower-bound for a zero-allocation lazy walk is ~61 ms on v0.3+#59 (a single `LazyNode` wrapper reused via in-place mutation). The public v0.4 API tops out at ~370 ms.

The good news first: directly using v0.4's `Tokenizer` + `TokenizerState` (currently inside `XML.XMLTokenizer` but not exported) gets to **72 ms** — within striking distance of the v0.3 number. The underlying primitive is the right shape.

The catch: that 72 ms is for a walker that *never constructs a `LazyNode`* — it just accumulates token spans directly. As soon as I add LazyNode construction per child + recursion (the "raw Tokenizer + recursive LazyNode" row above, which mirrors FastKML's actual lazy pattern), the cost jumps to 309 ms — only ~17% faster than `eachchildnode`.

### Cost decomposition of the v0.4 lazy walk

Comparing strategies 3, 5, and 6 reveals where each component pays:

| Component                                                                     | Cost      | % of `eachchildnode` total |
|-------------------------------------------------------------------------------|-----------|----------------------------|
| Tokenization (strategy 5: flat DFS, no LazyNode allocation)                   | 72 ms     | 19% |
| **LazyNode allocation per yielded child + recursion**                          | **237 ms** | **64%** |
| `eachchildnode` wrappers (`Stateful` + `LazyChildIterator` + `Ref{Bool}`)     | 61 ms     | 17% |
| **Total (strategy 3 — `eachchildnode`)**                                      | **370 ms** | 100% |

The headline: exposing `Tokenizer` publicly would let consumers reclaim the 17% wrapper share. The dominant 64% — the per-child `LazyNode` allocation — needs a separate API affordance to recover, because v0.4's `LazyNode` is immutable and a fresh allocation is required for each yielded child.

### POC — Can FastKML adopt the raw Tokenizer directly?

To confirm the synthetic decomposition transfers to real workloads, I tried three iterations of a FastKML walker built on `XML.Tokenizer` instead of `eachchildnode` (full writeup [here](https://github.com/mathieu17g/FastKML.jl/blob/wip-xml-v0.4/benchmark/poc_fastkml_raw_tokenizer_2026-05-11.md)). All three variants ended up **essentially equivalent** to `eachchildnode` on FastKML's real workloads:

| URL | lazy `eachchildnode` | lazy POC v3 (raw Tokenizer) |
|-----|----------------------|------------------------------|
| URL2 | 395 ms / 415 MiB | 401 ms / 399 MiB |
| URL4 | 688 ms / 1748 MiB | 688 ms / 1700 MiB |
| URL5 | 3188 ms / 6004 MiB | 3219 ms / 5873 MiB |
| URL6 | 2862 ms / 8099 MiB | 2863 ms / 8023 MiB |

This matches strategy 6 in the synthetic bench: ~17% better than `eachchildnode` synth, similar marginal gain here. The wrapper allocations went away, but FastKML still pays the 64% LazyNode-per-child cost (the dominant share). The two secondary residuals confirmed:

1. **One `LazyNode(data, token, nodetype)` allocation per yielded child**. On URL5, ~3M+ such allocations. v0.4's immutable `LazyNode` cannot be reused — PR #59's `next!`/`prev!` allocated exactly one wrapper for an entire walk by mutating its `raw` field in place.

2. **`iterate(::Tokenizer, ::TokenizerState)` produces ~1 alloc per visited token** (3M allocs / 100k placemarks = ~one per token, visible in strategy 5 numbers). The returned `Union{Nothing, Tuple{Token, TokenizerState}}` payload (~80 B) appears to exceed Julia's SROA stack-allocation threshold.

So exposing `Tokenizer` publicly would help when consumers don't need a per-child wrapper (strategy 5: ×5 over `eachchildnode`), but **wouldn't move the needle for consumers that materialize one** — which is essentially anyone building a typed DOM-like view on top of `LazyNode`.

### Design questions

I'd love your thinking on any of these directions — not asking you to commit to one, just laying out what I've considered:

#### (α) Callback-style walker: `walk_children(node, callback)`

```julia
walk_children(parent) do child
    # callback body sees a LazyNode; if @inline'd by Julia, child
    # never escapes the call frame → SROA stack-allocates the wrapper
end
```

Pros: leverages Julia's `@inline` to fold the wrapper into the caller's stack frame. Aligns with v0.4's immutable design.

Cons: callback bodies can't use `break`/`continue` naturally (closure-bound). Workaround: bodies use `return` (semantically equivalent to `continue`) and a sentinel return value for `break`.

#### (β) Public `Tokenizer` + `TokenizerState`

Just `export` `Tokenizer`, `TokenizerState`, `Token`, `TokenKind`, and the `TOKEN_*` constants. Optionally add small helpers (`skip_element!`, `peek_kind`).

Pros: zero new code. Consumers gain the ~5× from the synth bench above.

Cons: doesn't recover the per-child `LazyNode` cost for DOM-like consumers. Also forces them to depth-track manually.

#### (γ) Opt-in `MutableLazyNode`

A small mutable wrapper analogous to v0.3 + PR #59:

```julia
mutable struct MutableLazyNode{S}
    data::S
    token::Token{S}
    nodetype::NodeType
end

next!(o::MutableLazyNode) = ...   # mutates `o.token` in place
```

Pros: directly recovers v0.3+#59's zero-allocation behavior. Users opt in by choosing `MutableLazyNode` over `LazyNode`.

Cons: introduces mutability into v0.4 (against the rewrite's design philosophy). Has the aliasing contract from PR #59 that consumers must respect.

#### (δ) Poolable / reusable `LazyChildIterator`

Allow callers to provide a pre-allocated iterator that's reused across calls. Recovers wrapper allocations but not per-child `LazyNode` cost.

Probably insufficient alone — combine with one of the above.

### Reproduction

All measurements are reproducible from:

- Synthetic bench: [`benchmark/walk_pattern_env/`](https://github.com/mathieu17g/FastKML.jl/tree/wip-xml-v0.4/benchmark/walk_pattern_env) on the `wip-xml-v0.4` branch of FastKML.jl. Self-contained, no FastKML dep.
- FastKML real workloads: [`benchmark/results_eager_vs_lazy_3way_2026-05-11.md`](https://github.com/mathieu17g/FastKML.jl/blob/wip-xml-v0.4/benchmark/results_eager_vs_lazy_3way_2026-05-11.md).
- POC analysis: [`benchmark/poc_fastkml_raw_tokenizer_2026-05-11.md`](https://github.com/mathieu17g/FastKML.jl/blob/wip-xml-v0.4/benchmark/poc_fastkml_raw_tokenizer_2026-05-11.md).

Versions tested:

- v0.3.8 registry — `Pkg.add(name="XML", version="0.3.8")`
- v0.3.8 + PRs #58 + #59 — local branch `dev-combined` on [mathieu17g/XML.jl](https://github.com/mathieu17g/XML.jl)
- v0.4.0 — JuliaComputing/XML.jl@main SHA `e7e21a7` (PR #54 head as of 2026-05-11)

Julia 1.12.6, Darwin aarch64. `@benchmark` budget 10 s per (URL, strategy) for real workloads, 3 s per (N, strategy) for synth.

### Related

- [PR #58](https://github.com/JuliaComputing/XML.jl/pull/58) (ctx-share in `next_no_xml_space`) — naturally resolved by v0.4's refactor, no action needed.
- [PR #59](https://github.com/JuliaComputing/XML.jl/pull/59) (`next!` / `prev!` for `LazyNode`) — the v0.3 implementation of pattern (γ) above. The discussion thread on that PR has prior thinking on the aliasing contract.
- [Issue/PR for #54 discussion of `prev`/`next` removal](https://github.com/JuliaComputing/XML.jl/pull/54#discussion_r...) — @TimG1964 flagged a similar concern for XLSX.jl in March; their use case is single-pass forward, where `eachchildnode` works fine. FastKML's deep+repeated pattern is what makes the gap visible.

Thanks for considering — happy to refine the benchmark, prototype a specific design, or open a draft PR if any direction looks promising.

---

## Notes for our own review before posting

- [ ] Validate every chiffre against `benchmark/results_eager_vs_lazy_3way_2026-05-11.md` and `benchmark/walk_pattern_env/results_2026-05-11.md`
- [ ] Ensure tone is collaborative — recognize eager gains first
- [ ] Avoid pushing one specific design — present 4 as open questions
- [ ] Keep mention of TimG1964 / PR #59 in "Related" (factual, not adversarial)
- [ ] Mention reproducibility prominently
- [ ] Final length: ~1200 words (this draft ~1100), should fit comfortably in a GitHub issue
