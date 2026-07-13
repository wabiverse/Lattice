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
import LatticeCore
import OpenUSDKit

public final class LatticeXformSource
{
  private let store: LatticeStore
  private let paths: LatticePathTable
  private let protectedDirty = OSAllocatedUnfairLock(initialState: SdfPathVector())

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
  
  /// A boolean-based alternative to `getLiveXform(_:)` to bypass a Swift -> C++ interoperability linker bug.
  ///
  /// Use this function in C++ clients to safely retrieve the live transform matrix without triggering
  /// compilation failures related to Swift optional types across the language boundary.
  ///
  /// - Parameters:
  ///   - outMatrix: An in-out matrix that will be populated with the live transform if found.
  ///   - path: The target prim path (`SdfPath`).
  /// - Returns: `true` if a live transform was found and written to `outMatrix`; otherwise, `false`.
  ///
  /// - Warning: This is a temporary workaround. Swift currently fails to generate the type metadata
  ///   accessor for `swift::Optional<GfMatrix4d>::~Optional()`, resulting in a missing
  ///   destructor linker error.
  public func didGetLiveXform(_ outMatrix: inout GfMatrix4d, _ path: Pixar.SdfPath) -> Bool
  {
    guard let m = self.getLiveXform(path) else { return false }
    outMatrix = m
    return true
  }

  /// Call after each frame's mutation pass, before asking the scene
  /// index to notify. Drains and returns everything touched this tick.
  public func drainDirtiedPaths() -> SdfPathVector
  {
    return protectedDirty.withLock
    { pending in
      // 1. zero-allocation.
      var result = SdfPathVector()
      
      // 2. swap pointers O(1).
      result.swap(&pending)
      
      // 3. return populated vector
      return result
    }
  }

  /// Called by whatever drives per-frame mutation (existing
  /// changeTick/wholeColumnTick machinery) whenever a
  /// prim's xform changes this frame.
  public func markDirty(_ path: SdfPath)
  {
    protectedDirty.withLock
    { pending in
      pending.push_back(path)
    }
  }
}

extension SdfPathVector: @unchecked Sendable {}

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
