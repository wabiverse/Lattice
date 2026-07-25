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
import OpenUSDKit
import lattice

#if canImport(Metal)
  import LatticeMetal
  import Metal
#endif

/// The aggregating form of the scene: N individually addressable `Cube` prims
/// under ``cellsPath``, drawn through one co-authored `PointInstancer`.
///
/// The stage carries real, authorable, pickable cube prims, one per cell, individual `displayColor`,
/// exactly like the per-prim path. But it also carries the same `UsdGeomPointInstancer` that the
/// instancer path uses, and ``LatticeInstancerSceneIndex`` is registered with a suppress
/// prefix that clears the cells type before they reach the renderer. Storm therefore draws the whole
/// field as one instancer (one dirtied prim per frame, instancer speed) while the cells stay present in
/// the scene for identity and authoring.
///
/// Cells and instances are built from the same shuffled list, so cell `i` is instance `i`, the mapping
/// a selection layer would use to turn an `(instancer, instanceIndex)` hit back into a cell path.
public enum LatticeAggregateSceneBuilder
{
  /// Root of the addressable cells. Handed to the scene index as the suppress
  /// prefix, so everything under it is hidden from the renderer.
  public static let cellsPath = "/World/Cells"

  /// The cell prim path for an instancer instance index.
  ///
  /// Cells are authored in instance order, so this is the whole selection map. A
  /// pick returns `(instancerPath, instanceIndex)`, feeding the index
  /// here gives the addressable prim behind that instance. The inverse is the
  /// trailing integer of the path.
  public static func cellPath(forInstance index: Int) -> String
  {
    "\(cellsPath)/Cell_\(index)"
  }

  static func makeStage(count: Int) -> (stage: UsdStage, motions: [RippleMotion], halfExtent: Double)
  {
    let side = LatticeSceneBuilder.gridSide(for: count)
    let spacing = 2.2
    let half = Double(side - 1) * spacing * 0.5
    let paletteCount = LatticeInstancerSceneBuilder.paletteCount

    var motions: [RippleMotion] = []
    motions.reserveCapacity(count)

    var positions = ""
    positions.reserveCapacity(count * 28)
    var protoIndices = ""
    protoIndices.reserveCapacity(count * 2)
    var cells = ""
    cells.reserveCapacity(count * 180)

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

    // same seed as the instancer builder, so a prefix of the field stays a
    // spatially uniform sample and cell i lines up with instance i.
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

      // the addressable cell. its rest pose and color match the instance it
      // stands for. it is never drawn, the scene index clears its type, so
      // authoring a cube here costs nothing at draw time.
      let color = LatticeSceneBuilder.colorLiteral(
        LatticeSceneBuilder.rainbow(Double(item.proto) / Double(paletteCount - 1))
      )
      cells += "    def Cube \"Cell_\(i)\"\n    {\n"
      cells += "        double size = 1\n"
      cells += "        matrix4d xformOp:transform = ( (0.42, 0, 0, 0), (0, 0.42, 0, 0), (0, 0, 0.42, 0), (\(item.x), \(item.y), \(item.z), 1) )\n"
      cells += "        uniform token[] xformOpOrder = [\"xformOp:transform\"]\n"
      cells += "        color3f[] primvars:displayColor = [(\(color))]\n"
      cells += "    }\n"
    }

    let bound = half * 1.15 + 4.0

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
    usda += "}\n"
    usda += "def Scope \"Cells\"\n{\n"
    usda += cells
    usda += "}\n"
    usda += "}\n"

    let filename = "lattice-hydra-aggregate-\(UUID().uuidString).usda"
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

    let source = LatticeInstanceSource(
      store: store,
      instancerPath: SdfPath(LatticeInstancerSceneBuilder.instancerPath)
    )

    for motion in motions
    {
      let entity = store.spawn()
      store.set(motion, on: entity)
      store.set(LatticeInstancerSceneBuilder.restInstance(motion), on: entity)
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
}
