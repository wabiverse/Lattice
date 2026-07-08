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

/// A single mirrored USD value is a Lattice component in its own right, so it
/// can be stored one-per-row in a dense, runtime-named column (see
/// ``LatticeStore/setDynamic(_:forKey:on:)``) rather than boxed in a per-entity
/// array. This is what lets a whole stage be mirrored with the real
/// column-per-attribute layout.
extension LatticeUSDValue: LatticeComponent {}

/// A concrete ``USDStageSourceRepresentable`` backed by a real,
/// composed `UsdStage` from `wabiverse/swift-usd` (`OpenUSDKit`).
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
public final class USDStageSource: USDStageSourceRepresentable
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
    guard prim.isValid else { return nil }

    guard let attribute = prim.attribute(named: name)
    else { return nil }

    return Self.latticeValue(of: attribute)
  }

  /// The names of every attribute authored on the prim at `path`, in the
  /// prim's own attribute order, without resolving any values. Empty when the
  /// prim doesn't exist.
  ///
  /// Listing attribute names is metadata-only - it does not fault in USD's
  /// resolved values the way `Get` does - so it's cheap enough to drive a
  /// prefetch that picks a bounded working set before paying to read anything.
  /// This is what lets population mirror only the attributes a query/prefetch
  /// asks for (see ``USDPopulationSync/prefetch(where:)``), the way a prim only
  /// enters Fabric because something touched specific attributes on it, rather
  /// than eagerly copying every attribute of every prim.
  public func attributeNames(at path: String) -> [String]
  {
    let prim = stage.getPrim(at: path)
    guard prim.isValid else { return [] }

    return prim.attributes.map { $0.GetPath().name }
  }

  /// Maps a single USD attribute's resolved value at the default time to the
  /// closest ``LatticeUSDValue``, or `nil` when it has no value or its type
  /// isn't one Lattice mirrors. `Get` requires an exact type match - USD does
  /// not silently convert `float` to `double` - so each branch reads into the
  /// matching C++ value type before converting.
  ///
  /// Grouping rule: a *role* (`point3f`, `normal3f`, `color3f`, `texCoord3f`,
  /// ...) changes only how a value is interpreted, never how it's stored, so
  /// same-precision roles share one branch. A *precision* suffix (`h`/`f`/`d`)
  /// changes the C++ storage type (`GfVec3h`/`GfVec3f`/`GfVec3d`), so it
  /// must never share a branch - `Get` into the wrong precision fails.
  /// Half-precision types (`half`, `half2[]`, `point3h[]`, ...) are
  /// `GfHalf`-backed and not currently read; add `VtHalfArray`-family branches
  /// if a scene needs them.
  private static func latticeValue(of attribute: Usd.Attribute) -> LatticeUSDValue?
  {
    guard attribute.HasValue() else { return nil }

    let time = UsdTimeCode.Default()
    let typeName = attribute.typeName.GetAsToken().string

    switch typeName
    {
      // MARK: scalars

      case "double":
        var value = 0.0
        guard attribute.Get(&value, time) else { return nil }
        return .double(value)

      case "float":
        var value: Float = 0
        guard attribute.Get(&value, time) else { return nil }
        return .double(Double(value))

      case "int":
        var value: Int32 = 0
        guard attribute.Get(&value, time) else { return nil }
        return .int(Int64(value))

      case "int64":
        var value: Int64 = 0
        guard attribute.Get(&value, time) else { return nil }
        return .int(value)

      case "uint":
        var value: UInt32 = 0
        guard attribute.Get(&value, time) else { return nil }
        return .int(Int64(value))

      case "uint64":
        var value: UInt64 = 0
        guard attribute.Get(&value, time) else { return nil }
        return .int(Int64(bitPattern: value))

      case "bool":
        var value = false
        guard attribute.Get(&value, time) else { return nil }
        return .bool(value)

      case "string":
        var value = std.string()
        guard attribute.Get(&value, time) else { return nil }
        return .string(String(value))

      case "token":
        var value = Tf.Token()
        guard attribute.Get(&value, time) else { return nil }
        return .string(value.string)

      // `asset` holds an SdfAssetPath, not a token; mirror its authored path.
      case "asset":
        var value = Sdf.AssetPath()
        guard attribute.Get(&value, time) else { return nil }
        return .string(String(value.GetAssetPath()))

      case "float2", "texCoord2f":
        var value = GfVec2f()
        guard attribute.Get(&value, time) else { return nil }
        let v = value.simd
        return .float2(v.x, v.y)
      
      case "float4", "color4f":
        var value = Pixar.GfVec4f()
        guard attribute.Get(&value, time) else { return nil }
        return .float4(value[0], value[1], value[2], value[3])
      
      case "matrix4d":
        var value = GfMatrix4d()
        guard attribute.Get(&value, time) else { return nil }
        let v = value.simd
        return .double16(v)

      case let type where Self.float3Types.contains(type):
        var value = GfVec3f()
        guard attribute.Get(&value, time) else { return nil }
        let v = value.simd
        return .float3(v.x, v.y, v.z)

      case let type where Self.double3Types.contains(type):
        var value = GfVec3d()
        guard attribute.Get(&value, time) else { return nil }
        let v = value.simd
        return .float3(Float(v.x), Float(v.y), Float(v.z))

      // MARK: arrays (the bulk of a real asset)
      //
      // Every layout-compatible case is a zero-copy view (`view(_:base:count:as:)`)
      // over the VtArray's own buffer - mirroring costs a handle, not a payload.
      // Only strings (un-viewable across the C++ boundary) and double2 (a
      // narrowing conversion) still copy.

      case "float4[]", "color4f[]":
        var array = Pixar.VtVec4fArray()
        guard attribute.Get(&array, time) else { return nil }
        return .float4Array(Self.view(array, base: Overlay.cdata(array), count: Int(array.size()), as: LatticeFloat4.self))

      case "float[]":
        var array = Pixar.VtFloatArray()
        guard attribute.Get(&array, time) else { return nil }
        return .floatArray(Self.view(array, base: Overlay.cdata(array), count: Int(array.size()), as: Float.self))

      case "double[]":
        var array = Pixar.VtDoubleArray()
        guard attribute.Get(&array, time) else { return nil }
        return .doubleArray(Self.view(array, base: Overlay.cdata(array), count: Int(array.size()), as: Double.self))

      case "int[]":
        var array = Pixar.VtIntArray()
        guard attribute.Get(&array, time) else { return nil }
        return .intArray(Self.view(array, base: Overlay.cdata(array), count: Int(array.size()), as: Int32.self))

      // Unsigned 32-bit is viewed by bit pattern - documented on `.intArray`.
      case "uint[]":
        var array = Pixar.VtUIntArray()
        guard attribute.Get(&array, time) else { return nil }
        return .intArray(Self.view(array, base: Overlay.cdata(array), count: Int(array.size()), as: Int32.self))

      case "int64[]":
        var array = Pixar.VtInt64Array()
        guard attribute.Get(&array, time) else { return nil }
        return .int64Array(Self.view(array, base: Overlay.cdata(array), count: Int(array.size()), as: Int64.self))

      case "uint64[]":
        var array = Pixar.VtUInt64Array()
        guard attribute.Get(&array, time) else { return nil }
        return .int64Array(Self.view(array, base: Overlay.cdata(array), count: Int(array.size()), as: Int64.self))

      case "bool[]":
        var array = Pixar.VtBoolArray()
        guard attribute.Get(&array, time) else { return nil }
        return .boolArray(Self.view(array, base: Overlay.cdata(array), count: Int(array.size()), as: Bool.self))

      case "token[]":
        var array = Pixar.VtTokenArray()
        guard attribute.Get(&array, time) else { return nil }
        var arrayValue: [String] = []
        arrayValue.reserveCapacity(Int(array.size()))
        for i in 0..<Int(array.size()) { arrayValue.append(array[i].string) }
        return .stringArray(arrayValue)

      case "string[]":
        var array = Pixar.VtStringArray()
        guard attribute.Get(&array, time) else { return nil }
        var arrayValue: [String] = []
        arrayValue.reserveCapacity(Int(array.size()))
        for i in 0..<Int(array.size()) { arrayValue.append(String(array[i])) }
        return .stringArray(arrayValue)

      case let type where Self.float2ArrayTypes.contains(type):
        var array = Pixar.VtVec2fArray()
        guard attribute.Get(&array, time) else { return nil }
        return .float2Array(Self.view(array, base: Overlay.cdata(array), count: Int(array.size()), as: LatticeFloat2.self))

      // GfVec2d-backed; narrowed to Float on the way in (the same way the
      // scalar double3 case narrows to .float3), so this is a converting copy
      // rather than a view - the element widths differ.
      case let type where Self.double2ArrayTypes.contains(type):
        var array = Pixar.VtVec2dArray()
        guard attribute.Get(&array, time) else { return nil }
        var arrayValue: [LatticeFloat2] = []
        arrayValue.reserveCapacity(Int(array.size()))
        for i in 0..<Int(array.size())
        {
          let v = array[i].simd
          arrayValue.append(LatticeFloat2(Float(v.x), Float(v.y)))
        }
        return .float2Array(LatticeUSDArray(copying: arrayValue))

      case let type where Self.float3ArrayTypes.contains(type):
        var array = Pixar.VtVec3fArray()
        guard attribute.Get(&array, time) else { return nil }
        return .float3Array(Self.view(array, base: Overlay.cdata(array), count: Int(array.size()), as: LatticeFloat3.self))

      case let type where Self.double3ArrayTypes.contains(type):
        var array = Pixar.VtVec3dArray()
        guard attribute.Get(&array, time) else { return nil }
        return .double3Array(Self.view(array, base: Overlay.cdata(array), count: Int(array.size()), as: LatticeDouble3.self))

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
    
    guard let attribute = prim.attribute(named: name)
    else { return false }
    
    let time = UsdTimeCode.Default()
    switch value
    {
      case let .double(d):
        return attribute.set(d)
      case let .bool(b):
        return attribute.set(b)
      case let .string(s):
        return attribute.set(s)
      case let .float2(x, y):
        return attribute.Set(GfVec2f(SIMD2<Float>(x, y)), time)
      case let .float3(x, y, z):
        return attribute.set(GfVec3f(SIMD3<Float>(x, y, z)))
      default:
        print("not yet implemented: not authoring \(value) back to USD stage")
        return false
    }
  }

  // MARK: - Zero-copy views

  /// Boxes a C++ value - a `VtArray` handle - behind a Swift class reference,
  /// so a ``LatticeUSDArray`` can keep it (and therefore the refcounted buffer
  /// it shares) alive for as long as the view exists.
  private final class Handle<A>
  {
    let value: A

    init(_ value: A)
    {
      self.value = value
    }
  }

  /// Wraps a `VtArray`'s buffer as a zero-copy ``LatticeUSDArray`` whose
  /// `Element` must be layout-identical to the array's C++ element type
  /// (that's what the packed `LatticeFloat3`-family types are for).
  ///
  /// The pointer must come from `Overlay.cdata(_:)` - the *const* accessor.
  /// The non-const `data()` detaches copy-on-write, which would deep-copy the
  /// shared buffer this exists to avoid. Boxing the handle bumps the buffer's
  /// refcount, so the view stays valid independent of the stage's lifetime.
  private static func view<A, CxxElement, Element>(
    _ array: A,
    base: UnsafePointer<CxxElement>?,
    count: Int,
    as _: Element.Type
  ) -> LatticeUSDArray<Element>
  {
    guard let base, count > 0 else { return LatticeUSDArray(copying: []) }
    let typed = UnsafeRawPointer(base).assumingMemoryBound(to: Element.self)
    return LatticeUSDArray(owner: Handle(array), view: UnsafeBufferPointer(start: typed, count: count))
  }

  // MARK: - Roled type-name groups
  //
  // USD's roled types (point/normal/vector/color/texCoord) alias an underlying
  // value type - the role changes interpretation, never storage - so every
  // member of a group below shares the exact C++ type its branch reads. The
  // precision suffix is what selects storage (`f` -> GfVec*f, `d` -> GfVec*d,
  // `h` -> GfVec*h), so half- and double-precision names must never appear in
  // a float group: `Get` is exact-typed and would fail for every one of them.
  // Note there are no 2-component point/normal/vector/color roles in USD; the
  // only roled 2-vectors are texCoord2{f,d,h}.

  /// `GfVec3f`-backed: `float3` and its float-precision roles.
  private static let float3Types: Set<String> = [
    "float3", "point3f", "normal3f", "vector3f", "color3f", "texCoord3f",
  ]

  /// `GfVec3d`-backed: `double3` and its double-precision roles.
  private static let double3Types: Set<String> = [
    "double3", "point3d", "normal3d", "vector3d", "color3d", "texCoord3d",
  ]

  /// `VtVec2fArray`-backed: `float2[]` and its one float-precision role.
  private static let float2ArrayTypes: Set<String> = [
    "float2[]", "texCoord2f[]",
  ]

  /// `VtVec2dArray`-backed: `double2[]` and its one double-precision role.
  private static let double2ArrayTypes: Set<String> = [
    "double2[]", "texCoord2d[]",
  ]

  /// `VtVec3fArray`-backed: `float3[]` and its float-precision roles.
  private static let float3ArrayTypes: Set<String> = [
    "float3[]", "point3f[]", "normal3f[]", "vector3f[]", "color3f[]", "texCoord3f[]",
  ]

  /// `VtVec3dArray`-backed: `double3[]` and its double-precision roles.
  private static let double3ArrayTypes: Set<String> = [
    "double3[]", "point3d[]", "normal3d[]", "vector3d[]", "color3d[]", "texCoord3d[]",
  ]
}
