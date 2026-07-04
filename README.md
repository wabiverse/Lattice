# Lattice

A Swift-native, open-source runtime data store for real-time scenes -
the same problem [NVIDIA's Fabric/USDRT](https://docs.omniverse.nvidia.com/kit/docs/usdrt.scenegraph/latest/usd_fabric_usdrt.html)
solve inside Omniverse, built as its own thing rather than a port of that API.

Lattice is not a scene graph, not a composition engine, and not tied to
USD. It's a small archetype-based store: entities, columns of component
data laid out for cache-friendly bulk iteration, and cheap structural moves
when an entity's component set changes. It's meant to sit *next to*
whatever owns your authoritative scene description - a `UsdStage` via
`LatticeUSD`, or nothing at all - the same way Fabric sits next to a stage
without replacing it.

## Why this exists

Fabric gives Omniverse a place to read and write scene data at
per-frame rates without paying USD composition and `TfNotice` overhead.
USDRT is a USD-shaped API on top of it. Neither is open source - only the
USDRT API layer ships as source/binary, and Fabric itself is developed
inside Kit. There isn't an existing open equivalent for people who want
Fabric-style performance in their own Swift engine without Omniverse.

Lattice borrows the two ideas that actually matter from Fabric's design -
bucketed, columnar storage, and cheap change tracking instead of per-value
notifications - and otherwise takes a completely Swift-native shape: no
`usdrt::UsdStage`-alike API, no attempt at source compatibility with anything
NVIDIA ships. What Fabric does with CUDA and a C++ Kit runtime, Lattice does
with Swift value types, contiguous columns, `MTLBuffer`-backed storage on
unified memory, and Swift's own concurrency for parallel iteration.

## Package layout

- **`Lattice`** - the core. Entities, archetypes, columns, queries, change
  tracking. No platform-specific or USD-specific code lives here; it builds
  and tests anywhere Swift runs.
- **`LatticeMetal`** - `MetalBackedColumn<T>`, a column backed by an
  `MTLBuffer` instead of a Swift array, wired into the store through a
  per-component factory. On Apple Silicon's unified memory, writes here are
  immediately visible to the GPU with no upload step:
  `store.register(Particle.self) { MetalBackedColumn<Particle>(device: device) }`.
- **`LatticeUSD`** - a thin adapter (`USDStageSource`) that lets any USD
  binding populate a `LatticeStore`, without Lattice depending on that
  binding's concrete API.
- **`LatticeDemo`** - `swift run -c release LatticeDemo`: spawns 100k entities
  with a `Transform`/`Velocity` pair and integrates position for 120 frames,
  timing the serial and parallel query paths against each other (~3x+ on an
  8-performance-core M-series).

## Core concepts

- **`LatticeEntity`** - a dense index/generation handle. No data, no path,
  no name. Just an identity.
- **`LatticeComponent`** - marker protocol for a storable value type.
- **`Archetype`** - a bucket of entities sharing exactly the same component
  types, holding one densely packed column per type.
- **`LatticeStore`** - owns every archetype, and is the only place that
  moves an entity between archetypes when you `set`/`remove` a component
  type it didn't previously have.
- **`Query1<A>` ... `Query4<A, B, C, D>`** - read or mutate matching entities by
  iterating archetype columns directly, not by looking entities up one at a
  time. Iteration hands the closure contiguous buffers so the loop vectorizes;
  `forEachMutatingFirstParallel` fans the same work across cores.
- **`mutationGeneration(of:)`** - a coarse "did anything of this component
  type change" counter, standing in for `TfNotice`.
- **`currentTick` / `forEachChanged(since:)`** - per-row change detection:
  every write stamps the row with a monotonic tick, so a system can touch only
  the entities whose component changed since it last ran (Bevy-style), the
  fine-grained counterpart to `mutationGeneration(of:)`.

```swift
let store = LatticeStore()

// No registration step needed - set/spawn register a component on first use.
let entity = store.spawn(
    Transform(x: 0, y: 0, z: 0),
    Velocity(dx: 1, dy: 0, dz: 0)
)

// Bulk-iterate matching entities over contiguous columns.
store.query(Transform.self, Velocity.self).forEachMutatingFirst { _, transform, velocity in
    transform.x += velocity.dx
}

// The same loop, fanned out across cores (data-parallel, single-writer for structure):
store.query(Transform.self, Velocity.self).forEachMutatingFirstParallel { transform, velocity in
    transform.x += velocity.dx
}
```

## Concurrency model

Fabric exists so many systems can read and write scene data per frame without
serializing on composition. Lattice takes the same position with a clear,
enforceable contract:

- **Value mutation is data-parallel.** `forEachMutatingFirstParallel` splits an
  archetype's rows into contiguous batches across the global concurrent queue.
  Each worker owns a disjoint row range, so mutating one component while reading
  others needs no locking. This is the embarrassingly-parallel per-frame
  simulation path.
- **Structural change is single-writer.** `spawn`, `despawn`, `set`-that-adds-a
  -type, and `remove` move entities between archetypes and mutate shared
  indices. They must not run concurrently with a query. Run structural edits
  between parallel passes, not during them - the same discipline Fabric's
  bucket model requires.

## What's implemented

- **Optional registration.** `set`/`spawn` register a component the first time
  they see it; there's no mandatory startup step. `register(_:columnFactory:)`
  remains, now solely to choose a component's backing storage.
- **Selectable column backing.** Columns are created through a per-component
  factory, so a type can live in a plain array (`TypedColumn`) or directly in
  an `MTLBuffer` (`MetalBackedColumn`) - queries drive either transparently
  through the `TypedColumnStorage` protocol. `MetalBackedColumn` also exposes a
  `bufferGeneration` so a renderer knows when a growth reallocation invalidated
  the buffer it had bound.
- **Two-level change detection.** The coarse `mutationGeneration(of:)` answers
  "did any `T` change"; per-row change ticks (`currentTick`,
  `forEachChanged(since:)`) answer "*which* entities' `T` changed", and ticks
  are preserved across archetype moves so an unrelated add/remove never looks
  like a value edit.
- **Queries up to arity four**, with vectorizable contiguous iteration and the
  parallel mutation path above.
- **USD population *and* synchronization.** `syncAll()` does one-time
  population; `syncIncremental()` diffs the stage's current prim set against the
  last-seen set and spawns/despawns only the delta - USDRT's
  population-vs-synchronization split. `OpenUSDStageSource` is a concrete
  `USDStageSource` backed by a real `UsdStage` via `wabiverse/swift-usd`.

## Roadmap

What's genuinely still ahead, in rough priority:

- **A system scheduler** that runs *different* systems concurrently when their
  component read/write sets are disjoint - the current parallelism is within a
  single query; the next step is across systems, inferred from access sets.
- **Query filtering** - `without:` exclusion and optional components - plus
  arity beyond four via parameter packs rather than more overloads.
- **Writing computed values back to USD** on the same invalidation graph that
  drives recompute, closing the loop between the runtime store and the stage.

## Integrating with `wabiverse/swift-usd`

`LatticeUSD` depends on `OpenUSDKit` from `wabiverse/swift-usd` and ships
`OpenUSDStageSource`, a concrete `USDStageSource` backed by a real `UsdStage`:
it traverses the composed stage for prim paths and reads resolved attribute
values, mapping USD value types to `LatticeUSDValue`.

```swift
let source = OpenUSDStageSource(openingStageAt: "scene.usd")
let sync = USDPopulationSync(store: store, paths: paths, source: source)
sync.syncAll()                                    // one-time population
sync.populate(Transform.self, from: "xformOp:translate") { value in
    guard case let .float3(x, y, z) = value else { return nil }
    return Transform(x: x, y: y, z: z)
}
// Later, each frame the stage's prim set can change:
sync.syncIncremental()   // spawns/despawns only the delta
```

If we extend `ExecUsdSystem` to also write its computed values (posed
transforms, bounds) into a `LatticeStore` - rather than only handing an
`ExecUsdCacheView` back to a caller - we could get something Fabric and
USD's own execution system don't currently share: one store that both
holds bulk runtime data *and* receives computed values from the same
invalidation graph that already knows when to recompute them.
