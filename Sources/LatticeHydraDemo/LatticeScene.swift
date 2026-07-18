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

#if canImport(Metal)
  import LatticeMetal
  import Metal
#endif

/// Per-cube animation state for the ripple.
///
/// Seven `Float`s, laid out as plain scalars rather than a `SIMD3` so the Swift
/// and Metal structs agree byte for byte - `float3` carries 16-byte alignment
/// in MSL and would silently disagree with Swift's 12-byte `SIMD3<Float>`
/// packing at the buffer boundary.
///
/// Everything the kernel needs to pose a cube at time `t` lives here, so the
/// per-frame computation is a pure function of `(motion, t)`: no reads back
/// into the store, no cross-row dependencies, no dependence on the previous
/// frame. That is what makes it a one-line compute dispatch.
public struct RippleMotion: LatticeComponent, Equatable, Sendable
{
  /// Rest position - the cube's slot in the grid.
  public var homeX: Float
  public var homeY: Float
  public var homeZ: Float
  /// Distance from the grid centre, precomputed so the kernel does not pay a
  /// `sqrt` per thread per frame.
  public var radius: Float
  /// Phase offset, so cubes in a shell do not move in lockstep.
  public var phase: Float
  /// Radians/second about Y.
  public var spin: Float
  /// Half-extent, folded into the matrix as a uniform scale.
  public var scale: Float

  public init(homeX: Float, homeY: Float, homeZ: Float,
              radius: Float, phase: Float, spin: Float, scale: Float)
  {
    self.homeX = homeX
    self.homeY = homeY
    self.homeZ = homeZ
    self.radius = radius
    self.phase = phase
    self.spin = spin
    self.scale = scale
  }
}

#if canImport(Metal)
  // Both columns live in `MTLBuffer`s. On unified memory that makes the bytes
  // the kernel writes the same bytes `getLiveXform(_:)` reads - the reason this
  // path has no upload and no readback.
  //
  // `XformGPU` is declared in `LatticeUSD` (the transform source has to be able
  // to read it) while `LatticeGPUComponent` is declared in `LatticeMetal`, and
  // `LatticeUSD` deliberately does not depend on `LatticeMetal`. This target is
  // the first place that sees both, so the conformance is necessarily
  // retroactive - marked as such rather than left to warn.
  extension XformGPU: LatticeGPUComponent {}
  extension RippleMotion: LatticeGPUComponent {}
#endif

/// Which path drives the transforms this run.
public enum LatticeDrivePath: String, Sendable
{
  /// Compute kernel writes `XformGPU` straight into unified memory.
  case gpu
  /// Parallel CPU pass over the `Xform` columns. Fallback when Metal is
  /// unavailable, and useful as an A/B on stage.
  case cpu
}

/// The stage, the store, and the live transform source, built together and
/// handed to the frame driver as one unit.
public struct LatticeScene
{
  public let stage: UsdStage
  public let store: LatticeStore
  public let paths: LatticePathTable
  public let source: LatticeXformSource
  /// Every animated prim path, built once at load.
  ///
  /// The ripple moves every cube every frame, so the frame's dirty set is
  /// always this whole array. Rebuilding it per frame - or discovering it by
  /// walking the store - would cost more than the dispatch itself, so it is
  /// materialised once and re-submitted through
  /// ``LatticeXformSource/markDirty(contentsOf:)``.
  public let animatedPaths: [SdfPath]
  public let cubeCount: Int
  public let drivePath: LatticeDrivePath

  #if canImport(Metal)
    /// The device the columns were allocated on, so the driver encodes against
    /// the same one rather than re-resolving a possibly different default.
    public let device: (any MTLDevice)?
  #endif
}

public enum LatticeSceneBuilder
{
  /// Grid extent that most nearly holds `count` cubes.
  static func gridSide(for count: Int) -> Int
  {
    max(1, Int(Foundation.cbrt(Double(count)).rounded(.up)))
  }

  /// Authors a `.usda` layer of `count` cubes and opens it in one shot.
  ///
  /// Authored as text and composed once rather than prim-by-prim on a live
  /// stage: USD recomposes on every live edit, so incremental authoring is
  /// orders of magnitude slower and would cap how many cubes the demo can
  /// afford. At 100k prims that is the difference between a couple of seconds
  /// and minutes.
  ///
  /// The authored `xformOp:transform` is the rest pose. Once the scene index is
  /// in the chain, Lattice's live matrix replaces it wholesale (`resetXformStack`), so
  /// this value only decides what the first frame looks like - and what you would see if you
  /// pulled the scene index back out.
  static func makeStage(count: Int) -> (stage: UsdStage, paths: [SdfPath], motions: [(String, RippleMotion)])
  {
    let side = gridSide(for: count)
    let spacing = 2.2
    let half = Double(side - 1) * spacing * 0.5

    var usda = "#usda 1.0\n(\n    upAxis = \"Y\"\n)\n\ndef Xform \"World\"\n{\n"
    usda.reserveCapacity(count * 320)

    var pathStrings: [String] = []
    pathStrings.reserveCapacity(count)
    var motions: [(String, RippleMotion)] = []
    motions.reserveCapacity(count)

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

          // deterministic per-cube jitter, so the field reads as organic
          // without a random source that would change from run to run.
          let jitter = Double((index &* 2654435761) % 1000) / 1000.0

          let name = "c\(index)"
          let path = "/World/\(name)"
          pathStrings.append(path)
          motions.append((path, RippleMotion(
            homeX: Float(x), homeY: Float(y), homeZ: Float(z),
            radius: Float(radius),
            phase: Float(jitter * 6.283185307179586),
            spin: Float(0.6 + jitter * 1.8),
            scale: 0.42
          )))

          // hue sweeps with radius so the ripple stays legible as it travels.
          let hue = (radius / (half * 1.7321 + 0.0001)).clamped01
          let color = colorLiteral(rainbow(hue))

          usda += "def Cube \"\(name)\"\n{\n"
          usda += "    double size = 1\n"
          usda += "    matrix4d xformOp:transform = ( (0.42, 0, 0, 0), (0, 0.42, 0, 0), (0, 0, 0.42, 0), (\(x), \(y), \(z), 1) )\n"
          usda += "    uniform token[] xformOpOrder = [\"xformOp:transform\"]\n"
          usda += "    color3f[] primvars:displayColor = [(\(color))]\n"
          usda += "}\n"

          index += 1
        }
      }
    }
    usda += "}\n"

    let filename = "lattice-hydra-demo-\(UUID().uuidString).usda"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    try? usda.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }
    
    let stage = UsdStage.open(url.path)
    
    let domeLight = UsdLux.DomeLight.define(stage, path: "/World/DefaultDomeLight")
    if let hdxResources = Bundle.hdx?.resourcePath {
      let tex = "\(hdxResources)/textures/StinsonBeach.hdr"
      if FileManager.default.fileExists(atPath: tex) {
        let hdrAsset = Sdf.AssetPath(tex)
        domeLight.createTextureFileAttr().set(hdrAsset)
      }
    }

    return (stage, pathStrings.map { SdfPath($0) }, motions)
  }

  /// Full-spectrum hue sweep `t` in `0...1` walks
  /// red -> yellow -> green -> cyan -> blue -> magenta
  /// and back toward red.
  static func colorLiteral(_ c: (Double, Double, Double)) -> String
  {
    String(format: "%.3f, %.3f, %.3f", c.0, c.1, c.2)
  }

  static func rainbow(_ t: Double, span: Double = 0.85) -> (Double, Double, Double)
  {
    let value = 0.92
    let sector = t.clamped01 * span * 6.0
    let index = min(5, Int(sector))
    let f = sector - Double(index)
    let rising = f * value
    let falling = (1.0 - f) * value

    switch index
    {
      case 0: return (value, rising, 0)
      case 1: return (falling, value, 0)
      case 2: return (0, value, rising)
      case 3: return (0, falling, value)
      case 4: return (rising, 0, value)
      default: return (value, 0, falling)
    }
  }

  /// Builds the stage, mirrors it into a ``LatticeStore``, and returns the
  /// pieces the frame driver needs.
  ///
  /// Population is direct rather than going through ``USDPopulationSync/prefetch(where:)``
  /// the demo already knows the exact component values it wants on every prim, so reading them back
  /// out of USD only to decode them again would measure USD's attribute resolution rather than Lattice's
  /// throughput.
  ///
  /// - Parameter useGPU: when true and a Metal device exists, both columns are
  ///   registered as `MetalBackedColumn`s **before** any entity is spawned.
  ///   Registration has to precede population: `set`/`spawn` register a
  ///   component the first time they see it, and a column that defaulted to
  ///   array storage would stay array-backed for the rest of the run.
  public static func build(cubeCount: Int, useGPU: Bool = true) -> LatticeScene
  {
    let (stage, sdfPaths, motions) = makeStage(count: cubeCount)

    let store = LatticeStore()
    var drivePath: LatticeDrivePath = .cpu

    #if canImport(Metal)
      let device: (any MTLDevice)? = useGPU ? MTLCreateSystemDefaultDevice() : nil
      if let device
      {
        store.register(XformGPU.self)
        {
          MetalBackedColumn<XformGPU>(device: device, initialCapacity: max(motions.count, 1))
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
      store.register(Xform.self)
      store.register(RippleMotion.self)
    }

    let paths = LatticePathTable(framePhase: store.framePhase)
    let source = LatticeXformSource(store: store, paths: paths)

    // bind one entity per cube and seed both columns. the lookup key
    // must be the SdfPath hash - that is what the scene index keys on
    // from c++.
    for (i, (pathString, motion)) in motions.enumerated()
    {
      let entity = store.spawn()
      paths.bind(entity, to: pathString, lookupKey: sdfPaths[i].GetHash())
      store.set(motion, on: entity)

      switch drivePath
      {
        case .gpu:
          store.set(XformGPU(matrix: restMatrixF(motion)), on: entity)
        case .cpu:
          store.set(Xform(matrix: restMatrix(motion)), on: entity)
      }
    }

    #if canImport(Metal)
      return LatticeScene(
        stage: stage,
        store: store,
        paths: paths,
        source: source,
        animatedPaths: sdfPaths,
        cubeCount: motions.count,
        drivePath: drivePath,
        device: device
      )
    #else
      return LatticeScene(
        stage: stage,
        store: store,
        paths: paths,
        source: source,
        animatedPaths: sdfPaths,
        cubeCount: motions.count,
        drivePath: drivePath
      )
    #endif
  }

  /// The t = 0 pose, matching the transform authored into the layer.
  static func restMatrix(_ m: RippleMotion) -> LatticeDouble4x4
  {
    LatticeDouble4x4(
      Double(m.scale), 0, 0, 0,
      0, Double(m.scale), 0, 0,
      0, 0, Double(m.scale), 0,
      Double(m.homeX), Double(m.homeY), Double(m.homeZ), 1
    )
  }

  static func restMatrixF(_ m: RippleMotion) -> LatticeFloat4x4
  {
    LatticeFloat4x4(
      m.scale, 0, 0, 0,
      0, m.scale, 0, 0,
      0, 0, m.scale, 0,
      m.homeX, m.homeY, m.homeZ, 1
    )
  }
}

extension Double
{
  var clamped01: Double { self < 0 ? 0 : (self > 1 ? 1 : self) }
}
