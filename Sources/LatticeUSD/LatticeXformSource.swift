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
  /// Reads the GPU column first, then the CPU one.
  ///
  /// A scene driven by a compute kernel carries only ``XformGPU``, and this is
  /// the point where its single-precision matrix is widened to the double-precision
  /// `GfMatrix4d` USD wants. Doing it here rather than in a bulk pass is the
  /// whole reason the GPU path needs no CPU touch: Hydra pulls one prim at a
  /// time anyway, so the widening rides along with a read that was already
  /// happening, and prims Hydra never asks for are never converted.
  ///
  /// A CPU-driven scene pays one extra failed column lookup per prim for the
  /// `XformGPU` miss. That is the deliberate trade - the GPU path is the fast
  /// path, so it gets the single lookup.
  public func getLiveXform(_ path: SdfPath) -> GfMatrix4d?
  {
    assert(framePhase.current == .readable,
           "GetPrim() pulled outside the read phase - the store may be mutating concurrently.")

    guard let entity = paths.entity(forLookupKey: path.GetHash()) else { return nil }

    if let gpu = store.get(XformGPU.self, for: entity)
    {
      return gpu.matrix.asGfMatrix4d
    }
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

  /// Bulk form of ``markDirty(_:)``: appends an entire batch under a single
  /// lock acquisition.
  ///
  /// At scene scale the lock traffic of calling ``markDirty(_:)`` in a loop is
  /// the dominant cost of the mutation pass - a hundred thousand uncontended
  /// acquisitions per frame buys nothing, since the caller already knows the
  /// whole batch. This pays for the lock once and appends the run.
  ///
  /// The phase assertion is unchanged: a bulk push is still a write, and still
  /// illegal once Hydra is reading.
  public func markDirty(contentsOf paths: some Sequence<SdfPath>)
  {
    assert(framePhase.current == .mutable,
           "Mutation during the read phase - Hydra may be reading concurrently.")

    protectedDirty.withLock
    { pending in
      for path in paths
      {
        pending.push_back(path)
      }
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

/// `Sendable` so the column can be driven through
/// ``Query2/forEachMutatingFirstParallel(batchSize:_:)``,
/// which hands raw column buffers to concurrent workers. Trivially satisfied -
/// the payload is a `LatticeDouble4x4` of sixteen `Double`s with no
/// reference storage.
public struct Xform: LatticeComponent, Equatable, Sendable
{
  public var matrix: LatticeDouble4x4

  public init(matrix: LatticeDouble4x4)
  {
    self.matrix = matrix
  }
}

/// Sixteen packed `Float`s in `GfMatrix4d`'s row-major layout (64 bytes).
///
/// The GPU-side mirror of ``LatticeDouble4x4``. Metal Shading Language has no
/// `double` type at all, so any transform a compute kernel produces is necessarily single
/// precision - this is where that boundary lives.
///
/// The layout is deliberately identical to ``LatticeDouble4x4``'s: row-major,
/// translation in the last row. Widening is then a straight element-wise cast with no
/// transpose, and the Metal struct is a plain `float m[16]` with no padding
/// surprises (scalars rather than `float4`, whose 16-byte alignment would not
/// match Swift's layout).
public struct LatticeFloat4x4: Hashable, Sendable
{
  public var m00: Float, m01: Float, m02: Float, m03: Float
  public var m10: Float, m11: Float, m12: Float, m13: Float
  public var m20: Float, m21: Float, m22: Float, m23: Float
  public var m30: Float, m31: Float, m32: Float, m33: Float

  public init(
    _ m00: Float, _ m01: Float, _ m02: Float, _ m03: Float,
    _ m10: Float, _ m11: Float, _ m12: Float, _ m13: Float,
    _ m20: Float, _ m21: Float, _ m22: Float, _ m23: Float,
    _ m30: Float, _ m31: Float, _ m32: Float, _ m33: Float)
  {
    self.m00 = m00; self.m01 = m01; self.m02 = m02; self.m03 = m03
    self.m10 = m10; self.m11 = m11; self.m12 = m12; self.m13 = m13
    self.m20 = m20; self.m21 = m21; self.m22 = m22; self.m23 = m23
    self.m30 = m30; self.m31 = m31; self.m32 = m32; self.m33 = m33
  }

  public static let identity = LatticeFloat4x4(
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1
  )

  public var asGfMatrix4d: GfMatrix4d
  {
    GfMatrix4d(
      Double(m00), Double(m01), Double(m02), Double(m03),
      Double(m10), Double(m11), Double(m12), Double(m13),
      Double(m20), Double(m21), Double(m22), Double(m23),
      Double(m30), Double(m31), Double(m32), Double(m33)
    )
  }
}

/// The GPU-resident transform.
///
/// Register this against a `MetalBackedColumn` and a compute kernel writes the
/// column's bytes directly. On unified memory that write is visible to
/// ``LatticeXformSource/getLiveXform(_:)`` with no upload, no readback,
/// and no CPU pass over the column - the widening to `GfMatrix4d` happens one
/// prim at a time, at the moment Hydra actually pulls it, and only for the prims it
/// pulls.
///
/// Conformance to `LatticeMetal.LatticeGPUComponent` is declared by whoever
/// owns the Metal column, since `LatticeUSD` does not depend on `LatticeMetal`.
public struct XformGPU: LatticeComponent, Equatable, Sendable
{
  public var matrix: LatticeFloat4x4

  public init(matrix: LatticeFloat4x4)
  {
    self.matrix = matrix
  }
}
