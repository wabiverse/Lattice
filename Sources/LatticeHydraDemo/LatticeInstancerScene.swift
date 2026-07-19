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
import OpenUSDKit
import lattice

#if canImport(Metal)
  import LatticeMetal
  import Metal

  extension InstanceXform: LatticeGPUComponent {}
#endif

/// The instancer form of the scene: one `UsdGeomPointInstancer` carrying every
/// cube as an instance, instead of one prim per cube.
///
/// Same store, same kernel shape, same frame contract - the only thing that
/// changes is how many prims Hydra has to be told about. That is the entire
/// difference between ~1 fps and real time at a hundred thousand cubes, and
/// it is a property of the *scene*, not of Lattice.
public struct LatticeInstancerScene
{
  public let stage: UsdStage
  public let store: LatticeStore
  public let source: LatticeInstanceSource
  public let instanceCount: Int
  /// Half-extent of the authored grid, in world units.
  /// Kernels normalize by it so their look does not
  /// follow '--count'.
  public let halfExtent: Double
  public let drivePath: LatticeDrivePath

  #if canImport(Metal)
    public let device: (any MTLDevice)?
  #endif
}

/// A small deterministic generator, so the shuffled instance order and
/// what any given slider position shows - is identical on every run.
struct SeededGenerator: RandomNumberGenerator
{
  private var state: UInt64

  init(seed: UInt64)
  {
    state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
  }

  mutating func next() -> UInt64
  {
    // splitmix64
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

extension Double
{
  /// Cube root, for turning a fraction of the instances into
  /// the linear scale that preserves their density.
  var cbrt: Double { Foundation.cbrt(self) }
}

public enum LatticeInstancerSceneBuilder
{
  public static let instancerPath = "/World/Instancer"

  /// How many differently-coloured prototypes the rainbow is quantised into.
  ///
  /// Colour has to come from the prototype here, because every instance of one
  /// prototype shares its `displayColor` - a single prototype would give a
  /// hundred thousand identically-coloured cubes. Indexing a palette through
  /// the already-authored `protoIndices` costs the layer nothing, where an
  /// instance-rate `primvars:displayColor` would add a third hundred-thousand
  /// element array.
  ///
  /// The cost is one draw per prototype rather than one for the whole field,
  /// which at sixteen is irrelevant next to the hundred thousand draws the
  /// per-prim path would need.
  public static let paletteCount = 16

  /// Authors a point instancer with `count` instances.
  ///
  /// Only `positions`, `protoIndices` and `extent` are authored. Scales and
  /// orientations are left unauthored on purpose: the scene index supplies all
  /// three instance primvars every frame anyway, and leaving them out keeps the
  /// text layer to one array instead of three.
  ///
  /// `extent` *is* authored, because the render engine frames its camera from
  /// the stage's world bound - and computing that bound for an instancer with
  /// no extent hint means expanding every instance.
  static func makeStage(count: Int) -> (stage: UsdStage, motions: [RippleMotion], halfExtent: Double)
  {
    let side = LatticeSceneBuilder.gridSide(for: count)
    let spacing = 2.2
    let half = Double(side - 1) * spacing * 0.5

    var motions: [RippleMotion] = []
    motions.reserveCapacity(count)

    var positions = ""
    positions.reserveCapacity(count * 28)
    var protoIndices = ""
    protoIndices.reserveCapacity(count * 2)

    // built as tuples first so the whole set can be shuffled before anything is written out.
    var built: [(x: Double, y: Double, z: Double, motion: RippleMotion, proto: Int)] = []
    built.reserveCapacity(count)

    var index = 0
    outer: for ix in 0 ..< side
    {
      for iy in 0 ..< side
      {
        for iz in 0 ..< side
        {
          if index >= count { break outer }

          let x = Double(ix) * spacing - half
          let y = Double(iy) * spacing - half
          let z = Double(iz) * spacing - half
          let radius = (x * x + y * y + z * z).squareRoot()
          let jitter = Double((index &* 2654435761) % 1000) / 1000.0

          // same radius-driven hue as the per-prim scene, quantised onto the
          // prototype palette - concentric rainbow shells for the ripple to
          // travel through.
          let hue = (radius / (half * 1.7321 + 0.0001)).clamped01

          built.append((
            x: x, y: y, z: z,
            motion: RippleMotion(
              homeX: Float(x), homeY: Float(y), homeZ: Float(z),
              radius: Float(radius),
              phase: Float(jitter * 6.283185307179586),
              spin: Float(0.6 + jitter * 1.8),
              scale: 0.42
            ),
            proto: min(paletteCount - 1, Int(hue * Double(paletteCount)))
          ))

          index += 1
        }
      }
    }

    // shuffle once, so that a subset of the instances
    // is a spatially uniform sample of the field rather
    // than a slab of it.
    var rng = SeededGenerator(seed: 0x5EED_1A77_1CE0)
    built.shuffle(using: &rng)

    for (i, item) in built.enumerated()
    {
      motions.append(item.motion)
      if i > 0
      {
        positions += ", "
        protoIndices += ", "
      }
      positions += "(\(item.x), \(item.y), \(item.z))"
      protoIndices += "\(item.proto)"
    }

    // padded so the ripple's lift and swell stay inside the authored bound.
    let bound = half * 1.15 + 4.0

    // the relationship's target order *is* the prototype index space:
    // protoIndices[i] == k selects the k-th target listed here.
    var prototypeTargets: [String] = []
    var prototypeDefs = ""
    for k in 0 ..< paletteCount
    {
      let color = LatticeSceneBuilder.colorLiteral(
        LatticeSceneBuilder.rainbow(Double(k) / Double(paletteCount - 1))
      )
      prototypeTargets.append("</World/Instancer/Prototypes/Cube\(k)>")
      prototypeDefs += "        def Cube \"Cube\(k)\"\n        {\n"
      prototypeDefs += "            double size = 1\n"
      prototypeDefs += "            color3f[] primvars:displayColor = [(\(color))]\n"
      prototypeDefs += "        }\n"
    }

    var usda = "#usda 1.0\n(\n    upAxis = \"Y\"\n)\n\ndef Xform \"World\"\n{\n"
    usda += "def PointInstancer \"Instancer\"\n{\n"
    usda += "    point3f[] positions = [\(positions)]\n"
    usda += "    int[] protoIndices = [\(protoIndices)]\n"
    usda += "    float3[] extent = [(\(-bound), \(-bound), \(-bound)), (\(bound), \(bound), \(bound))]\n"
    usda += "    rel prototypes = [\(prototypeTargets.joined(separator: ", "))]\n\n"
    usda += "    def Scope \"Prototypes\"\n    {\n"
    usda += prototypeDefs
    usda += "    }\n"
    usda += "}\n}\n"

    let filename = "lattice-hydra-instancer-\(UUID().uuidString).usda"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    try? usda.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    let stage = UsdStage.open(url.path)
    AppUtils.addDomeLight(to: stage)
    return (stage, motions, half)
  }

  public static func build(instanceCount: Int, useGPU: Bool = true) -> LatticeInstancerScene
  {
    let (stage, motions, halfExtent) = makeStage(count: instanceCount)

    let store = LatticeStore()
    var drivePath: LatticeDrivePath = .cpu

    #if canImport(Metal)
      let device: (any MTLDevice)? = useGPU ? MTLCreateSystemDefaultDevice() : nil
      if let device
      {
        // the c++ side walks this column as a flat float array at a fixed
        // stride, so a layout change here would silently shear the field.
        precondition(MemoryLayout<InstanceXform>.stride == 10 * MemoryLayout<Float>.stride,
                     "InstanceXform must stay 10 packed floats - the scene index strides it as such")

        store.register(InstanceXform.self)
        {
          MetalBackedColumn<InstanceXform>(device: device, initialCapacity: max(motions.count, 1))
        }
        store.register(RippleMotion.self)
        {
          MetalBackedColumn<RippleMotion>(device: device, initialCapacity: max(motions.count, 1))
        }
        drivePath = .gpu
      }
    #endif

    if drivePath == .cpu
    {
      store.register(InstanceXform.self)
      store.register(RippleMotion.self)
    }

    // no path table here: there is one prim, and it is named directly. The
    // per-instance identity that `LatticePathTable` provides on the per-prim
    // path is carried by the row index instead - which is exactly what makes
    // the instancer path cheap.
    let source = LatticeInstanceSource(store: store, instancerPath: SdfPath(instancerPath))

    for motion in motions
    {
      let entity = store.spawn()
      store.set(motion, on: entity)
      store.set(restInstance(motion), on: entity)
    }

    #if canImport(Metal)
      return LatticeInstancerScene(
        stage: stage,
        store: store,
        source: source,
        instanceCount: motions.count,
        halfExtent: halfExtent,
        drivePath: drivePath,
        device: device
      )
    #else
      return LatticeInstancerScene(
        stage: stage,
        store: store,
        source: source,
        instanceCount: motions.count,
        halfExtent: halfExtent,
        drivePath: drivePath
      )
    #endif
  }

  /// The t = 0 instance, matching the positions authored into the layer.
  static func restInstance(_ m: RippleMotion) -> InstanceXform
  {
    InstanceXform(
      tx: m.homeX, ty: m.homeY, tz: m.homeZ,
      sx: m.scale, sy: m.scale, sz: m.scale,
      rx: 0, ry: 0, rz: 0, rw: 1
    )
  }
}
