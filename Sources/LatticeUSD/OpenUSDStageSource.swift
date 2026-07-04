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

import CxxStdlib
import Lattice
import OpenUSDKit

/// A concrete ``USDStageSource`` backed by a real, composed `UsdStage` from
/// `wabiverse/swift-usd` (`OpenUSDKit`).
///
/// This is the piece that actually reads USD. It walks the composed stage for
/// prim paths and pulls resolved attribute values through OpenUSDKit's C++
/// interop, translating the small set of value types Lattice cares about into
/// ``LatticeUSDValue``. Everything above it - `USDPopulationSync`, the
/// `LatticeStore` - stays free of any USD or C++ knowledge; only this file
/// imports `OpenUSDKit`.
///
/// All access here goes through `getPrim(at:)` and attribute `Get`, both of
/// which USD guarantees are read-only and safe to call without mutating the
/// stage, so a populated store can be refreshed from the same stage repeatedly.
public final class OpenUSDStageSource: USDStageSource
{
  private let stage: UsdStage

  /// Wraps an already-opened stage. Use this when the caller owns stage
  /// lifetime (e.g. it also drives editing or rendering from the same stage).
  public init(stage: UsdStage)
  {
    self.stage = stage
  }

  /// Opens the composed stage rooted at `filePath` and wraps it. The layer
  /// must already exist; see `Usd.Stage.open(_:load:)`.
  public convenience init(openingStageAt filePath: String)
  {
    self.init(stage: Usd.Stage.open(filePath))
  }

  /// Every active, defined, non-abstract prim path on the composed stage, in
  /// depth-first traversal order - the same order `Usd.Stage.traverse()`
  /// yields.
  public func primPaths() -> [String]
  {
    stage.traverse().map { $0.getPath().getAsString() }
  }

  /// Reads the resolved value of attribute `name` on the prim at `path` at the
  /// default time, mapping USD's value type to the closest ``LatticeUSDValue``.
  ///
  /// Returns `nil` when the prim or attribute doesn't exist, the attribute has
  /// no authored or fallback value, or its type isn't one Lattice currently
  /// mirrors. `Get` requires an exact type match - USD does not silently
  /// convert `float` to `double` - so each branch reads into the matching C++
  /// value type before converting.
  public func attributeValue(at path: String, attribute name: String) -> LatticeUSDValue?
  {
    let prim = stage.getPrim(at: path)
    guard prim.IsValid() else { return nil }

    let attribute = prim.GetAttribute(Tf.Token(name))
    guard attribute.IsValid(), attribute.HasValue() else { return nil }

    let time = UsdTimeCode.Default()
    let typeName = attribute.typeName.GetAsToken().string

    switch typeName
    {
      case "double":
        var value = 0.0
        guard attribute.Get(&value, time) else { return nil }
        return .double(value)

      case "float":
        var value: Float = 0
        guard attribute.Get(&value, time) else { return nil }
        return .double(Double(value))

      case "bool":
        var value = false
        guard attribute.Get(&value, time) else { return nil }
        return .bool(value)

      case "string":
        var value = std.string()
        guard attribute.Get(&value, time) else { return nil }
        return .string(String(value))

      case "token", "asset":
        var value = Tf.Token()
        guard attribute.Get(&value, time) else { return nil }
        return .string(value.string)

      case let type where Self.isFloat3(type):
        var value = GfVec3f()
        guard attribute.Get(&value, time) else { return nil }
        let v = value.simd
        return .float3(v.x, v.y, v.z)

      case let type where Self.isDouble3(type):
        var value = GfVec3d()
        guard attribute.Get(&value, time) else { return nil }
        let v = value.simd
        return .float3(Float(v.x), Float(v.y), Float(v.z))

      default:
        return nil
    }
  }

  /// Writes `value` to attribute `name` on the prim at `path` at the default
  /// time, returning whether it landed. The attribute must already exist on
  /// the stage (this authors a value, it doesn't create the attribute) and the
  /// stage's edit target must be writable.
  ///
  /// This is the store->stage half of the loop: after a system computes new
  /// values in the runtime store, `USDPopulationSync.writeBackChanged` funnels
  /// the changed rows through here to author them back onto USD.
  public func setAttributeValue(_ value: LatticeUSDValue, at path: String, attribute name: String) -> Bool
  {
    let prim = stage.getPrim(at: path)
    guard prim.IsValid() else { return false }

    let attribute = prim.GetAttribute(Tf.Token(name))
    guard attribute.IsValid() else { return false }

    let time = UsdTimeCode.Default()
    switch value
    {
      case let .double(d):
        return attribute.Set(d, time)
      case let .bool(b):
        return attribute.Set(b, time)
      case let .string(s):
        return attribute.Set(std.string(s), time)
      case let .float3(x, y, z):
        return attribute.Set(GfVec3f(SIMD3<Float>(x, y, z)), time)
    }
  }

  /// Three-component `float`-backed USD types (`float3` and its roled
  /// variants), all stored as `GfVec3f`.
  private static func isFloat3(_ typeName: String) -> Bool
  {
    switch typeName
    {
      case "float3", "point3f", "normal3f", "vector3f", "color3f", "texCoord3f":
        true
      default:
        false
    }
  }

  /// Three-component `double`-backed USD types (`double3` and its roled
  /// variants), all stored as `GfVec3d`.
  private static func isDouble3(_ typeName: String) -> Bool
  {
    switch typeName
    {
      case "double3", "point3d", "normal3d", "vector3d", "color3d":
        true
      default:
        false
    }
  }
}
