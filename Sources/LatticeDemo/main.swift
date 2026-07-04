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
import Lattice

#if canImport(Metal)
  import LatticeMetal
  import Metal
#endif

// A minimal "physics" component pair, standing in for the kind of thing a
// game or simulation would update every frame at scale.
struct Transform: LatticeComponent
{
  var x: Float
  var y: Float
  var z: Float
}

struct Velocity: LatticeComponent
{
  var dx: Float
  var dy: Float
  var dz: Float
}

#if canImport(Metal)
  extension Transform: LatticeGPUComponent {}
  extension Velocity: LatticeGPUComponent {}
#endif

let entityCount = 100_000
let frames = 120
let dt: Float = 1.0 / 60.0

/// Timings from the CPU demo, so the GPU demo can compare against both the
/// serial baseline and the (fairer, harder-to-beat) parallel one.
struct CPUTimings
{
  var serialElapsed: TimeInterval
  var parallelElapsed: TimeInterval
}

func integrate(_ transform: inout Transform, _ velocity: Velocity)
{
  transform.x += velocity.dx * dt
  transform.y += velocity.dy * dt
  transform.z += velocity.dz * dt
}

func printTransform(_ label: String, _ transform: Transform)
{
  print("\(label): (\(transform.x), \(transform.y), \(transform.z))")
}

func runCPUDemo() -> CPUTimings
{
  let store = LatticeStore()
  var entities: [LatticeEntity] = []
  entities.reserveCapacity(entityCount)

  // No registration; spawn lands each entity directly in its final archetype.
  for i in 0 ..< entityCount
  {
    entities.append(
      store.spawn(
        Transform(x: Float(i), y: 0, z: 0),
        Velocity(dx: 1, dy: 0.5, dz: 0)
      )
    )
  }

  let query = store.query(Transform.self, Velocity.self)

  let serialStart = Date()
  for _ in 0 ..< frames
  {
    query.forEachMutatingFirst { _, transform, velocity in integrate(&transform, velocity) }
    store.advanceFrame()
  }
  let serialElapsed = Date().timeIntervalSince(serialStart)

  let parallelStart = Date()
  for _ in 0 ..< frames
  {
    query.forEachMutatingFirstParallel { transform, velocity in integrate(&transform, velocity) }
    store.advanceFrame()
  }
  let parallelElapsed = Date().timeIntervalSince(parallelStart)

  print("Lattice demo (CPU)")
  print("Entities:                    \(entityCount)")
  print("Frames:                      \(frames)")
  print("Serial   per-frame avg:      \(String(format: "%.5f", serialElapsed / Double(frames) * 1000))ms")
  print("Parallel per-frame avg:      \(String(format: "%.5f", parallelElapsed / Double(frames) * 1000))ms")
  print("Parallel speedup:            \(String(format: "%.2f", serialElapsed / parallelElapsed))x")
  print("Transform mutations:         \(store.mutationGeneration(of: Transform.self))")

  if let sample = store.get(Transform.self, for: entities[0])
  {
    printTransform("entities[0].Transform after \(frames * 2) CPU frames", sample)
  }

  return CPUTimings(serialElapsed: serialElapsed, parallelElapsed: parallelElapsed)
}

#if canImport(Metal)
  let metalShaderSource = """
  #include <metal_stdlib>
  using namespace metal;

  struct Transform
  {
    float x;
    float y;
    float z;
  };

  struct Velocity
  {
    float dx;
    float dy;
    float dz;
  };

  kernel void integrate(
    device Transform *transforms [[buffer(0)]],
    const device Velocity *velocities [[buffer(1)]],
    constant float &dt [[buffer(2)]],
    constant uint &count [[buffer(3)]],
    uint id [[thread_position_in_grid]]
  )
  {
    if (id >= count) { return; }

    transforms[id].x += velocities[id].dx * dt;
    transforms[id].y += velocities[id].dy * dt;
    transforms[id].z += velocities[id].dz * dt;
  }
  """

  func makeComputePipeline(device: MTLDevice) throws -> MTLComputePipelineState
  {
    let library = try device.makeLibrary(source: metalShaderSource, options: nil)
    guard let function = library.makeFunction(name: "integrate")
    else
    {
      throw DemoError.missingMetalFunction("integrate")
    }
    return try device.makeComputePipelineState(function: function)
  }

  func runGPUDemo(cpuTimings: CPUTimings)
  {
    guard let device = MTLCreateSystemDefaultDevice()
    else
    {
      print("Lattice demo (GPU)")
      print("Metal unavailable: no default MTLDevice")
      return
    }

    do
    {
      let pipeline = try makeComputePipeline(device: device)
      guard let commandQueue = device.makeCommandQueue()
      else
      {
        print("Lattice demo (GPU)")
        print("Metal unavailable: failed to create command queue")
        return
      }

      let store = LatticeStore()
      store.register(Transform.self) {
        MetalBackedColumn<Transform>(device: device, initialCapacity: entityCount)
      }
      store.register(Velocity.self) {
        MetalBackedColumn<Velocity>(device: device, initialCapacity: entityCount)
      }

      var entities: [LatticeEntity] = []
      entities.reserveCapacity(entityCount)
      for i in 0 ..< entityCount
      {
        entities.append(
          store.spawn(
            Transform(x: Float(i), y: 0, z: 0),
            Velocity(dx: 1, dy: 0.5, dz: 0)
          )
        )
      }

      let query = store.query(Transform.self, Velocity.self)
      var queriedColumnPairs: [(MetalBackedColumn<Transform>, MetalBackedColumn<Velocity>)] = []
      query.forEachColumnPair { transformStorage, velocityStorage in
        guard let transformColumn = transformStorage as? MetalBackedColumn<Transform>,
              let velocityColumn = velocityStorage as? MetalBackedColumn<Velocity>
        else { return }
        queriedColumnPairs.append((transformColumn, velocityColumn))
      }

      guard !queriedColumnPairs.isEmpty
      else
      {
        print("Lattice demo (GPU)")
        print("Metal unavailable: query did not find Metal-backed columns")
        return
      }

      var frameDelta = dt
      var componentCount = UInt32(entityCount)
      let threadsPerThreadgroup = MTLSize(
        width: min(pipeline.maxTotalThreadsPerThreadgroup, 256),
        height: 1,
        depth: 1
      )
      let threadgroups = MTLSize(
        width: (entityCount + threadsPerThreadgroup.width - 1) / threadsPerThreadgroup.width,
        height: 1,
        depth: 1
      )

      let gpuStart = Date()
      for _ in 0 ..< frames
      {
        for (transformColumn, velocityColumn) in queriedColumnPairs
        {
          guard let commandBuffer = commandQueue.makeCommandBuffer(),
                let encoder = commandBuffer.makeComputeCommandEncoder()
          else
          {
            print("Lattice demo (GPU)")
            print("Metal unavailable: failed to encode compute work")
            return
          }

          componentCount = UInt32(transformColumn.count)
          encoder.setComputePipelineState(pipeline)
          encoder.setBuffer(transformColumn.metalBuffer, offset: 0, index: 0)
          encoder.setBuffer(velocityColumn.metalBuffer, offset: 0, index: 1)
          encoder.setBytes(&frameDelta, length: MemoryLayout<Float>.stride, index: 2)
          encoder.setBytes(&componentCount, length: MemoryLayout<UInt32>.stride, index: 3)
          encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
          encoder.endEncoding()
          commandBuffer.commit()
          commandBuffer.waitUntilCompleted()
          transformColumn.markWholeColumnChanged(tick: store.currentTick)
        }
        store.advanceFrame()
      }
      let gpuElapsed = Date().timeIntervalSince(gpuStart)

      print("")
      print("Lattice demo (GPU)")
      print("Entities:                    \(entityCount)")
      print("Frames:                      \(frames)")
      print("Compute per-frame avg:       \(String(format: "%.5f", gpuElapsed / Double(frames) * 1000))ms")
      print("GPU speedup vs serial:       \(String(format: "%.2f", cpuTimings.serialElapsed / gpuElapsed))x")
      print("GPU speedup vs parallel:     \(String(format: "%.2f", cpuTimings.parallelElapsed / gpuElapsed))x")
      print("Device:                      \(device.name)")
      print("Transform mutations:         \(store.mutationGeneration(of: Transform.self))")

      if let sample = store.get(Transform.self, for: entities[0])
      {
        printTransform("entities[0].Transform after \(frames) GPU frames", sample)
      }
    }
    catch
    {
      print("Lattice demo (GPU)")
      print("Metal unavailable: \(error)")
    }
  }
#endif

enum DemoError: Error
{
  case missingMetalFunction(String)
}

let cpuTimings = runCPUDemo()
#if canImport(Metal)
  runGPUDemo(cpuTimings: cpuTimings)
#else
  print("")
  print("Lattice demo (GPU)")
  print("Metal unavailable: this platform cannot import Metal")
#endif
