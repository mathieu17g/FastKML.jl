# POC — FastKML lazy walker using v0.4 private Tokenizer API

Run date: 2026-05-11
Branch: `wip-xml-v0.4`. Tested in working tree; **not committed to src/macros.jl** (reverted to `eachchildnode` after measurement).

## Hypothesis

If `XML.Tokenizer` and `XML.TokenizerState` were exposed publicly in v0.4,
FastKML could replace `XML.eachchildnode` (which wraps `Tokenizer` in
`Iterators.Stateful` + `LazyChildIterator` + `Ref{Bool}` — ~3 wrapper
allocations per parent visited) with a custom walker that uses the raw
immutable Tokenizer directly. Expected gain: ~3 allocations × number of
parents visited recovered.

The synthetic walk-pattern bench
(`benchmark/walk_pattern_env/results_2026-05-11.md`) showed raw Tokenizer
DFS at `72.9 ms / 3M allocs / 281 MiB` vs `eachchildnode` at
`370.6 ms / 15M allocs / 1198 MiB` on N=100k flat document — a ×5 win on
all axes. We wanted to confirm whether this synthetic gain translates to
FastKML's real workloads (URL2/4/5/6).

## Three POC iterations

### POC v1 — naive iterator with `(Tokenizer, TokenizerState)` state tuple

Custom `Base.iterate` over an immutable struct holding `data` + `parent_pos`,
constructing `Tokenizer` on each `iterate` call, threading state as
`Tuple{Tokenizer, TokenizerState}`.

| URL | lazy POC v1 | lazy eachchildnode (baseline) | delta |
|-----|-------------|-------------------------------|-------|
| URL2 | 402 ms / 417 MiB | 395 ms / 415 MiB | +2% / +0.5% |
| URL4 | 690 ms / 1776 MiB | 688 ms / 1748 MiB | +0% / +1.6% |
| URL5 | 3307 ms / 6229 MiB | 3188 ms / 6004 MiB | +4% / +3.7% |
| URL6 | 2938 ms / 8412 MiB | 2862 ms / 8099 MiB | +3% / +3.9% |

→ **Slightly worse** than `eachchildnode`. The state-tuple
`Tuple{Tokenizer, TokenizerState}` (~64-72 bytes) exceeds Julia's SROA
stack-allocation threshold and boxes per iteration.

### POC v2 — state-tuple boxing avoided

`Tokenizer` stored in the iterator struct (constructed once); `state` field
is bare `TokenizerState` (no Tuple). Initial state set to
`TokenizerState(start, M_DEFAULT, no_token(data))` so the iterate path
never sees `Union{Nothing, TokenizerState}`.

| URL | lazy POC v2 | lazy eachchildnode | delta |
|-----|-------------|---------------------|-------|
| URL2 | 398 ms / 404 MiB | 395 ms / 415 MiB | +1% / -3% |
| URL4 | 688 ms / 1700 MiB | 688 ms / 1748 MiB | 0% / -3% |
| URL5 | 3151 ms / 5948 MiB | 3188 ms / 6004 MiB | -1% / -1% |
| URL6 | 2863 ms / 8023 MiB | 2862 ms / 8099 MiB | 0% / -1% |

→ Marginal mem gain (-1 to -3%) confirms state-tuple boxing was a real
factor but not the dominant one. Time identical to `eachchildnode`.

### POC v3 — POC v2 + `@inline` on `Base.iterate(it)` initial method

Aggressive `@inline` annotations on all custom iterate methods + initial
state constructor.

| URL | lazy POC v3 | lazy eachchildnode | delta |
|-----|-------------|---------------------|-------|
| URL2 | 401 ms / 399 MiB | 395 ms / 415 MiB | +1% / -4% |
| URL5 | 3219 ms / 5873 MiB | 3188 ms / 6004 MiB | +1% / -2% |

→ No further gain. Confirms the bottleneck is **neither** inlining **nor**
state-tuple boxing as primary cause.

## Diagnosis — what's left

Two compounding allocation sources that the private-API access can't fix:

1. **`XML.LazyNode(data, token, nodetype)` per yielded child**. URL5 has
   ~114k Placemarks × ~5 children per element × ~5 nesting levels =
   ~3M+ LazyNode allocations. `LazyNode{S}` contains `data::S` (a heap
   ref to the source String), so SROA can't fully stack-allocate it.
   The v0.3 `next!`/`prev!` pattern (PR #59) avoided this by mutating
   a single LazyNode wrapper — that primitive is *removed* by v0.4's
   immutable LazyNode design.

2. **`iterate(::Tokenizer, ::TokenizerState)` returns
   `Union{Nothing, Tuple{Token, TokenizerState}}`** (~80 bytes payload).
   Exceeds Julia's SROA stack-allocation threshold for the returned tuple.
   On the synth N=100k bench, raw Tokenizer DFS (no LazyNode allocations)
   still produced 3M allocations = ~1 alloc per visited token (3M tokens
   on a 100k-placemark document).

## Implication for upstream issues

The POC's negative result is itself the key finding. Exposing `Tokenizer`
publicly **is not sufficient** to recover the v0.3+#59 perf class on
FastKML real workloads. Two distinct upstream fixes would be needed:

### Issue candidate A (primary) — Streaming primitive that doesn't allocate per child

A v0.4-shaped equivalent of PR #59's `next!`/`prev!` pattern, where a
single wrapper is reused across the walk. Possible designs:

- **(α) Callback-style** `walk_children(node, callback)`. If `callback` is
  inlined by Julia, no LazyNode escapes the call frame → SROA wins.
  Constraint: caller bodies cannot use `break`/`continue` directly
  (closure-bounded). FastKML's existing macros use `continue` in 8+
  callsites — porting would require refactoring or auto-rewriting Expr.

- **(γ) Opt-in `MutableLazyNode`** type. Same shape as PR #59. Breaks
  v0.4's "everything immutable" purity, but is opt-in. The performance
  characteristics would mirror v0.3+#59 directly.

- **(δ) Pre-allocable / poolable `LazyChildIterator`**. Less invasive
  but only recovers wrapper allocations, not the per-child LazyNode
  cost. Probably insufficient.

### Issue candidate B (secondary) — `iterate(::Tokenizer)` Tuple boxing

`iterate(t::Tokenizer, st::TokenizerState)` returns
`Union{Nothing, Tuple{Token, TokenizerState}}`. The Tuple payload (~80 B)
exceeds Julia's SROA threshold for the *Union return value*, causing one
allocation per yielded token. Independently of any new API, optimizing
this would help every consumer of the tokenizer (eager parse, lazy walk,
sourcetext extraction, all of them).

Possible fixes upstream:

- Refactor `TokenizerState` to be smaller (currently 8 + 8 + ~32 = 48
  bytes due to embedded `pending::Token{S}`)
- Use a sentinel value instead of `Union{Nothing, …}` (e.g. a Tokenizer
  with `start > ncodeunits(data)`)
- Provide a callback iteration API that doesn't return Tuples at all

## Bottom line for Issue A

Don't claim "expose Tokenizer and we're done". The empirical answer is:

> v0.4's `Tokenizer` + `TokenizerState` are well-designed primitives, but
> exposing them publicly recovers ~80% of the synthetic-bench gain only
> when the consumer does not need to materialize per-child wrappers.
> FastKML — and any consumer building a typed DOM-like structure — does
> need such wrappers, and `LazyNode` v0.4 being immutable means each
> wrapper is a fresh allocation. To recover the v0.3+#59 perf class on
> such consumers, a streaming primitive that either (a) reuses a wrapper
> in place or (b) inlines a callback so the wrapper never escapes is
> necessary on top of public `Tokenizer` exposure.

## Reproduction

The POC source (POC v3 final state) is preserved at git commit
`<applied transiently to wip-xml-v0.4 working tree, reverted via
`git checkout 964feab -- src/macros.jl` after measurement>`.
The synth bench is reproducible via `benchmark/walk_pattern_env/`
on any v0.4 setup.

Key code excerpt of POC v3 (for reference):

```julia
struct _TokenizerChildrenIter{S}
    data::S
    tokenizer::XML.Tokenizer{S}    # constructed once at children_iter time
    parent_is_element::Bool
end

@inline _children_iter(node::XML.LazyNode) = ...
@inline _children_iter(n::XML.Node) = XML.children(n)

@inline _initial_state(tokenizer) =
    XML.TokenizerState(tokenizer.start, XML.XMLTokenizer.M_DEFAULT,
                       XML.XMLTokenizer.no_token(tokenizer.data))

@inline function Base.iterate(it::_TokenizerChildrenIter{S}) where {S}
    state = _initial_state(it.tokenizer)
    # ... skip parent attrs, then dispatch to _next_child
end

@inline Base.iterate(it::_TokenizerChildrenIter, state) =
    _next_child(it, state)

@inline function _next_child(it, state)
    tokenizer = it.tokenizer
    while true
        result = iterate(tokenizer, state)
        result === nothing && return nothing
        token, state = result
        # dispatch on token.kind, construct LazyNode for direct children,
        # skip subtrees on nested elements, etc.
    end
end
```
