/* ----------------------------------------------------------------
 * :: :  O  P  E  N  U  S  D  :                                  ::
 * ----------------------------------------------------------------
 * Licensed under the terms set forth in the LICENSE.txt file, this
 * file is available at https://openusd.org.
 *
 *                   Copyright (C) 2016 Pixar. All Rights Reserved.
 *                              Copyright (C) 2024 Wabi Foundation.
 * ----------------------------------------------------------------
 *  . x x x . o o o . x x x . : : : .    o  x  o    . : : : .
 * ---------------------------------------------------------------- */

import Lattice

/// Populates a ``LatticeStore`` from a ``USDStageSourceRepresentable``,
/// the way USDRT populates Fabric on first touch rather than mirroring the whole stage
/// eagerly.
///
/// This implementation does a full pull every time `syncAll()` is
/// called: it walks every prim path and ensures each one has a bound
/// ``LatticeEntity``, without touching entities that are already bound. The
/// natural next step is to make this incremental - keep the last-seen path
/// set, diff it against the stage's current set, and only spawn/despawn the
/// entities that actually changed - which mirrors how USDRT distinguishes
/// one-time "population" from ongoing "synchronization".
public final class USDPopulationSync
{
  private let store: LatticeStore
  private let paths: LatticePathTable
  private let source: USDStageSourceRepresentable
  /// The prim-path set observed at the last ``syncIncremental()``, so the next
  /// call can diff against it instead of re-walking from scratch.
  private var lastSeenPaths: Set<String> = []

  /// A summary of what an incremental sync changed, handy for logging or for
  /// deciding whether any downstream work is needed this frame.
  public struct SyncDelta: Equatable, Sendable
  {
    public var added: Int
    public var removed: Int
    public var isEmpty: Bool
    {
      added == 0 && removed == 0
    }

    public init(added: Int, removed: Int)
    {
      self.added = added
      self.removed = removed
    }
  }

  public init(store: LatticeStore, paths: LatticePathTable, source: USDStageSourceRepresentable)
  {
    self.store = store
    self.paths = paths
    self.source = source
  }

  /// Ensures every prim path on the stage has a corresponding
  /// ``LatticeEntity``. Does not populate component values on its own -
  /// pair this with a type-specific sync (for example, one that reads
  /// `xformOp` attributes into a `Transform` component) that calls
  /// `value(at:attribute:)` and writes the result through
  /// `LatticeStore.set(_:on:)`.
  ///
  /// This is the one-time "population" pass. For an ongoing loop against a
  /// stage that gains and loses prims, use ``syncIncremental()`` instead.
  public func syncAll()
  {
    let current = source.primPaths()
    for path in current where paths.entity(for: path) == nil
    {
      let entity = store.spawn()
      paths.bind(entity, to: path)
    }
    lastSeenPaths = Set(current)
  }

  /// Reconciles the store with the stage's *current* prim set by diffing it
  /// against the set seen at the previous sync: spawns+binds an entity for
  /// each newly-appeared prim, and despawns+unbinds the entity for each prim
  /// that disappeared. Prims present in both are left untouched.
  ///
  /// This is the "synchronization" half of the population/synchronization
  /// split that USDRT draws - after the first `syncAll()`/`syncIncremental()`
  /// establishes the baseline, subsequent calls touch only what changed, so
  /// cost scales with the delta rather than with total stage size. Returns
  /// what changed.
  @discardableResult
  public func syncIncremental() -> SyncDelta
  {
    let current = Set(source.primPaths())

    var added = 0
    for path in current.subtracting(lastSeenPaths)
    {
      // Guard against a path that's already bound (e.g. after a prior syncAll).
      guard paths.entity(for: path) == nil else { continue }
      let entity = store.spawn()
      paths.bind(entity, to: path)
      added += 1
    }

    var removed = 0
    for path in lastSeenPaths.subtracting(current)
    {
      guard let entity = paths.entity(for: path) else { continue }
      paths.unbind(entity)
      store.despawn(entity)
      removed += 1
    }

    lastSeenPaths = current
    return SyncDelta(added: added, removed: removed)
  }

  /// Convenience for callers hand-rolling their own component population
  /// loop, rather than waiting on a generic schema-driven sync path.
  public func value(at path: String, attribute name: String) -> LatticeUSDValue?
  {
    source.attributeValue(at: path, attribute: name)
  }

  /// Reads USD attribute `attribute` on every bound prim, decodes it into a
  /// component of type `T`, and writes that component onto the prim's entity
  /// via `LatticeStore.set(_:on:)`. Returns the number of entities that got a
  /// value.
  ///
  /// This is the typed half of population: `syncAll()` establishes the
  /// path<->entity mapping (one entity per prim), and this pulls a specific
  /// attribute into a specific component column. Call it once per component
  /// you want mirrored - e.g. one call reading `xformOp:translate` into a
  /// `Transform`, another reading a visibility token into a `Visibility` flag.
  ///
  /// `decode` is where the caller bridges USD's value model to their own
  /// component type; returning `nil` skips that prim (attribute absent, wrong
  /// type, or not meaningful for this component). `T` must already be
  /// registered on the store, the same as any other `set`.
  ///
  /// Only reads happen against USD here, so this is safe to re-run each frame
  /// to refresh values from the stage - though for a large stage we'll want the
  /// incremental, change-driven path noted on ``syncAll()`` rather than a
  /// full re-pull.
  @discardableResult
  public func populate<T: LatticeComponent>(
    _: T.Type,
    from attribute: String,
    decode: (LatticeUSDValue) -> T?
  ) -> Int
  {
    var populated = 0
    paths.forEachBinding
    { entity, path in
      guard
        let raw = source.attributeValue(at: path, attribute: attribute),
        let component = decode(raw)
      else { return }
      store.set(component, on: entity)
      populated += 1
    }
    return populated
  }

  /// Authors component values back onto the stage - the store->USD direction -
  /// touching only the entities whose `T` changed strictly after `tick`.
  ///
  /// This closes the loop USDRT draws: `populate` pulls USD into the store, a
  /// system mutates the store, and this pushes the results back, but *only for
  /// what changed*, using the store's per-row change ticks (`store.currentTick`
  /// / `forEachChanged`). Encode each component into a `LatticeUSDValue` and it
  /// funnels through `USDStageSource.setAttributeValue`; returning `nil` from
  /// `encode` skips that entity. Entities with no bound path are skipped.
  /// Returns the number of attributes written.
  ///
  /// Typical loop:
  /// ```swift
  /// let lastWrite = store.currentTick
  /// // …systems mutate Transform…
  /// store.advanceChangeTick()
  /// sync.writeBackChanged(Transform.self, to: "xformOp:translate", since: lastWrite) {
  ///     .float3($0.x, $0.y, $0.z)
  /// }
  /// ```
  @discardableResult
  public func writeBackChanged<T: LatticeComponent>(
    _: T.Type,
    to attribute: String,
    since tick: UInt64,
    encode: (T) -> LatticeUSDValue?
  ) -> Int
  {
    var written = 0
    store.query(T.self).forEachChanged(since: tick)
    { entity, value in
      guard
        let path = paths.path(for: entity),
        let encoded = encode(value),
        source.setAttributeValue(encoded, at: path, attribute: attribute)
      else { return }
      written += 1
    }
    return written
  }
}
