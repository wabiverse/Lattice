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

/// One instance's transform, in the decomposed form Hydra's instancer schema
/// actually wants.
///
/// Ten `Float`s in one component - so one column, one `MTLBuffer`, one base
/// pointer for the scene index to read. A `UsdGeomPointInstancer` exposes its
/// per-instance data to Hydra as three separate instance-rate primvars
/// (`hydra:instanceTranslations`, `hydra:instanceScales`,
/// `hydra:instanceRotations`), all of them **float**-typed - `VtVec3fArray`,
/// `VtVec3fArray`, `VtQuatfArray`.
///
/// That is the happy accident that makes the instancer path strictly better
/// than the per-prim one for a GPU-driven scene: per-prim xforms are
/// `GfMatrix4d` and force a float->double widening, while instancing
/// wants exactly the precision a compute kernel produces. Nothing is widened
/// here at all.
///
/// Scalars rather than `SIMD3`/`SIMD4`, for the same reason as ``RippleMotion``:
/// MSL's `float3` is 16-byte aligned and would not agree with Swift's packing.
public struct InstanceXform: LatticeComponent, Equatable, Sendable
{
  public var tx: Float, ty: Float, tz: Float
  public var sx: Float, sy: Float, sz: Float
  /// Rotation quaternion, imaginary part first then real - matching the
  /// `GfQuatf(real, imaginary)` reconstruction on the C++ side.
  public var rx: Float, ry: Float, rz: Float, rw: Float

  public init(tx: Float, ty: Float, tz: Float,
              sx: Float, sy: Float, sz: Float,
              rx: Float, ry: Float, rz: Float, rw: Float)
  {
    self.tx = tx; self.ty = ty; self.tz = tz
    self.sx = sx; self.sy = sy; self.sz = sz
    self.rx = rx; self.ry = ry; self.rz = rz; self.rw = rw
  }

  public static let identity = InstanceXform(
    tx: 0, ty: 0, tz: 0,
    sx: 1, sy: 1, sz: 1,
    rx: 0, ry: 0, rz: 0, rw: 1
  )
}

/// The live, app-owned instance buffer that ``LatticeInstancerSceneIndex``
/// reads through when Hydra pulls the instancer prim.
///
/// The per-prim ``LatticeXformSource`` answers one `GetPrim()` per cube,
/// which means a scene of N moving cubes costs N scene-index answers and N dirtied
/// prims every frame. This answers **one** prim holding all N instances, so the frame's
/// notification set is a single path no matter how large N gets. Same store, same kernel,
/// same frame contract - a different shape of scene.
///
/// The frame contract is unchanged:
///
/// ```
/// mutate -> store.advanceChangeTick() -> sceneIndex.Tick() -> beginReadPhase()
///        -> Hydra pulls GetPrim() -> endReadPhase()
/// ```
public final class LatticeInstanceSource
{
  private let framePhase: LatticeFramePhase

  /// Base of the contiguous ``InstanceXform`` column, handed over once at
  /// setup.
  ///
  /// Stable for the run: the column is sized to the instance count up front and
  /// never grows, so the `MTLBuffer` is never reallocated and this address never
  /// dangles. A scene that spawned instances mid-run would have to re-bind here
  /// whenever `MetalBackedColumn.bufferGeneration` changed.
  ///
  /// Held as a bare address rather than an `UnsafeRawPointer?`, because
  /// `Mutex.withLock` returns its result `sending` - the value has to be safe to
  /// transfer out of the lock's isolation region, and a pointer is not. A `UInt` is trivially
  /// `Sendable`, so the transfer is unremarkable and the pointer is reconstituted on
  /// the far side of the lock. Nothing is lost: the safety that matters here is the frame phase,
  /// not the pointer's type.
  private let protectedBinding = Mutex<(base: UInt, count: Int)>((0, 0))
  private let protectedDirty = Mutex<Bool>(false)

  /// How many of the bound instances are live.
  ///
  /// The column, the primvar arrays and the stage's authored `protoIndices` are
  /// all sized once at startup, so this can only ever narrow that - it selects a prefix of the
  /// field rather than resizing it. The scene index sizes its arrays to it and drops every
  /// `instanceIndices` entry past it.
  ///
  /// `count` is what the UI has asked for and moves at any moment. `published` is what the
  /// frame in flight is being served at, latched once per frame by ``drainTopologyDirty()``.
  /// Reads from `GetPrim()` go through `published`, never `count`: Hydra pulls the instancer
  /// topology and the instance primvars in *separate* `GetPrim()` calls, so serving the live
  /// value would let the count move between them and leave `instanceIndices` addressing
  /// instances the primvar arrays no longer have - which Storm's indirect draw then reads
  /// straight off the end of the buffer.
  ///
  /// `topologyDirty` is separate from ``markDirty()`` because the index list lives in the
  /// instancer topology, not in the primvars - it only needs republishing when the count
  /// actually moves, not every frame.
  private let protectedActive = Mutex<(count: Int, published: Int, topologyDirty: Bool)>((0, 0, false))

  /// The instancer prim whose primvars are overridden.
  public let instancerPath: SdfPath

  public init(store: LatticeStore, instancerPath: SdfPath)
  {
    self.framePhase = store.framePhase
    self.instancerPath = instancerPath
  }

  // MARK: - Binding

  /// Points the source at the column the kernel writes.
  ///
  /// Separate from `init` because the column only exists after the store is
  /// populated, and its `MTLBuffer` only after the Metal path is confirmed.
  public func bind(base: UnsafeRawPointer?, count: Int)
  {
    let address = UInt(bitPattern: base)
    protectedBinding.withLock
    { binding in
      binding = (address, count)
    }
  }

  // MARK: - Frame phase

  public func beginReadPhase()
  {
    framePhase.beginReadPhase()
  }

  public func endReadPhase()
  {
    framePhase.endReadPhase()
  }

  // MARK: - Read path

  /// Base address of the instance column, or `nil` if nothing is bound.
  ///
  /// Called from C++ `GetPrim()` once per frame - not once per instance - and
  /// the caller strides it as ten floats per instance.
  public func instanceBase() -> UnsafeRawPointer?
  {
    assert(framePhase.current == .readable,
           "GetPrim() pulled outside the read phase - the store may be mutating concurrently.")

    // only the address crosses the lock, the pointer is formed outside it.
    let address = protectedBinding.withLock { $0.base }
    return UnsafeRawPointer(bitPattern: address)
  }

  public func instanceCount() -> Int
  {
    protectedBinding.withLock { $0.count }
  }

  /// How many instances the frame in flight is being served at, clamped to what
  /// is actually bound.
  ///
  /// Read from the scene index's `GetPrim()` to size the primvar arrays and
  /// narrow `instanceIndices`. This is the latched value, not the live one -
  /// see ``protectedActive``.
  public func activeCount() -> Int
  {
    let bound = protectedBinding.withLock { $0.count }
    let active = protectedActive.withLock { $0.published }
    return active <= 0 ? bound : min(active, bound)
  }

  /// Whether the live count moved since it was last published, and the point at
  /// which the frame's count is latched.
  ///
  /// Called once per frame from the scene index's `Tick()`, in the mutation
  /// phase and before the read phase opens, so every `GetPrim()` that Hydra
  /// makes against this frame sees one count. When it returns `true` the caller
  /// adds the instancer topology to the dirty set - dirtying the primvars alone
  /// would leave Hydra drawing the old count.
  public func drainTopologyDirty() -> Bool
  {
    protectedActive.withLock
    { state in
      state.published = state.count
      let was = state.topologyDirty
      state.topologyDirty = false
      return was
    }
  }

  /// Narrows the field to its first `count` instances.
  ///
  /// Safe to call from the UI thread at any point in the frame: it only moves
  /// the requested count, which nothing reads until the next latch.
  public func setActiveCount(_ count: Int)
  {
    protectedActive.withLock
    { state in
      guard state.count != count else { return }
      state.count = count
      state.topologyDirty = true
    }
  }

  // MARK: - Write path

  /// Flags the instancer as needing a `PrimsDirtied` this frame.
  ///
  /// A single bool, not a path set: there is only ever one prim to dirty,
  /// which is the entire point of this path.
  public func markDirty()
  {
    assert(framePhase.current == .mutable,
           "Mutation during the read phase - Hydra may be reading concurrently.")

    protectedDirty.withLock { $0 = true }
  }

  /// Drains the flag. Must run before ``beginReadPhase()``.
  public func drainDirty() -> Bool
  {
    assert(framePhase.current == .mutable,
           "Draining during the read phase.")

    return protectedDirty.withLock
    { flag in
      let was = flag
      flag = false
      return was
    }
  }
}
