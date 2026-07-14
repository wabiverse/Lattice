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
import LatticeCore
import LatticeUSD
import lattice
import OpenUSDKit

#if canImport(Metal)
  import LatticeMetal
  import Metal
#endif

/// A minimal "physics" component pair, standing in for the kind of thing a
/// game or simulation would update every frame at scale.
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

/// Per-entity ALU work each frame does. Cranked up so integration is
/// compute-bound rather than memory-bound - the scenario where the GPU's raw
/// throughput actually beats the CPU. A trivial add is dominated by memory and
/// dispatch overhead, and the GPU loses; heavier math is where it pulls ahead.
let heavyWorkIterations = 32

/// The GPU folds this many simulation frames into a single dispatch, so the
/// fixed per-command-buffer cost is paid once per batch instead of once per
/// frame. `frames` need not be a multiple - the last batch just runs shorter.
let framesPerDispatch = 30

/// The USD benchmark authors one real prim (with attributes) per entity. It
/// matches `entityCount` so its CPU/GPU numbers line up with the synthetic
/// demo's - the frame loop it feeds is identical; only the data's provenance
/// (loaded from a USD stage vs. spawned directly) differs.
let usdEntityCount = entityCount

/// Timings from the CPU demo, so the GPU demo can compare against both the
/// serial baseline and the (fairer, harder-to-beat) parallel one.
struct CPUTimings
{
  var serialElapsed: TimeInterval
  var parallelElapsed: TimeInterval
}

/// One heavy, ALU-bound integration step: repeatedly rotates a local copy of the
/// velocity with trig and folds a `sqrt` into the position, so the per-entity
/// cost is real compute rather than a single memory-bound add. The CPU path and
/// the Metal kernel (`metalShaderSource`) run identical math; results agree only
/// to a few significant figures since the GPU runs with fast math (peak
/// throughput) while the CPU uses libm's IEEE `sin`/`cos`/`sqrt`.
func integrate(_ transform: inout Transform, _ velocity: Velocity)
{
  var x = transform.x
  var y = transform.y
  var z = transform.z
  var dx = velocity.dx
  var dy = velocity.dy
  for _ in 0 ..< heavyWorkIterations
  {
    dx += sin(dx) * dt
    dy += cos(dy) * dt
    x += dx * dt
    y += dy * dt
    z += (dx * dx + dy * dy).squareRoot() * dt * 0.001
  }
  transform = Transform(x: x, y: y, z: z)
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
  
  print("")
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
      constant uint &stepsPerDispatch [[buffer(4)]],
      constant uint &heavyIterations [[buffer(5)]],
      uint id [[thread_position_in_grid]]
    )
    {
      if (id >= count) { return; }

      float x = transforms[id].x;
      float y = transforms[id].y;
      float z = transforms[id].z;
      const float startDx = velocities[id].dx;
      const float startDy = velocities[id].dy;

      // One dispatch advances the entity by `stepsPerDispatch` frames, each an
      // identical heavy step to the CPU's `integrate`.
      for (uint f = 0; f < stepsPerDispatch; ++f)
      {
        float dx = startDx;
        float dy = startDy;
        for (uint k = 0; k < heavyIterations; ++k)
        {
          dx += sin(dx) * dt;
          dy += cos(dy) * dt;
          x += dx * dt;
          y += dy * dt;
          z += sqrt(dx * dx + dy * dy) * dt * 0.001;
        }
      }

      transforms[id].x = x;
      transforms[id].y = y;
      transforms[id].z = z;
    }
    """

  func makeComputePipeline(device: MTLDevice) throws -> MTLComputePipelineState
  {
    // Fast math left ON - this is a peak-throughput benchmark (the scenario a
    // production Fabric/USDRT GPU kernel runs in), so we don't handicap the GPU
    // for IEEE parity. The trade-off is that the GPU's trig/sqrt approximations
    // drift from the CPU's libm results, so the CPU/GPU spot-checks below agree
    // only to a few significant figures - expected, not a bug.
    let options = MTLCompileOptions()
    options.mathMode = .fast
    let library = try device.makeLibrary(source: metalShaderSource, options: options)
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
      store.register(Transform.self)
      {
        MetalBackedColumn<Transform>(device: device, initialCapacity: entityCount)
      }
      store.register(Velocity.self)
      {
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
      query.forEachColumnPair
      { transformStorage, velocityStorage in
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
      var heavyIterations = UInt32(heavyWorkIterations)
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
      var remainingFrames = frames
      while remainingFrames > 0
      {
        // Fold up to `framesPerDispatch` frames into this one command buffer.
        var stepsThisDispatch = UInt32(min(framesPerDispatch, remainingFrames))
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
          encoder.setBytes(&stepsThisDispatch, length: MemoryLayout<UInt32>.stride, index: 4)
          encoder.setBytes(&heavyIterations, length: MemoryLayout<UInt32>.stride, index: 5)
          encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
          encoder.endEncoding()
          commandBuffer.commit()
          commandBuffer.waitUntilCompleted()
          transformColumn.markWholeColumnChanged(tick: store.currentTick)
        }
        store.advanceFrame()
        remainingFrames -= Int(stepsThisDispatch)
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

// MARK: - Memory instrumentation

/// The process's resident memory footprint in bytes, as reported by Mach's
/// `phys_footprint` - the same figure Activity Monitor shows under "Memory"
/// and the number that actually matters for "how much RAM is this using".
/// Returns 0 if the kernel query fails.
func currentMemoryFootprint() -> UInt64
{
  var info = task_vm_info_data_t()
  var count = mach_msg_type_number_t(
    MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride
  )
  let result = withUnsafeMutablePointer(to: &info)
  { pointer in
    pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count))
    { intPointer in
      task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPointer, &count)
    }
  }
  return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
}

/// Human-readable byte count, MB above a mebibyte and KB below it.
func formatBytes(_ bytes: UInt64) -> String
{
  let mb = Double(bytes) / (1024 * 1024)
  if mb >= 1 { return String(format: "%.2f MB", mb) }
  return String(format: "%.1f KB", Double(bytes) / 1024)
}

/// Resolves the USD scene to load for the memory-factor benchmark: a
/// `--usd <path>` command-line argument, else the `LATTICE_USD_SCENE`
/// environment variable, else `nil` (fall back to the synthetic stage). Point
/// either at a real scene - e.g. ALab - to measure Lattice's factor on it.
func usdScenePathFromArguments() -> String?
{
  let arguments = CommandLine.arguments
  if let index = arguments.firstIndex(of: "--usd"), index + 1 < arguments.count
  {
    return arguments[index + 1]
  }
  if let path = ProcessInfo.processInfo.environment["LATTICE_USD_SCENE"], !path.isEmpty
  {
    return path
  }
  return nil
}

/// The bounded attribute working set a renderer/sim actually prefetches into
/// Fabric - transforms, geometry, topology, and the primvars a draw reads -
/// rather than every attribute the scene happens to author.
///
/// This is the crux of modelling Fabric faithfully: Fabric does *not*
/// auto-populate every prim. A prim (and a specific attribute on it) lands in
/// Fabric only because something prefetched or queried it, so the resident cost
/// tracks a working set, not the whole stage. Mirroring every attribute of
/// every prim would reproduce the worst case Fabric is built to avoid, not its
/// behaviour - so the memory-factor benchmark prefetches exactly this set.
func isPrefetchedAttribute(_ name: String) -> Bool
{
  // Transforms: the op names vary per prim (translate/orient/scale/transform),
  // so match the whole `xformOp:` family by prefix, plus the op ordering.
  if name.hasPrefix("xformOp:") { return true }

  return switch name
  {
    case "xformOpOrder",
         "points", "normals", "extent",
         "faceVertexIndices", "faceVertexCounts",
         "curveVertexCounts", "widths",
         "primvars:st", "primvars:displayColor",
         "visibility":
      true
    default:
      false
  }
}

/// Turns Lattice "on" against a scene the way Fabric populates from a stage:
/// a prim enters the store only because a prefetch touched one of the
/// attributes in ``isPrefetchedAttribute(_:)`` on it, and only those attributes
/// are mirrored - each into its own dense, runtime-named column via
/// ``LatticeStore/setDynamic(_:forKey:on:)``, prim as the row, attribute name
/// as the column. Array payloads are content-hash binned by the prefetch, so
/// geometry USD shares across referenced/instanced prims is stored once here
/// too. Returns what was mirrored, including the unique/shared array split.
@discardableResult
func prefetchWorkingSet(into store: LatticeStore, source: USDStageSource) -> USDPopulationSync.PrefetchStats
{
  let paths = LatticePathTable(framePhase: store.framePhase)
  let sync = USDPopulationSync(store: store, paths: paths, source: source)
  return sync.prefetch(where: isPrefetchedAttribute)
}

// MARK: - USD-populated benchmark

/// Builds a USD stage of `primCount` prims, each carrying a `xformOp:translate`
/// and a `velocity` (both `float3`) - the same two fields the integration
/// kernel drives, so the store can be populated straight from USD and then
/// simulated on CPU and GPU.
///
/// The stage is written as a `.usda` layer and opened in one shot rather than
/// authored prim-by-prim on a live stage: USD recomposes on every live edit, so
/// incremental authoring is orders of magnitude slower and would cap how many
/// prims the demo can afford. A one-shot load composes once - faster, and closer
/// to how a real pipeline gets its stage.
func makeUSDStage(primCount: Int) -> UsdStage
{
  var usda = "#usda 1.0\n\n"
  usda.reserveCapacity(primCount * 96)
  for i in 0 ..< primCount
  {
    usda += "def \"prim\(i)\"\n{\n"
    usda += "    float3 xformOp:translate = (\(i), 0, 0)\n"
    usda += "    custom float3 velocity = (1, 0.5, 0)\n"
    usda += "}\n\n"
  }

  let filename = "lattice-usd-demo-\(UUID().uuidString).usda"
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
  try? usda.write(to: url, atomically: true, encoding: .utf8)
  defer { try? FileManager.default.removeItem(at: url) }
  return Usd.Stage.open(url.path)
}

/// Binds one entity per prim and pulls `xformOp:translate`/`velocity` into
/// `Transform`/`Velocity` columns. Register any custom (e.g. Metal-backed)
/// columns on `store` *before* calling this. Returns the path table so callers
/// can look an entity up by prim path for spot-checks.
@discardableResult
func populateFromUSD(into store: LatticeStore, source: USDStageSource) -> LatticePathTable
{
  let paths = LatticePathTable(framePhase: store.framePhase)
  let sync = USDPopulationSync(store: store, paths: paths, source: source)
  sync.syncAll()
  sync.populate(Transform.self, from: "xformOp:translate")
  { value in
    guard case let .float3(x, y, z) = value else { return nil }
    return Transform(x: x, y: y, z: z)
  }
  sync.populate(Velocity.self, from: "velocity")
  { value in
    guard case let .float3(dx, dy, dz) = value else { return nil }
    return Velocity(dx: dx, dy: dy, dz: dz)
  }
  return paths
}

/// Register USD plugins prior to working with any real ``USDStageSource``.
func runUSDPluginRegistration()
{
  // register all USD plugin resources.
  Pixar.Bundler.shared.setup(.resources)
}

/// End-to-end USD benchmark: author a stage, populate a `LatticeStore` from a
/// real ``USDStageSource``, then run the same integration serial, parallel, and
/// on the GPU.
func runUSDDemo()
{
  // building + opening the .usda stage is pure USD fixture setup, not a Lattice
  // cost, so it's deliberately not timed or reported. announced up front so any
  // pause reads as USD work, not Lattice.
  print("")
  print("Authoring a new USD stage with \(usdEntityCount) prims...")
  let stage = makeUSDStage(primCount: usdEntityCount)
  let source = USDStageSource(stage: stage)

  print("")
  print("Lattice demo (USD population -> CPU)")
  
  let store = LatticeStore()
  let populateStart = Date()
  let paths = populateFromUSD(into: store, source: source)
  let populateElapsed = Date().timeIntervalSince(populateStart)

  // serial and parallel baselines, both over the USD-populated store, so the
  // GPU run below has a same-workload, same-entity-count comparison.
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

  print("Prims authored:              \(usdEntityCount)")
  print("Entities populated:          \(store.entityCount)")
  print("Frames:                      \(frames)")
  print("USD -> store populate:       \(String(format: "%.5f", populateElapsed * 1000))ms")
  print("Serial   per-frame avg:      \(String(format: "%.5f", serialElapsed / Double(frames) * 1000))ms")
  print("Parallel per-frame avg:      \(String(format: "%.5f", parallelElapsed / Double(frames) * 1000))ms")
  print("Parallel speedup vs serial:  \(String(format: "%.2f", serialElapsed / parallelElapsed))x")

  if let prim0 = paths.entity(for: "/prim0"), let sample = store.get(Transform.self, for: prim0)
  {
    printTransform("/prim0.Transform after \(frames * 2) CPU frames", sample)
  }

  #if canImport(Metal)
    guard let device = MTLCreateSystemDefaultDevice()
    else
    {
      print("")
      print("Lattice demo (USD population -> GPU)")
      print("Metal unavailable: no default MTLDevice")
      return
    }

    do
    {
      let pipeline = try makeComputePipeline(device: device)
      guard let commandQueue = device.makeCommandQueue()
      else
      {
        print("")
        print("Lattice demo (USD population -> GPU)")
        print("Metal unavailable: failed to create command queue")
        return
      }

      // metal-backed columns must be registered before population so the pulled
      // USD values land straight in the MTLBuffer the compute pass will bind.
      let gpuStore = LatticeStore()
      gpuStore.register(Transform.self)
      {
        MetalBackedColumn<Transform>(device: device, initialCapacity: usdEntityCount)
      }
      gpuStore.register(Velocity.self)
      {
        MetalBackedColumn<Velocity>(device: device, initialCapacity: usdEntityCount)
      }

      let gpuPopulateStart = Date()
      let gpuPaths = populateFromUSD(into: gpuStore, source: source)
      let gpuPopulateElapsed = Date().timeIntervalSince(gpuPopulateStart)

      var queriedColumnPairs: [(MetalBackedColumn<Transform>, MetalBackedColumn<Velocity>)] = []
      gpuStore.query(Transform.self, Velocity.self).forEachColumnPair
      { transformStorage, velocityStorage in
        guard let transformColumn = transformStorage as? MetalBackedColumn<Transform>,
              let velocityColumn = velocityStorage as? MetalBackedColumn<Velocity>
        else { return }
        queriedColumnPairs.append((transformColumn, velocityColumn))
      }

      guard !queriedColumnPairs.isEmpty
      else
      {
        print("")
        print("Lattice demo (USD population -> GPU)")
        print("Metal unavailable: query did not find Metal-backed columns")
        return
      }

      var frameDelta = dt
      var componentCount = UInt32(usdEntityCount)
      var heavyIterations = UInt32(heavyWorkIterations)
      let threadsPerThreadgroup = MTLSize(
        width: min(pipeline.maxTotalThreadsPerThreadgroup, 256),
        height: 1,
        depth: 1
      )

      let gpuStart = Date()
      var remainingFrames = frames
      while remainingFrames > 0
      {
        // Fold up to `framesPerDispatch` frames into this one command buffer.
        var stepsThisDispatch = UInt32(min(framesPerDispatch, remainingFrames))
        for (transformColumn, velocityColumn) in queriedColumnPairs
        {
          guard let commandBuffer = commandQueue.makeCommandBuffer(),
                let encoder = commandBuffer.makeComputeCommandEncoder()
          else
          {
            print("")
            print("Lattice demo (USD population -> GPU)")
            print("Metal unavailable: failed to encode compute work")
            return
          }

          componentCount = UInt32(transformColumn.count)
          let threadgroups = MTLSize(
            width: (transformColumn.count + threadsPerThreadgroup.width - 1) / threadsPerThreadgroup.width,
            height: 1,
            depth: 1
          )
          encoder.setComputePipelineState(pipeline)
          encoder.setBuffer(transformColumn.metalBuffer, offset: 0, index: 0)
          encoder.setBuffer(velocityColumn.metalBuffer, offset: 0, index: 1)
          encoder.setBytes(&frameDelta, length: MemoryLayout<Float>.stride, index: 2)
          encoder.setBytes(&componentCount, length: MemoryLayout<UInt32>.stride, index: 3)
          encoder.setBytes(&stepsThisDispatch, length: MemoryLayout<UInt32>.stride, index: 4)
          encoder.setBytes(&heavyIterations, length: MemoryLayout<UInt32>.stride, index: 5)
          encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
          encoder.endEncoding()
          commandBuffer.commit()
          commandBuffer.waitUntilCompleted()
          transformColumn.markWholeColumnChanged(tick: gpuStore.currentTick)
        }
        gpuStore.advanceFrame()
        remainingFrames -= Int(stepsThisDispatch)
      }
      let gpuElapsed = Date().timeIntervalSince(gpuStart)

      print("")
      print("Lattice demo (USD population -> GPU)")
      print("Entities populated:          \(gpuStore.entityCount)")
      print("Frames:                      \(frames)")
      print("USD -> store populate:       \(String(format: "%.5f", gpuPopulateElapsed * 1000))ms")
      print("Compute per-frame avg:       \(String(format: "%.5f", gpuElapsed / Double(frames) * 1000))ms")
      print("GPU speedup vs serial:       \(String(format: "%.2f", serialElapsed / gpuElapsed))x")
      print("GPU speedup vs parallel:     \(String(format: "%.2f", parallelElapsed / gpuElapsed))x")
      print("Device:                      \(device.name)")

      if let prim0 = gpuPaths.entity(for: "/prim0"), let sample = gpuStore.get(Transform.self, for: prim0)
      {
        printTransform("/prim0.Transform after \(frames) GPU frames", sample)
      }
    }
    catch
    {
      print("")
      print("Lattice demo (USD population -> GPU)")
      print("Metal unavailable: \(error)")
    }
  #endif
}

// MARK: - Memory-factor benchmark

/// If a USD scene costs `n` bytes resident on its own, what's the memory factor
/// `k` once Lattice is "turned on" - populated the way Fabric would, by
/// prefetching a bounded working set (see ``isPrefetchedAttribute(_:)``) rather
/// than mirroring every attribute of every prim? Reports
/// `k = (n + Lattice) / n`. Prims that carry none of the prefetched attributes
/// never enter the store, so `entities` can be well below the prim count -
/// exactly the selective population Fabric does, not the whole-stage worst case.
///
/// Runs first, before the CPU/GPU demos allocate, so the process baseline it
/// subtracts is clean. USD's runtime is warmed on a throwaway stage beforehand
/// so its fixed schema/plugin cost lands below the baseline and doesn't inflate
/// the scene's marginal footprint. Point it at a real scene (e.g. ALab) with
/// `--usd <path>` or `LATTICE_USD_SCENE`, with neither it loads the same
/// synthetic stage the USD benchmark authors, so the demo still runs standalone.
func runMemoryFactorDemo()
{
  let scenePath = usdScenePathFromArguments()

  // warm USD's runtime (schema registry, plugins, value-type machinery) on a
  // tiny throwaway stage so that fixed, scene-independent cost sinks below the
  // baseline - otherwise it would be charged to the first real scene we load.
  do
  {
    let warmup = makeUSDStage(primCount: 1)
    _ = USDStageSource(stage: warmup).primPaths()
  }

  print("")
  print("Lattice demo (memory factor)")

  // The process's resident floor before any scene is loaded.
  let baseline = currentMemoryFootprint()

  let stage: UsdStage
  if let scenePath
  {
    print("Scene:                       \(scenePath)")
    stage = Usd.Stage.open(scenePath)
  }
  else
  {
    print("Scene:                       synthetic (\(usdEntityCount) prims)")
    stage = makeUSDStage(primCount: usdEntityCount)
  }
  let source = USDStageSource(stage: stage)

  // warm USD value resolution for exactly the prefetched working set - the
  // same attributes Lattice will mirror below - so the footprint we attribute
  // to the scene already holds those resolved values. otherwise USD would
  // lazily fault them in while Lattice mirrors and that cost would be
  // misattributed to Lattice, overstating the factor. warming attributes we
  // don't mirror would instead inflate the scene baseline, so we warm the
  // working set and nothing more.
  let primPaths = source.primPaths()
  for path in primPaths
  {
    for name in source.attributeNames(at: path) where isPrefetchedAttribute(name)
    {
      _ = source.attributeValue(at: path, attribute: name)
    }
  }
  let sceneFootprint = currentMemoryFootprint()

  // turn on Lattice the way Fabric populates: prefetch the working set, so a
  // prim enters only because one of those attributes was touched, and only
  // those attributes are mirrored - not every attribute of every prim.
  let store = LatticeStore()
  let prefetched = prefetchWorkingSet(into: store, source: source)
  let latticeFootprint = currentMemoryFootprint()

  let sceneCost = sceneFootprint >= baseline ? sceneFootprint - baseline : 0
  let latticeCost = latticeFootprint >= sceneFootprint ? latticeFootprint - sceneFootprint : 0
  let entities = store.entityCount

  print("Prims / prefetched entities: \(primPaths.count) / \(entities)")
  if entities > 0
  {
    let perPrim = Double(prefetched.mirrored) / Double(entities)
    print("Attributes mirrored:         \(prefetched.mirrored) (\(String(format: "%.1f", perPrim))/entity)")
  }
  let totalArrays = prefetched.uniqueArrays + prefetched.sharedArrays
  if totalArrays > 0
  {
    let sharedPercent = Double(prefetched.sharedArrays) / Double(totalArrays) * 100
    print("Array payloads:              \(totalArrays) (\(prefetched.uniqueArrays) unique, \(prefetched.sharedArrays) binned = \(String(format: "%.0f", sharedPercent))% shared)")
  }
  print("Scene resident (n):          \(formatBytes(sceneCost))")
  print("With Lattice on (kN):        \(formatBytes(sceneCost + latticeCost))")
  print("Lattice added:               \(formatBytes(latticeCost))")
  if entities > 0
  {
    let perEntity = Double(latticeCost) / Double(entities)
    print("Lattice per entity:          \(String(format: "%.1f", perEntity)) bytes")
  }
  if sceneCost > 0
  {
    let k = Double(sceneCost + latticeCost) / Double(sceneCost)
    print("Memory factor (k):           \(String(format: "%.2f", k))x")
  }
  else
  {
    print("Memory factor (k):           n/a")
  }
}

runUSDPluginRegistration()
runMemoryFactorDemo()

let cpuTimings = runCPUDemo()
#if canImport(Metal)
  runGPUDemo(cpuTimings: cpuTimings)
#else
  print("")
  print("Lattice demo (GPU)")
  print("Metal unavailable: this platform cannot import Metal")
#endif

runUSDDemo()
