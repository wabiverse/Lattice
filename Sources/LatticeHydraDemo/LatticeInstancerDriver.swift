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

/// What the HUD needs from whichever driver is running.
public protocol LatticeDriving: Hydra.FrameDelegate
{
  func snapshot() -> LatticeFrameStats

  /// The motion field currently driving the instances.
  ///
  /// Settable live. Because every kernel is a pure function of `(motion, t)`,
  /// swapping one is instantaneous and needs no reset - the next frame simply
  /// poses each instance from its home under a different function.
  var kernel: LatticeKernel { get set }

  /// `false` where switching does nothing, so the UI can say so rather than
  /// offering buttons that appear to do nothing.
  var supportsKernelSwitching: Bool { get }
}

/// Drives the instancer scene.
///
/// Identical frame contract to ``LatticeFrameDriver``, the only difference
/// is what gets published. Instead of pushing a hundred thousand paths into a
/// dirty set and asking Hydra to re-sync a hundred thousand prims, this flips
/// one bool and dirties one prim.
public final class LatticeInstancerDriver: LatticeDriving
{
  private let scene: LatticeInstancerScene
  private let startTime: Date = Date()
  private var lastPullStart: CFAbsoluteTime = 0

  private let statsLock = NSLock()
  private var _stats = LatticeFrameStats()
  /// Touched only from `hydraWillPull`, which Hydra calls one frame at a time.
  private var smoother = LatticeStatsSmoother()

  public var isPaused: Bool = false

  /// Read on the render thread, written from the UI thread when a button is
  /// pressed. A `Bool`-sized enum write is atomic in practice and the worst a
  /// torn read could do is render one frame with the previous field, so this is
  /// deliberately unsynchronised rather than paying a lock every frame.
  public var kernel: LatticeKernel = .ripple

  public var supportsKernelSwitching: Bool { isGPUActive }

  #if canImport(Metal)
    private var commandQueue: (any MTLCommandQueue)?
    /// One pipeline per kernel, all built up front from a single library.
    /// Switching is then picking a different entry from this table -
    /// compiling on demand would stall the render thread.
    private var pipelines: [LatticeKernel: any MTLComputePipelineState] = [:]
    private var columns: [(xform: MetalBackedColumn<InstanceXform>, motion: MetalBackedColumn<RippleMotion>)] = []
  #endif

  public init(scene: LatticeInstancerScene)
  {
    self.scene = scene

    #if canImport(Metal)
      if scene.drivePath == .gpu, let device = scene.device
      {
        do
        {
          let options = MTLCompileOptions()
          options.mathMode = .fast
          let library = try device.makeLibrary(source: latticeKernelShader, options: options)

          // every kernel, up front. a missing one is reported and skipped
          // rather than aborting them all.
          for k in LatticeKernel.allCases
          {
            guard let function = library.makeFunction(name: k.functionName)
            else
            {
              print("[lattice] kernel '\(k.functionName)' missing - '\(k.label)' unavailable")
              continue
            }
            pipelines[k] = try device.makeComputePipelineState(function: function)
          }

          guard !pipelines.isEmpty
          else
          {
            print("[lattice] no kernels compiled - falling back to CPU")
            return
          }
          commandQueue = device.makeCommandQueue()

          scene.store.query(InstanceXform.self, RippleMotion.self).forEachColumnPair
          { xformStorage, motionStorage in
            guard let x = xformStorage as? MetalBackedColumn<InstanceXform>,
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

    bindSource()
  }

  /// Points the source at the instance column.
  ///
  /// A single archetype is expected - every instance carries the same two
  /// components - so the scene index can read one contiguous run. If the store
  /// ever split them across archetypes the column would no longer be one array
  /// and this would need to gather instead, so the split is reported rather than
  /// silently rendering a partial field.
  private func bindSource()
  {
    #if canImport(Metal)
      guard columns.count == 1, let column = columns.first?.xform
      else
      {
        if columns.count > 1
        {
          print("[lattice] instance column split across \(columns.count) archetypes - unsupported")
        }
        return
      }
      scene.source.bind(base: UnsafeRawPointer(column.metalBuffer.contents()),
                        count: column.count)
    #endif
  }

  public func snapshot() -> LatticeFrameStats
  {
    statsLock.lock()
    defer { statsLock.unlock() }
    return _stats
  }

  public var isGPUActive: Bool
  {
    #if canImport(Metal)
      return !pipelines.isEmpty && commandQueue != nil && columns.count == 1
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

    let mutateStart = CFAbsoluteTimeGetCurrent()
    var mutated = 0
    if !isPaused
    {
      mutated = isGPUActive ? dispatchGPU(t: t) : mutateCPU(t: t)
    }
    let mutateMs = (CFAbsoluteTimeGetCurrent() - mutateStart) * 1000.0

    // one flag, one prim. the array itself is never copied here - the scene
    // index de-interleaves it straight out of the column when hydra pulls.
    let notifyStart = CFAbsoluteTimeGetCurrent()
    if !isPaused
    {
      scene.source.markDirty()
    }
    scene.store.advanceChangeTick()
    LatticeHydraInstancerTick()
    scene.source.beginReadPhase()
    let notifyMs = (CFAbsoluteTimeGetCurrent() - notifyStart) * 1000.0

    smoother.record(frameMs: frameMs, mutateMs: mutateMs, notifyMs: notifyMs)

    statsLock.lock()
    _stats.mutated = mutated
    _stats.drivePath = isGPUActive
      ? "gpu (metal) - instancer"
      : (scene.drivePath == .gpu ? "cpu (gpu fallback)" : "cpu (parallel)")
    _stats.kernelLabel = kernel.label
    _stats.kernelCost = kernel.costBlurb
    _stats.mutateMilliseconds = smoother.mutateMilliseconds
    _stats.notifyMilliseconds = smoother.notifyMilliseconds
    _stats.frameMilliseconds = smoother.frameMilliseconds
    _stats.liveSceneIndices = Int(LatticeHydraLiveInstancerSceneIndexCount())
    statsLock.unlock()
  }

  public func hydraDidPull()
  {
    scene.source.endReadPhase()
  }

  // MARK: - GPU path

  #if canImport(Metal)
    private func dispatchGPU(t: Double) -> Int
    {
      // falls back to whatever did compile if the selected kernel is missing,
      // so a bad selection degrades to a different motion rather than a frozen
      // field.
      guard let commandQueue,
            let pipeline = pipelines[kernel] ?? pipelines[.ripple] ?? pipelines.values.first
      else { return 0 }

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
        // shared storage: the kernel is writing the bytes the scene index is
        // about to read, so the buffer has to retire before the read phase.
        commandBuffer.waitUntilCompleted()

        xformColumn.markWholeColumnChanged(tick: scene.store.currentTick)
        total += count
      }
      return total
    }
  #endif

  // MARK: - CPU fallback

  private func mutateCPU(t: Double) -> Int
  {
    scene.store.query(InstanceXform.self, RippleMotion.self)
      .forEachMutatingFirstParallel
    { xform, motion in
      xform = LatticeInstancerDriver.instance(motion, t)
    }
    return scene.instanceCount
  }

  /// Mirrors `kRipple` from `latticeKernelShader`.
  @inline(__always)
  static func instance(_ m: RippleMotion, _ t: Double) -> InstanceXform
  {
    let wave = sin(Double(m.radius) * 0.55 - t * 2.4 + Double(m.phase))
    let lift = wave * 1.35
    let swell = 1.0 + wave * 0.06
    let k = Double(m.scale) * (1.0 + wave * 0.25)
    let halfAngle = (t * Double(m.spin) + Double(m.phase)) * 0.5

    return InstanceXform(
      tx: Float(Double(m.homeX) * swell),
      ty: Float(Double(m.homeY) * swell + lift),
      tz: Float(Double(m.homeZ) * swell),
      sx: Float(k), sy: Float(k), sz: Float(k),
      rx: 0, ry: Float(sin(halfAngle)), rz: 0, rw: Float(cos(halfAngle))
    )
  }
}
