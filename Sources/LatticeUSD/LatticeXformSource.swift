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

import os.lock
import Lattice
import OpenUSDKit

public final class LatticeXformSource
{
  private let store: LatticeStore
  private let paths: LatticePathTable
  private var pendingDirty: Set<SdfPath> = []
  private var pendingDirtyLock = os_unfair_lock()

  public init(store: LatticeStore, paths: LatticePathTable)
  {
    self.store = store
    self.paths = paths
  }

  /// Called from C++ GetPrim(). Returns nil if this path has no
  /// live Lattice-owned xform (falls through to the stage's own value).
  public func getLiveXform(_ path: SdfPath) -> GfMatrix4d?
  {
    guard let entity = paths.entity(for: path.string) else { return nil }
    return store.get(Xform.self, for: entity)?.matrix.asGfMatrix4d
  }

  /// Call after each frame's mutation pass, before asking the scene
  /// index to notify. Drains and returns everything touched this tick.
  public func drainDirtiedPaths() -> [SdfPath]
  {
    os_unfair_lock_lock(&pendingDirtyLock)
    let result = Array(pendingDirty)
    pendingDirty.removeAll(keepingCapacity: true)
    os_unfair_lock_unlock(&pendingDirtyLock)
    return result
  }

  /// Called by whatever drives per-frame mutation (existing
  /// changeTick/wholeColumnTick machinery) whenever a
  /// prim's xform changes this frame.
  public func markDirty(_ path: SdfPath)
  {
    os_unfair_lock_lock(&pendingDirtyLock)
    pendingDirty.insert(path)
    os_unfair_lock_unlock(&pendingDirtyLock)
  }
}

extension SdfPath: Identifiable, Hashable
{
  public var id: Int
  {
    GetHash()
  }

  public func hash(into hasher: inout Hasher)
  {
    hasher.combine(id)
  }
}

public struct Xform: LatticeComponent, Equatable
{
  public var matrix: LatticeDouble4x4

  public init(matrix: LatticeDouble4x4)
  {
    self.matrix = matrix
  }
}
