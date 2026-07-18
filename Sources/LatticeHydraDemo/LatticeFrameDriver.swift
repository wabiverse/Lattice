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
import HydraKit
import LatticeCore
import LatticeUSD
import lattice

#if canImport(Metal)
  import LatticeMetal
  import Metal
#endif

/// A snapshot of one frame's cost, split by phase.
public struct LatticeFrameStats: Sendable, Equatable
{
  /// Cubes whose transform was recomputed this frame.
  public var mutated: Int = 0
  /// Which path recomputed them.
  public var drivePath: String = "-"
  /// The motion field driving them, and roughly what it costs per instance.
  public var kernelLabel: String = "-"
  public var kernelCost: String = ""
  /// Recomputing every transform - a compute dispatch on the GPU path
  /// (including the wait for completion), a parallel column pass on the CPU one.
  public var mutateMilliseconds: Double = 0
  /// Publishing the dirty set and letting Hydra fan `PrimsDirtied` out.
  public var notifyMilliseconds: Double = 0
  /// Wall clock between successive `hydraWillPull`s.
  public var frameMilliseconds: Double = 0
  /// Live scene indices the bridge is driving - `0` means registration missed
  /// render index construction and nothing is overriding.
  public var liveSceneIndices: Int = 0

  public var framesPerSecond: Double
  {
    frameMilliseconds > 0 ? 1000.0 / frameMilliseconds : 0
  }

  /// Transform writes per second sustained by the mutation pass alone.
  public var transformsPerSecond: Double
  {
    mutateMilliseconds > 0 ? Double(mutated) / (mutateMilliseconds / 1000.0) : 0
  }

  public init() {}
}

/// Exponentially smooths per-frame timings on their way to the HUD.
public struct LatticeStatsSmoother: Sendable
{
  /// Roughly a ten-frame memory - responsive enough to track a real change,
  /// slow enough that one stalled frame does not dominate the reading.
  private let alpha = 0.1

  public private(set) var frameMilliseconds: Double = 0
  public private(set) var mutateMilliseconds: Double = 0
  public private(set) var notifyMilliseconds: Double = 0

  public init() {}

  public mutating func record(frameMs: Double, mutateMs: Double, notifyMs: Double)
  {
    // the very first frame has no predecessor to measure against and reports
    // zero, feeding that in would drag the average down for several seconds.
    if frameMs > 0
    {
      frameMilliseconds = frameMilliseconds > 0
        ? frameMilliseconds * (1 - alpha) + frameMs * alpha
        : frameMs
    }
    mutateMilliseconds = mutateMilliseconds > 0
      ? mutateMilliseconds * (1 - alpha) + mutateMs * alpha
      : mutateMs
    notifyMilliseconds = notifyMilliseconds > 0
      ? notifyMilliseconds * (1 - alpha) + notifyMs * alpha
      : notifyMs
  }
}

#if canImport(Metal)
  /// The ripple, as a compute kernel.
  ///
  /// Byte-identical in intent to ``LatticeFrameDriver/pose(_:_:)`` - the CPU
  /// fallback and this kernel must produce the same pose.
  ///
  /// The struct layouts here are the contract with Swift: plain `float`
  /// scalars, never `float3`, whose 16-byte MSL alignment would not match
  /// Swift's packing of the same fields.
  let latticeRippleShader = """
    #include <metal_stdlib>
    using namespace metal;

    struct RippleMotion
    {
      float homeX;
      float homeY;
      float homeZ;
      float radius;
      float phase;
      float spin;
      float scale;
    };

    struct XformGPU
    {
      float m[16];
    };

    kernel void ripple(
      device XformGPU *xforms [[buffer(0)]],
      const device RippleMotion *motions [[buffer(1)]],
      constant float &t [[buffer(2)]],
      constant uint &count [[buffer(3)]],
      uint id [[thread_position_in_grid]]
    )
    {
      if (id >= count) { return; }

      const RippleMotion mo = motions[id];

      // a spherical wave travelling out from the centre of the grid.
      const float wave = sin(mo.radius * 0.55f - t * 2.4f + mo.phase);
      const float lift = wave * 1.35f;
      // cubes ride the crest outward a little, so it reads as a pulse
      // rather than a flat bob.
      const float swell = 1.0f + wave * 0.06f;

      const float angle = t * mo.spin + mo.phase;
      const float c = cos(angle);
      const float s = sin(angle);
      const float k = mo.scale * (1.0f + wave * 0.25f);

      // row-major with translation in the last row - GfMatrix4d's row-vector
      // convention, so widening on the read side is a cast, not a transpose.
      device float *o = xforms[id].m;
      o[0]  = k * c; o[1]  = 0.0f; o[2]  = -k * s; o[3]  = 0.0f;
      o[4]  = 0.0f;  o[5]  = k;    o[6]  = 0.0f;   o[7]  = 0.0f;
      o[8]  = k * s; o[9]  = 0.0f; o[10] = k * c;  o[11] = 0.0f;
      o[12] = mo.homeX * swell;
      o[13] = mo.homeY * swell + lift;
      o[14] = mo.homeZ * swell;
      o[15] = 1.0f;
    }
    """
#endif

/// Drives the scene between Hydra's frames.
///
/// The whole contract lives in the two callbacks. `hydraWillPull` is the only
/// window in which the store may be written; by the time it returns, every
/// transform Hydra is about to read has been recomputed, published as a dirty
/// set, and the store has been flipped to its read phase. `hydraDidPull` flips
/// it back.
///
/// ```
/// mutate -> advanceChangeTick() -> LatticeHydraTick() -> beginReadPhase()
///        -> Hydra pulls GetPrim() -> endReadPhase()
/// ```
///
/// Getting that order wrong is not a subtle bug: Hydra pulls `GetPrim()`
/// concurrently from several threads, so a write that escapes into the read
/// phase races those readers. The phase assertions in ``LatticeXformSource``
/// and ``LatticePathTable`` trap on it in debug builds.
public final class LatticeFrameDriver: LatticeDriving
{
  private let scene: LatticeScene
  private let startTime: Date = Date()
  private var lastPullStart: CFAbsoluteTime = 0

  private let statsLock = NSLock()
  private var _stats = LatticeFrameStats()
  /// Touched only from `hydraWillPull`, which Hydra calls one frame at a time.
  private var smoother = LatticeStatsSmoother()

  /// Freezing still pays the notify cost but skips the math, which makes it
  /// easy to show what the mutation pass alone is worth.
  public var isPaused: Bool = false

  /// Stored to satisfy ``LatticeDriving``, but inert: the per-prim path exists
  /// as the "what per-prim scene-graph updates cost" comparison, and carries
  /// only the ripple. Reporting `supportsKernelSwitching == false` lets
  /// the UI disable the buttons rather than offer ones that do nothing.
  public var kernel: LatticeKernel = .ripple
  public var supportsKernelSwitching: Bool { false }

  #if canImport(Metal)
    private var commandQueue: (any MTLCommandQueue)?
    private var pipeline: (any MTLComputePipelineState)?
    /// Cached once: the columns do not grow after population, so the
    /// `MTLBuffer` handles stay valid. If the demo ever spawned cubes
    /// mid-run this would need to watch `bufferGeneration` and re-query.
    private var columns: [(xform: MetalBackedColumn<XformGPU>, motion: MetalBackedColumn<RippleMotion>)] = []
  #endif

  public init(scene: LatticeScene)
  {
    self.scene = scene

    #if canImport(Metal)
      if scene.drivePath == .gpu, let device = scene.device
      {
        do
        {
          // fast math on: this is a viewport transform, not an IEEE-parity
          // benchmark, and the CPU fallback is only ever compared by eye.
          let options = MTLCompileOptions()
          options.mathMode = .fast
          let library = try device.makeLibrary(source: latticeRippleShader, options: options)
          guard let function = library.makeFunction(name: "ripple")
          else
          {
            print("[lattice] kernel 'ripple' missing - falling back to CPU")
            return
          }
          pipeline = try device.makeComputePipelineState(function: function)
          commandQueue = device.makeCommandQueue()

          scene.store.query(XformGPU.self, RippleMotion.self).forEachColumnPair
          { xformStorage, motionStorage in
            guard let x = xformStorage as? MetalBackedColumn<XformGPU>,
                  let m = motionStorage as? MetalBackedColumn<RippleMotion>
            else { return }
            columns.append((x, m))
          }

          if columns.isEmpty
          {
            print("[lattice] no Metal-backed columns found - falling back to CPU")
          }
        }
        catch
        {
          print("[lattice] compute pipeline failed (\(error)) - falling back to CPU")
        }
      }
    #endif
  }

  public func snapshot() -> LatticeFrameStats
  {
    statsLock.lock()
    defer { statsLock.unlock() }
    return _stats
  }

  /// `true` when the compute path is actually wired up.
  public var isGPUActive: Bool
  {
    #if canImport(Metal)
      return pipeline != nil && commandQueue != nil && !columns.isEmpty
    #else
      return false
    #endif
  }

  // MARK: - Hydra.FrameDelegate

  public func hydraWillPull(deltaTime: Double)
  {
    let pullStart = CFAbsoluteTimeGetCurrent()
    let frameMs = lastPullStart > 0 ? (pullStart - lastPullStart) * 1000.0 : 0
    lastPullStart = pullStart

    let t = Date().timeIntervalSince(startTime)

    // 1. recompute every transform.
    let mutateStart = CFAbsoluteTimeGetCurrent()
    var mutated = 0
    if !isPaused
    {
      mutated = isGPUActive ? dispatchGPU(t: t) : mutateCPU(t: t)
    }
    let mutateMs = (CFAbsoluteTimeGetCurrent() - mutateStart) * 1000.0

    // 2. publish, one lock for the whole batch rather than one per path.
    let notifyStart = CFAbsoluteTimeGetCurrent()
    if !isPaused
    {
      scene.source.markDirty(contentsOf: scene.animatedPaths)
    }

    // 3. close the write window in the order the store asserts on, bump the
    //    change tick, let the bridge drain the dirty set and fan `PrimsDirtied`
    //    out, and only then hand the store to hydra.
    scene.store.advanceChangeTick()
    LatticeHydraTick()
    scene.source.beginReadPhase()
    let notifyMs = (CFAbsoluteTimeGetCurrent() - notifyStart) * 1000.0

    smoother.record(frameMs: frameMs, mutateMs: mutateMs, notifyMs: notifyMs)

    statsLock.lock()
    _stats.mutated = mutated
    _stats.drivePath = isGPUActive
      ? "gpu (metal)"
      : (scene.drivePath == .gpu ? "cpu (gpu fallback)" : "cpu (parallel)")
    _stats.kernelLabel = kernel.label
    _stats.kernelCost = kernel.costBlurb
    _stats.mutateMilliseconds = smoother.mutateMilliseconds
    _stats.notifyMilliseconds = smoother.notifyMilliseconds
    _stats.frameMilliseconds = smoother.frameMilliseconds
    _stats.liveSceneIndices = Int(LatticeHydraLiveSceneIndexCount())
    statsLock.unlock()
  }

  public func hydraDidPull()
  {
    // paired with `beginReadPhase()` on every path, including the early
    // returns inside Hydra's own draw - `hydraDidPull` is called from a
    // `defer`.
    //
    // Nothing else belongs here: `advanceFrame()` would bump the change
    // tick a second time in the same frame, since `hydraWillPull` already
    // advanced it.
    scene.source.endReadPhase()
  }

  // MARK: - GPU path

  #if canImport(Metal)
    /// Encodes one dispatch per Metal-backed archetype and waits for it.
    ///
    /// The wait is not optional. `.storageModeShared` means the kernel is
    /// writing the very bytes `getLiveXform(_:)` is about to read, so the
    /// command buffer has to retire before the read phase opens - otherwise
    /// Hydra samples a half-written column.
    private func dispatchGPU(t: Double) -> Int
    {
      guard let pipeline, let commandQueue else { return 0 }

      var time = Float(t)
      var total = 0

      for (xformColumn, motionColumn) in columns
      {
        let count = xformColumn.count
        guard count > 0,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { continue }

        var elementCount = UInt32(count)
        let width = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
        let threadsPerThreadgroup = MTLSize(width: width, height: 1, depth: 1)
        let threadgroups = MTLSize(width: (count + width - 1) / width, height: 1, depth: 1)

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(xformColumn.metalBuffer, offset: 0, index: 0)
        encoder.setBuffer(motionColumn.metalBuffer, offset: 0, index: 1)
        encoder.setBytes(&time, length: MemoryLayout<Float>.stride, index: 2)
        encoder.setBytes(&elementCount, length: MemoryLayout<UInt32>.stride, index: 3)
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // the kernel wrote through the buffer behind the column's back,
        // so the column's own change tracking has to be told.
        xformColumn.markWholeColumnChanged(tick: scene.store.currentTick)
        total += count
      }
      return total
    }
  #endif

  // MARK: - CPU fallback

  /// Drives whichever column the scene was actually built with.
  ///
  /// The branch matters: if the compute pipeline failed to build, the store was
  /// still populated with ``XformGPU`` columns, and a pass over ``Xform``
  /// would match no archetype at all - leaving the viewport frozen rather than
  /// merely slower. Degrading to a slower picture is fine; degrading to a still
  /// one while reporting success is not.
  private func mutateCPU(t: Double) -> Int
  {
    switch scene.drivePath
    {
      case .gpu:
        scene.store.query(XformGPU.self, RippleMotion.self)
          .forEachMutatingFirstParallel
        { xform, motion in
          xform.matrix = LatticeFrameDriver.poseF(motion, t)
        }

      case .cpu:
        scene.store.query(Xform.self, RippleMotion.self)
          .forEachMutatingFirstParallel
        { xform, motion in
          xform.matrix = LatticeFrameDriver.pose(motion, t)
        }
    }
    return scene.cubeCount
  }

  /// The pose of one cube at time `t`, in double precision.
  ///
  /// Mirrors `latticeRippleShader` exactly, the two must agree or switching
  /// paths would visibly pop.
  @inline(__always)
  static func pose(_ m: RippleMotion, _ t: Double) -> LatticeDouble4x4
  {
    let wave = sin(Double(m.radius) * 0.55 - t * 2.4 + Double(m.phase))
    let lift = wave * 1.35
    let swell = 1.0 + wave * 0.06

    let angle = t * Double(m.spin) + Double(m.phase)
    let c = cos(angle)
    let s = sin(angle)
    let k = Double(m.scale) * (1.0 + wave * 0.25)

    return LatticeDouble4x4(
      k * c, 0, -k * s, 0,
      0, k, 0, 0,
      k * s, 0, k * c, 0,
      Double(m.homeX) * swell, Double(m.homeY) * swell + lift, Double(m.homeZ) * swell, 1
    )
  }

  /// Single-precision form, for driving a ``XformGPU`` column from the CPU when
  /// the compute pipeline is unavailable. Narrowing after the fact rather than
  /// duplicating the math keeps the two poses identical by construction.
  @inline(__always)
  static func poseF(_ m: RippleMotion, _ t: Double) -> LatticeFloat4x4
  {
    let d = pose(m, t)
    return LatticeFloat4x4(
      Float(d.m00), Float(d.m01), Float(d.m02), Float(d.m03),
      Float(d.m10), Float(d.m11), Float(d.m12), Float(d.m13),
      Float(d.m20), Float(d.m21), Float(d.m22), Float(d.m23),
      Float(d.m30), Float(d.m31), Float(d.m32), Float(d.m33)
    )
  }
}
