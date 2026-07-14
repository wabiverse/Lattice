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

import Synchronization
import LatticeCore
import OpenUSDKit

/// The live, app-owned transform store that ``LatticeHydraSceneIndex``
/// reads through on every `GetPrim()`.
///
/// The frame contract is a two-phase one, and the assertions below encode it:
///
/// ```
/// mutate -> store.advanceChangeTick() -> sceneIndex.Tick() -> beginReadPhase()
///        -> Hydra pulls GetPrim() -> endReadPhase()
/// ```
///
/// Hydra calls `GetPrim()` concurrently from multiple threads. Concurrent
/// *reads* of the store and path table are safe; a read overlapping a *write*
/// is not - a `Dictionary` mutation racing a reader is memory corruption, not
/// merely a torn value. Nothing in the type system enforces the phase split, so
/// it is asserted instead: violations trap in debug and compile out in release.
///
/// The phase itself lives in ``LatticeFramePhase``, shared with
/// ``LatticePathTable`` so both sides of the boundary assert against one clock.
public final class LatticeXformSource
{
  private let store: LatticeStore
  private let paths: LatticePathTable
  private let framePhase: LatticeFramePhase
  private let protectedDirty = Mutex<SdfPathVector>(SdfPathVector())

  public init(store: LatticeStore, paths: LatticePathTable)
  {
    self.store = store
    self.paths = paths
    self.framePhase = store.framePhase
  }

  // MARK: - Frame phase

  /// Called by the frame loop after `Tick()`,
  /// before handing the scene index to Hydra.
  /// Reads become legal; writes become a
  /// programmer error.
  public func beginReadPhase()
  {
    framePhase.beginReadPhase()
  }

  /// Called once Hydra has finished pulling for this frame.
  public func endReadPhase()
  {
    framePhase.endReadPhase()
  }

  // MARK: - Read path

  /// Called from C++ `GetPrim()`, once per prim per frame. Returns nil if this
  /// path has no live Lattice-owned xform (falls through to the stage's own value).
  ///
  /// Deliberately keys on `SdfPath.GetHash()` rather than the path's string
  /// form: `path.string` would heap-allocate a Swift `String` on every call,
  /// which at scene scale is the dominant per-frame cost. The hash agrees with the
  /// key `USDPopulationSync` bound with, courtesy of `SdfPath` interning.
  public func getLiveXform(_ path: SdfPath) -> GfMatrix4d?
  {
    assert(framePhase.current == .readable,
           "GetPrim() pulled outside the read phase - the store may be mutating concurrently.")

    guard let entity = paths.entity(forLookupKey: path.GetHash()) else { return nil }
    return store.get(Xform.self, for: entity)?.matrix.asGfMatrix4d
  }

  /// A boolean-based alternative to `getLiveXform(_:)` to bypass a Swift -> C++
  /// interoperability linker bug.
  ///
  /// - Parameters:
  ///   - outMatrix: Populated with the live transform if one is found.
  ///   - path: The target prim path.
  /// - Returns: `true` if a live transform was found and written.
  ///
  /// - Warning: `outMatrix` must be initialized by the caller. Swift `inout`
  ///   reads the value in before writing it back, and `GfMatrix4d`'s default ctor
  ///   is `= default` - it leaves the 16 doubles uninitialized. Always pass an
  ///   initialized `GfMatrix4d(1.0)`, never `GfMatrix4d()`.
  ///
  /// - Warning: This is a temporary workaround. Swift currently fails to generate
  ///   the type metadata accessor for `swift::Optional<GfMatrix4d>::~Optional()`,
  ///   producing a missing destructor linker error.
  public func didGetLiveXform(_ outMatrix: inout GfMatrix4d, _ path: SdfPath) -> Bool
  {
    guard let m = self.getLiveXform(path) else { return false }
    outMatrix = m
    return true
  }

  // MARK: - Write path (mutation phase)

  /// Called by whatever drives per-frame mutation whenever a prim's xform
  /// changes this frame.
  ///
  /// The lock here is not redundant with the phase assertion: mutation may
  /// run on the parallel CPU path or from a GPU completion handler, so several
  /// threads can push concurrently *within* the mutable phase. The phase
  /// guards an ordering; this lock guards the structure.
  public func markDirty(_ path: SdfPath)
  {
    assert(framePhase.current == .mutable,
           "Mutation during the read phase - Hydra may be reading concurrently.")

    protectedDirty.withLock
    { pending in
      pending.push_back(path)
    }
  }

  /// Call after each frame's mutation pass, before asking the scene index to
  /// notify. Drains and returns everything touched this tick.
  ///
  /// Must run *before* ``beginReadPhase()``, since it clears the dirty
  /// set that the frame's notifications are built from.
  public func drainDirtiedPaths() -> SdfPathVector
  {
    assert(framePhase.current == .mutable,
           "Draining dirty paths during the read phase.")

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
}

extension SdfPathVector: @unchecked Sendable {}

public struct Xform: LatticeComponent, Equatable
{
  public var matrix: LatticeDouble4x4

  public init(matrix: LatticeDouble4x4)
  {
    self.matrix = matrix
  }
}
