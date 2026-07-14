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

import Foundation

/// Maps stable external identifiers - most importantly USD `SdfPath`
/// strings - to dense ``LatticeEntity`` handles, and back.
///
/// The store itself never needs to know about USD, paths, or strings; it
/// only deals in `LatticeEntity` values, which is what keeps its inner loop
/// fast. This table is what lets a sync layer such as `LatticeUSD` - or an
/// editor, or a save/load system - translate between "the stable name a
/// human or a file format cares about" and "the dense handle the store
/// cares about".
public final class LatticePathTable
{
  private var byPath: [String: LatticeEntity] = [:]
  private var byEntity: [LatticeEntity: (path: String, lookupKey: Int)] = [:]
  private var byLookupKey: [Int: LatticeEntity] = [:]
  private let framePhase: LatticeFramePhase

  public init(framePhase: LatticeFramePhase)
  {
    self.framePhase = framePhase
  }

  public func entity(for path: String) -> LatticeEntity?
  {
    byPath[path]
  }

  /// Allocation-free lookup for the runtime read path. `key` must be derived
  /// the same way it was at ``bind(_:to:lookupKey:)``.
  public func entity(forLookupKey key: Int) -> LatticeEntity?
  {
    byLookupKey[key]
  }

  public func path(for entity: LatticeEntity) -> String?
  {
    byEntity[entity]?.path
  }

  /// Binds `entity` to `path`. `lookupKey` is required, not optional: a binding
  /// without one is invisible to the runtime read path, which fails silently.
  public func bind(_ entity: LatticeEntity, to path: String, lookupKey: Int)
  {
    assert(framePhase.current == .mutable,
           "LatticePathTable.bind during the read phase - Hydra may be reading concurrently.")

    byPath[path] = entity
    byEntity[entity] = (path: path, lookupKey: lookupKey)
    byLookupKey[lookupKey] = entity
  }

  /// Removes every index entry for `entity`. Deliberately takes no key - it
  /// recovers the one actually used at bind time, so it cannot be unbound with
  /// the wrong key and leave a stale entry behind.
  public func unbind(_ entity: LatticeEntity)
  {
    assert(framePhase.current == .mutable,
           "LatticePathTable.unbind during the read phase - Hydra may be reading concurrently.")

    guard let (path, lookupKey) = byEntity.removeValue(forKey: entity) else { return }
    byPath[path] = nil
    byLookupKey[lookupKey] = nil
  }

  /// The number of bound path<->entity pairs.
  public var count: Int
  {
    byEntity.count
  }

  /// Visits every bound `(entity, path)` pair. Iteration order is unspecified.
  public func forEachBinding(_ body: (LatticeEntity, String) -> Void)
  {
    for (entity, binding) in byEntity
    {
      body(entity, binding.path)
    }
  }
}
