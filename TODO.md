# TODO

Active work, deferred decisions, lessons learned, and an archive of
completed milestones. For released changes, see
[`CHANGELOG.md`](CHANGELOG.md).

---

## Active items

> **RESUME HERE — 2026-05-21.** Upstream "Phase C" is **done and posted**:
> the streaming-primitive issue is live as
> [JuliaComputing/XML.jl#61](https://github.com/JuliaComputing/XML.jl/issues/61),
> with companion comments on PRs #54 / #58 / #59. It shipped a *reframed*
> design — two-layer StAX (iterator-based `Tokenizer` + cursor-based
> `CursorNode`), **with a recommendation** — not the 4-open-options
> (α/β/γ/δ) framing the Phase C plan below describes. The planned
> children()-regression "Issue B" was **folded into #61 + the PR #58
> comment**, not filed separately. Full executed state in the archive
> entry "Upstream Phase C — issues posted (2026-05-20)".
>
> ⚠️ **Naming clash**: "Issue B" in the Phase C plan = the `children()`
> regression. It is **unrelated** to the UTF-16-input bug (also nicknamed
> "Issue B" in a later session), which was filed from a different package
> and has no FastKML footprint.
>
> **Next trigger is external** — joshday's response on #61, or PR #54
> merging. PR #54 is still active: head advanced `e7e21a7` → `e532a28`
> (+10 commits) by 2026-05-21, so the "stay / keep anticipating"
> criterion below holds. The v0.4 migration stays gated on (a) #54
> merging and (b) a streaming primitive landing. The `dev/XML.jl-v0.4/`
> clone stays pinned at `e7e21a7` for bench reproducibility — do not
> bump it without re-running the 3-way bench.

### Migration v0.4 — anticipée sur cette branche `wip-xml-v0.4`

**Finalité** : être *day-zero ready* lors du merge de
[`JuliaComputing/XML.jl#54`](https://github.com/JuliaComputing/XML.jl/pull/54)
("WIP XML.jl v0.4: Rewrite of internals, streaming tokenizer, XPath
support, and bug fixes" par joshday). Cette PR est mature — 9 semaines
ouverte, polish phase depuis fin avril, 14/15 CI verts (le seul fail
est XLSX.jl downstream que joshday s'engage à fixer). Estimation de
merge **mode 6-10 semaines** (mi-juin à mi-juillet 2026), avec la
rédaction d'une présomption à 25%/50%/25% optimiste/médian/pessimiste.

**Pourquoi anticiper plutôt qu'attendre** : la migration touche le
cœur de FastKML (macros d'itération, parsing lazy, tokenizer). Faire
le travail en amont permet (i) de **valider l'estimation perf**
(-25-35% wall-clock + -30-45% mémoire vs `wip-xml-next-bang-adoption`,
voir `CHANGELOG.md`), (ii) de **cartographier toutes les cassures
d'API** sur un terrain stable, (iii) de pouvoir **contribuer à la PR**
si on trouve des bugs en cours de route.

**Setup local** :
- `dev/XML.jl-v0.4/` est un clone de `joshday/XML.jl@main` épinglé sur
  le HEAD de la PR #54 (SHA `e7e21a7…` au 2026-04-24).
- Remotes configurés : `origin` = `joshday/XML.jl` (lecture upstream),
  `mathieu17g` = `mathieu17g/XML.jl` (push pour ouvrir une PR vers la
  PR #54 si nécessaire).
- `[sources] XML = {path = "dev/XML.jl-v0.4"}` dans `Project.toml`
  bypasse le registre pour cette branche uniquement.
- `dev/` est gitignored. Pour reproduire le setup sur une autre
  machine :
  ```sh
  cd dev/
  git clone https://github.com/joshday/XML.jl XML.jl-v0.4
  cd XML.jl-v0.4
  git checkout e7e21a7265f2bf8a0bc1d0018fbf871e5aa0e587
  git remote add mathieu17g https://github.com/mathieu17g/XML.jl.git
  ```

**Première cartographie** (sondée par `julia --project=. -e 'using FastKML'`
au 2026-05-10) :
- ❌ `XML.AbstractXMLNode` n'existe plus en v0.4 — utilisé dans
  `src/types.jl:68` et propagé partout.
- (suite de la cartographie à faire au cours de la migration —
  rewrite des macros, drop des snapshots `XML.LazyNode(child.raw)`
  dans Layers.jl, suppression de `_peek_text_content` au profit du
  `value()` SubString-natif, adaptation de `extract_placemark_fields_lazy`
  et `parse_geometry_lazy` à `children(node)` retournant un Vector.)

**Stay/leave criteria** :
- **Stay (continue à anticiper)** tant que la PR #54 reste active
  (commits récents, pas d'abandon explicite).
- **Update** quand joshday push de nouveaux commits — `git fetch
  origin && git checkout <new-SHA>` dans `dev/XML.jl-v0.4/`, puis
  `Pkg.resolve` côté FastKML. Mettre à jour la mention du SHA
  ci-dessus.
- **Retire** quand v0.4 est sur le General registry — supprimer le
  `[sources]`, bumper `[compat] XML = "0.4"` dans `Project.toml`,
  merger ce branch dans `main`, supprimer `dev/XML.jl-v0.4/`.

**Effort estimé restant** : 2.5-4.5 jours de migration (rewrite des
3 macros, adaptation tables.jl + xml_parsing.jl + Layers.jl, tests,
profile/benchmark v0.4).

#### Benchmark 3-way 2026-05-10 — v0.4 naïve est 2-3× PLUS LENTE que wip-xml-next-bang

Run identique à `benchmark_kml_parsers.jl` sur URL2/4/5/6 :

| URL                 | wip-xml-next-bang (#58+#59) | wip-xml-v0.4 (PR #54 naïf) | ArchGDAL  |
|---------------------|-----------------------------|----------------------------|-----------|
| URL2 enzone (5.4k)  | **195 ms**                  | 448 ms (×2.30)             | 250 ms    |
| URL4 WRS-2 (28.5k)  | **261 ms**                  | 858 ms (×3.29)             | 297 ms    |
| URL5 qfaults (114k) | **2345 ms**                 | 3873 ms (×1.65)            | 2425 ms   |
| URL6 national_frs   | **1254 ms**                 | 3369 ms (×2.69)            | 3253 ms   |

Mémoire (KiB) :
| URL  | wip-xml-next-bang | wip-xml-v0.4   | ratio |
|------|-------------------|----------------|-------|
| URL2 | 192 459           | 503 202        | ×2.6  |
| URL4 | 491 357           | 2 136 307      | ×4.3  |
| URL5 | 1 899 831         | 7 857 701      | ×4.1  |
| URL6 | 2 372 652         | 10 751 067     | ×4.5  |

**Diagnostic** : ma migration utilise `XML.children(::LazyNode)` qui matérialise eagerly un Vector{LazyNode} par appel. FastKML walke en profondeur **multiple fois par fichier** (Document → Folder → Placemark → name/desc/geom → coords...) → ~170k Vector allocations sur URL4 vs 0 dans le pattern streaming `XML.next!` de wip.

L'estimation initiale -25-35% wall-clock était basée sur les benchmarks PARSE de joshday. Pas sur le pattern itération deep+repeated de FastKML.

**Conséquence** : `wip-xml-v0.4` reste **fonctionnellement correct** (577/577 tests) mais **PAS perf-cible**. `wip-xml-next-bang-adoption` reste la baseline performante.

#### Phase C — bench + upstream issues — ✅ DONE 2026-05-20 (issues posted; see status block at top of Active items + archive). Bench tables below kept as reference data.

**État** : 2 benchs reproductibles capturés. Phase B (eachchildnode adoption) sur wip-xml-v0.4 (`964feab`). Tout commité.

##### Bench FastKML 3-way × eager/lazy × ArchGDAL (commit `fb3a18e`)

**`benchmark/results_eager_vs_lazy_3way_2026-05-11.md`** — détail complet.

**Best config par URL — temps (ms)** :

| URL | v0.3.8 reg | v0.3+PRs lazy | v0.3+PRs eager | v0.4 lazy | v0.4 eager | GDAL |
|-----|-----------|---------------|----------------|-----------|------------|------|
| URL2 | 221 lazy | **204** ✨    | 412            | 395       | 192        | 256  |
| URL4 | 382 lazy | **261** ✨    | 1101           | 688       | 534        | 304  |
| URL5 | 2735 lazy | **2357** ✨  | 4834           | 3188      | 1836       | 2460 |
| URL6 | 1830 lazy | **1247** ✨  | 4259           | 2862      | 1924       | 3215 |

**v0.3+#58+#59 lazy est best sur 3/4 URLs ET beats ArchGDAL sur 4/4** (état idéal actuel).

**v0.4 améliore eager massivement** (×2-2.6 plus rapide vs eager v0.3+#59, -37 à -69% mem) MAIS le `next!` DFS pattern n'a pas d'équivalent → lazy v0.4 régresse.

##### Décision technique : ne PAS migrer main sur v0.4 maintenant

Migrer FastKML → v0.4 maintenant = **net-loss sur 3/4 URLs** (URL4, URL5, URL6). Seul URL2 voit un mince gain (192 vs 204 = +6%).

**Stratégie correcte** : rester sur `wip-xml-next-bang-adoption` pour l'instant. Engager Phase C upstream. Quand Phase C aboutit et v0.4 a un primitif streaming → puis migrer.

##### Bench synth standalone walk-pattern (commit `2499873`)

`benchmark/walk_pattern_env/walk_pattern.jl` + `results_2026-05-11.md`. **Self-contained**, pas de FastKML dep — directement PR-able upstream. Détecte les APIs via `isdefined` et adapte les stratégies par version.

Sur N=100k placemarks synthétiques :

| Strategy                  | v0.3.8 registry | v0.3.8 + #58 + #59     | v0.4.0           |
|---------------------------|-----------------|-------------------------|------------------|
| Node + children() (eager) | 32 ms / 0       | 25 ms / 0               | 21 ms / 0        |
| LazyNode + children()     | 278 ms / 1180 MiB | **202 ms / 872 MiB**  | **365 ms / 1280 MiB** ⚠️ |
| LazyNode + eachchildnode()| n/a             | n/a                     | 375 ms / 1198 MiB |
| LazyNode + next!() DFS    | n/a             | **61 ms / 123 MiB** ✨   | n/a              |

##### Diagnostic 5 points pour issues

1. **PR #58 (ctx-share)** : -27% temps / -25% mem sur `LazyNode + children()` path. Scope plus large que décrit. 9.2M allocs économisées sur 100k pm.
2. **PR #59 (`next!` DFS)** : seule API qui atteint comportement O(1) alloc/walk. 1.9M allocs vs 10-20M children-based. ×3.3 plus rapide, ×7 moins mémoire.
3. **v0.4 régresse `children()` lazy vs v0.3+#58** : ×1.8 plus lent (365 vs 202 ms), ×1.5 mem. Gain ctx-share intrinsèque MAIS plus que compensé par allocations `LazyChildIterator`+`Stateful(Tokenizer)`.
4. **v0.4 `eachchildnode` ≠ alternative à `next!`** : marginal vs `children()` (-6% mem, +3% temps). Pas la classe perf de #59.
5. **Net** : v0.3+#59 best path → v0.4 best path = **×6 plus lent, ×10 plus de mémoire**.

##### Plan 2 issues distinctes — ✅ POSTED 2026-05-20 (executed version differs from this plan)

> What actually shipped: **a single issue** —
> [#61](https://github.com/JuliaComputing/XML.jl/issues/61), the streaming
> primitive, reframed around a two-layer StAX design **with a
> recommendation** (not the α/β/γ/δ open-questions framing planned below;
> the PoC/failed-attempt narrative was set aside as it weakened the
> argument). The planned "Issue B" (children() regression) was **not
> filed separately** — folded into #61's body and the PR #58 comment. The
> original plan is kept below for the record.

**Issue A** — `Streaming walk primitive for LazyNode (regression vs PR #59 next!())` :
- Headline : "v0.4 lacks the O(1)-allocation walk pattern that PR #59 demonstrated on v0.3"
- Référence bench `benchmark/walk_pattern_env/` (3-way) + résultats `results_2026-05-11.md`
- Présente le gap 61ms → 365ms (×6 régression sur le best lazy path)
- Use case : deep+repeated lazy walk (FastKML, mais argumentation indépendante du package)
- Propose 4 options de design comme **questions ouvertes** à joshday (pas comme demandes) :
  - α : `walk_children(node, callback)` style visitor
  - β : exposer `Tokenizer` + helpers depth-tracking publics
  - γ : `MutableLazyNode` opt-in
  - δ : `LazyChildIterator` poolable / pré-allocable
- Tone : "I observed X, here is reproduction, what's your thinking?" pas "you must add Y"

**Issue B** — `LazyNode + children() net regression vs v0.3.8 + PR #58` :
- Headline : "v0.4 LazyNode + children() is 1.8x slower / 1.5x more memory than v0.3.8 + PR #58 on flat lazy walk"
- Référence le même bench
- Diagnostic : le coût intrinsèque `ctx-copy` éliminé en v0.4 (good), MAIS introduit en v0.4 le coût `LazyChildIterator` + `Stateful(Tokenizer)` par `children()` interne. Net = perte.
- Plus mineure que A, mais c'est une régression directe sans changement d'API → plus facile à corriger côté joshday probablement (optimiser le path interne)

##### Pour reprendre la session suivante

```sh
cd /Users/mathieu/Code/FastKML.jl
git checkout wip-xml-v0.4   # à 2499873
# Lire TODO.md section "Phase C — 2 issues upstream"
# Lire benchmark/walk_pattern_env/results_2026-05-11.md
# Action C.1.A : rédiger l'issue A en markdown local (.github/ISSUE_TEMPLATE/ ou docs/)
# Action C.1.B : rédiger l'issue B
# Action C.2 : valider avec utilisateur avant ouverture sur GitHub
```

Fichiers de référence pour la rédaction :
- `benchmark/walk_pattern_env/walk_pattern.jl` — script bench
- `benchmark/walk_pattern_env/results_2026-05-11.md` — résultats bruts 3 tailles
- `dev/XML.jl-v0.4/src/lazynode.jl:270-303` — `eachchildnode` impl
- `dev/XML.jl/src/XML.jl:138-170` — `next!`/`prev!` impl PR #59
- `dev/XML.jl/src/Raw.jl:428-470` — `next_no_xml_space` PR #58 ctx-share

Setup pour reproduire bench :
```sh
julia --project=benchmark/walk_pattern_env -e 'using Pkg; Pkg.add(name="XML", version="0.3.8")'  # v0.3.8 reg
julia --project=benchmark/walk_pattern_env -e 'using Pkg; Pkg.develop(path="dev/XML.jl")'        # v0.3+PRs
julia --project=benchmark/walk_pattern_env -e 'using Pkg; Pkg.develop(path="dev/XML.jl-v0.4")'   # v0.4
julia --project=benchmark/walk_pattern_env benchmark/walk_pattern_env/walk_pattern.jl
```

---

#### Phase B/C — Phase B exécutée : NO-GO (RESUME HERE)

**Objectif initial Phase B** : faire matcher v0.4 la perf wip-xml-next-bang en utilisant le tokenizer streaming v0.4, sans matérialiser children.

##### Découverte B.1 (2026-05-10)

`XML.eachchildnode(::LazyNode)` est **public et exporté en v0.4** (`dev/XML.jl-v0.4/src/lazynode.jl:280-303`). Pas besoin de hijack `_lazy_tokenizer` privé — l'API streaming existe déjà :
- `LazyChildIterator{S,I}` wrappe `Stateful(Tokenizer)` + `Ref{Bool}` done flag
- Yield un `LazyNode` à la fois sans matérialiser de Vector
- Pour `Node` (eager), `children(o)` est juste `something(o.children, ())` — accès de champ, zéro alloc

##### Implémentation B.2-B.4 (2026-05-10, commit pending)

`src/macros.jl` : helper polymorphique
```julia
@inline _children_iter(n::XML.Node) = XML.children(n)         # Vector existant
@inline _children_iter(n::XML.LazyNode) = XML.eachchildnode(n) # streaming
```
Propagation aux 3 macros (`@for_each_immediate_child`, `@find_immediate_child`, `@count_immediate_children`). **577/577 tests verts**.

##### Résultats B.5 — partial gain mais NO-GO sur critère

| URL  | wip-next-bang | v0.4 naïf | **v0.4 + `eachchildnode`** | vs wip | gain vs naïf |
|------|---------------|-----------|----------------------------|--------|--------------|
| URL2 | **195 ms**    | 448 ms    | 401 ms                     | ×2.05  | -10%         |
| URL4 | **261 ms**    | 858 ms    | 685 ms                     | ×2.62  | -20%         |
| URL5 | **2345 ms**   | 3873 ms   | 3297 ms                    | ×1.41  | -15%         |
| URL6 | **1254 ms**   | 3369 ms   | 2858 ms                    | ×2.28  | -15%         |

Mémoire (KiB) :
| URL  | wip-next-bang | v0.4 naïf | v0.4-each | gain vs naïf | vs wip |
|------|---------------|-----------|-----------|--------------|--------|
| URL2 | 192k          | 503k      | 415k      | -18%         | ×2.15  |
| URL4 | 491k          | 2 136k    | 1 748k    | -18%         | ×3.56  |
| URL5 | 1 900k        | 7 858k    | 6 148k    | -22%         | ×3.24  |
| URL6 | 2 373k        | 10 751k   | 8 293k    | -23%         | ×3.49  |

**Critère B.5** = v0.4-optim ≥ wip-next-bang sur ≥3/4 URLs → **0/4 respecté → NO-GO**.

##### Diagnostic du gap résiduel

Ce qui reste alloué après B.4 :
1. Une `LazyChildIterator` per `eachchildnode(parent)` (struct + `Ref{Bool}`) — minimum 1 alloc par parent visité
2. Une `LazyNode` per token enfant — la struct est petite mais `Stateful(Tokenizer)` itère et matérialise par yield
3. Pas de fast-path `next_no_xml_space` (PR #58 — sauter ws sans tokeniser)
4. Pas d'aliasing in-place (PR #59 — `next!`/`prev!` mute UN seul LazyNode par walk)

**Le pattern `next!` v0.3** alloue 1 `LazyNode` total pour tout le walk (mutation in-place sur `Raw.tag/value/depth`). v0.4 immutable + `eachchildnode` alloue O(N) iterators + O(N) LazyNodes. C'est l'inverse exact de l'approche zéro-alloc — l'immutabilité v0.4 et le pattern deep+repeated de FastKML sont fondamentalement antagonistes sans primitif streaming dédié.

#### Phase C — engagement upstream NÉCESSAIRE

L'API publique seule (`eachchildnode`) plafonne à -15-23% gain mémoire et ne ferme pas le gap. Il faut un primitif streaming sans alloc en v0.4. **Phase C devient mandatory**, pas optionnelle.

##### Plan Phase C

| Étape | Action |
|-------|--------|
| C.1 | Rapport markdown ~1 page : table 3-way + table B.5 + diagnostic alloc + use case FastKML deep+repeated walk |
| C.2 | Esquisse design API publique. **Pistes à présenter à joshday** :<br>– Option α : `walk_children(node, callback)` style visitor — ferme sur stack, pas d'iterator alloc<br>– Option β : `Tokenizer` direct + helpers depth-tracking publics (`skip_element!`, `peek_kind`)<br>– Option γ : un `LazyNode` mutable optionnel (`MutableLazyNode`) pour les patterns next!-like, avec promesse de "sourcetext on demand"<br>– Option δ : exposer `LazyChildIterator` mais pré-allocable + réutilisable (poolable) |
| C.3 | Ouvrir **issue** (pas PR direct) sur `joshday/XML.jl` avec rapport + 4 options + stats — laisser joshday choisir le design |
| C.4 | Itérer feedback design |
| C.5 | Si consensus : PR via fork `mathieu17g/XML.jl` → joshday/XML.jl@main |

##### En attendant — décision sur main

`wip-xml-next-bang-adoption` (PR #58 + #59 sur v0.3) reste la baseline perf. Ne pas merger `wip-xml-v0.4` sur main avant que :
- v0.4 atteigne au moins ≥ wip-next-bang via Phase C, OU
- la registry pousse v0.4 et v0.3 devient legacy

`wip-xml-v0.4` reste utile comme :
- **fonctionnellement correct** (577/577) — preuve qu'on est day-zero ready API-wise
- **base d'argumentation** pour Phase C — sans le diff v0.4, pas d'élément concret à montrer à joshday
- **branche de référence** pour mesurer tout futur ajout v0.4 (ex: après Phase C upstream)

##### Pour reprendre la session suivante

```sh
cd /Users/mathieu/Code/FastKML.jl
git checkout wip-xml-v0.4
# Phase suivante = C.1 — rédiger le rapport
# Le diff src/macros.jl + bench tables ci-dessus = matériel de base
```

Files de référence pour C.1 :
- `dev/XML.jl-v0.4/src/lazynode.jl:280-303` — `eachchildnode` actuel
- `dev/XML.jl-v0.4/src/lazynode.jl:181-198` — `_lazy_skip_element!` (depth-tracking interne)
- `dev/XML.jl/src/Raw.jl` (v0.3 + #58 + #59) — `next!`/`prev!` baseline pour comparison
- Ce TODO section "Diagnostic du gap résiduel" — résumé technique

#### Migration TERMINÉE — 577/577 tests verts (commit `f0d1944`, 2026-05-10)

Toute la migration v0.4 est appliquée. Tests à parité avec `main`.

Commits :
- `3c6bdd8` — setup branche + dev/XML.jl-v0.4 clone
- `43ef622` — parsing path migré (eager + lazy + DataFrame OK)
- `55f6049` — RESUME HERE checkpoint pour résilience contexte
- `f0d1944` — serialization migrée + signature widening (final)

`wip-xml-v0.4` est prêt à shipper les gains perf v0.4 (~70%
parse speedup à la source) le jour où PR #54 land sur General
registry. Steps de transition à ce moment-là :
1. Drop `[sources]` de `Project.toml` (et de `test/Project.toml`
   si présent).
2. Garder `[compat] XML = "0.4"`.
3. `Pkg.resolve()` côté FastKML — XML résolu depuis registry.
4. Supprimer le clone `dev/XML.jl-v0.4/` (plus utile).
5. Merger `wip-xml-v0.4` dans `main`.
6. Tag a v0.2.0 release (substantial v0.3 → v0.4 dependency change).

#### État courant de la migration (RESUME HERE — historique)

**Au 2026-05-10, commit `43ef622`** : la migration s'est révélée
beaucoup moins coûteuse que prévu (~45 min réels au lieu de jours).

**Ce qui est fait** :
- `XMLAnyNode = Union{XML.Node, XML.LazyNode}` défini dans `types.jl`
  + propagé dans 6 fichiers source.
- `KMLElement <: XML.AbstractXMLNode` supprimé (impossible de
  subtype un Union ; le dispatch méthode reste).
- 3 macros `@for_each_immediate_child` / `@find_immediate_child` /
  `@count_immediate_children` réécrites en uniforme `for child in
  XML.children(node)` (190 → 25 lignes). Plus de
  `XML.next!`/`.raw`/`XML.depth(::LazyNode)`.
- `_is_feature_tag`, `_is_container_tag` : signatures `String` →
  `AbstractString` (v0.4 `tag()` retourne `SubString{String}`).
- `Project.toml` + `test/Project.toml` : `[compat] XML = "0.4"`.

**Ce qui marche** :
- `using FastKML` (precompile clean).
- `read(path, KMLFile)` eager : tous les KMLElement matérialisés.
- `read(path, LazyKMLFile)` lazy : `_lazy_top_level_features` et
  `get_layer_info` walkent l'arbre correctement.
- `DataFrame(file::LazyKMLFile)` : 3 placemarks extraits avec
  Point/Polygon/LineString sur `test/example.kml`.
- Test suite : Issue Coverage 2/2 + ~70 Empty Constructors avant
  blocage sur serialization.

**Ce qui reste — `xml_serialization.jl` migration**

Le constructeur `XML.Node` a changé en v0.4. Cassure à
`src/xml_serialization.jl:24` (la fonction `Node(o::T) where {T<:KMLElement}`)
+ d'autres sites en cascade.

API mapping v0.3 → v0.4 :

```julia
# v0.3 (current FastKML code, breaks)
XML.Node(NodeType, tag::String, attrs::OrderedDict{String,String}, value, children)

# v0.4 target
XML.Node{String}(nodetype::NodeType,
                 tag::Union{Nothing,String},
                 attributes::Union{Nothing,Vector{Pair{String,String}}},
                 value::Union{Nothing,String},
                 children::Union{Nothing,Vector{Node{String}}})
```

Différences :
- **Type paramétrique `{S}`** explicite (utiliser `String`).
- **Attributs** : `OrderedDict{String,String}` → `Vector{Pair{String,String}}`.
  Conversion : `[k => v for (k, v) in attrs_dict]`.
- **Children** : `Vector{Node}` → `Vector{Node{String}}`.
- **Validation runtime** : v0.4 impose des règles
  (Element doit avoir tag + pas de value, Text/CData/etc. seulement
  value, Document seulement children). Voir `dev/XML.jl-v0.4/src/XML.jl:141-160`
  pour les contraintes.

Sites à patcher dans `xml_serialization.jl` :
- Ligne 15 : `Node(o::T) where {T<:Enums.AbstractKMLEnum}` — pattern
  Element + 1 Text child.
- Ligne 24 : `Node(o::T) where {T<:KMLElement}` — Element avec
  attributs + children récursifs.
- Lignes 60-90 (à confirmer) : `xml_children` builder, traitement
  des attributs.
- Ligne ~83 : `child isa XMLAnyNode` — devrait déjà fonctionner.

Pattern de migration suggéré :
1. Helper `_build_attrs(o::KMLElement)::Union{Nothing, Vector{Pair{String,String}}}`
   qui produit la nouvelle forme.
2. Tous les `XML.Node(NodeType.X, tag, attrs, val, kids)` → 
   `XML.Node{String}(NodeType.X, tag, attrs_vec, val, kids_typed)`.
3. Les `Vector{Node}` deviennent `Vector{Node{String}}`.

Effort estimé : **30-60 min** au vu de ce qui s'est passé pour le
parsing path.

Test de validation après fix :
```julia
julia --project=. -e 'using Pkg; Pkg.test()'
```
La testset "Empty constructor roundtrips with XML.Node" doit passer
les ~270 itérations sur tous les `concrete_subtypes(KMLElement)`.

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

### Patching XML.jl from FastKML — alternative to the `dev/XML.jl/` override

Instead of waiting on
[`XML.jl#54`](https://github.com/JuliaComputing/XML.jl/pull/54) (the
upstream renovation that put PRs #58 and #59 on hold), FastKML could
ship the perf gains via private helpers.

- **PR #59 (`next!`/`prev!`) — feasible without type piracy.**
  Define `FastKML.next!(o::XML.LazyNode)` (and `prev!`) as private
  helpers in FastKML, dispatching on the foreign `XML.LazyNode` type
  but living under FastKML's own function name (regular method
  definition, not piracy). ~30 LOC. Uses XML.LazyNode's internal
  field structure (`raw`, `tag`, `attributes`, `value`) — accept the
  fragility as the cost of bypassing upstream latency. The macros in
  `src/macros.jl` would call `FastKML.next!` instead of `XML.next!`;
  drops the `dev/XML.jl/` requirement entirely.

- **PR #58 (ctx-share inside `next_no_xml_space`) — harder.** The
  patch is INSIDE an existing XML.jl method, so delivery means either
  (a) `@eval`-ing a redefinition (full type piracy + redefinition
  warnings + invalidations), or (b) vendoring the entire
  `next_xml_space`/`next_no_xml_space` chain (~30 LOC) as private
  FastKML helpers. Option (b) is cleanest but doubles the maintenance
  surface. Worth ~60 MiB on URL2 per round-3 analysis, but URL2 is
  already 25% faster than ArchGDAL — diminishing returns. Recommend
  skipping.

**Trigger to act:**
1. **Either** we want to register FastKML.jl on the General registry
   (the `dev/XML.jl/` override blocks that), **or**
2. XML.jl#54 stalls beyond a few months without resolution.

Until one fires, the `dev/XML.jl/` + `wip-xml-next-bang-adoption`
override stays — it's cleaner than introducing fragile coupling to
XML.jl internals. Recorded in
[`memory:project_fastkml.md`](https://github.com/anthropics/claude-code/issues/0).

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

- [ ] Patching XML.jl from FastKML decided (above) — required if we
      want `Pkg.add("FastKML")` to work without dev/ override.
- [ ] CHANGELOG.md current and reviewed.
- [ ] One last run of the full benchmark suite + integration tests
      against the version that will be tagged.
- [ ] Decide on registry submission (General registry, dedicated
      registry, or stay url-based).

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
