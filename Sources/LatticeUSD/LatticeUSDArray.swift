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

// MARK: - Packed vector elements

/// Packed vector element types matching USD's `Gf` memory layout exactly.
///
/// These exist because Swift's SIMD types pad: `SIMD3<Float>` has a 16-byte
/// stride while `GfVec3f` is 12 tightly-packed bytes, so a zero-copy view of a
/// `VtVec3fArray` must use a 12-byte element or every read past index 0 lands
/// off the rails. They also carry 4/8-byte alignment (vs SIMD's 16), matching
/// what USD's allocations - including crate-file mmap regions - actually
/// guarantee.

/// Two packed `Float`s - the layout of `GfVec2f`.
public struct LatticeFloat2: Hashable, Sendable
{
  public var x: Float
  public var y: Float

  public init(_ x: Float, _ y: Float)
  {
    self.x = x
    self.y = y
  }
}

/// Three packed `Float`s - the layout of `GfVec3f` (12 bytes, not
/// `SIMD3<Float>`'s padded 16).
public struct LatticeFloat3: Hashable, Sendable
{
  public var x: Float
  public var y: Float
  public var z: Float

  public init(_ x: Float, _ y: Float, _ z: Float)
  {
    self.x = x
    self.y = y
    self.z = z
  }
}

/// Four packed `Float`s - the layout of `GfVec4f`.
public struct LatticeFloat4: Hashable, Sendable
{
  public var x: Float
  public var y: Float
  public var z: Float
  public var w: Float

  public init(_ x: Float, _ y: Float, _ z: Float, _ w: Float)
  {
    self.x = x
    self.y = y
    self.z = z
    self.w = w
  }
}

/// Three packed `Double`s - the layout of `GfVec3d` (24 bytes, not
/// `SIMD3<Double>`'s padded 32).
public struct LatticeDouble3: Hashable, Sendable
{
  public var x: Double
  public var y: Double
  public var z: Double

  public init(_ x: Double, _ y: Double, _ z: Double)
  {
    self.x = x
    self.y = y
    self.z = z
  }
}

/// Sixteen packed `Double`s in `GfMatrix4d`'s row-major layout (128
/// bytes). `simd_double4x4` is the same size, but stores columns in
/// column-major order, so direct reinterpretation would silently transpose
/// the matrix rather than fail on a size mismatch.
public struct LatticeDouble4x4: Hashable, Sendable
{
  public var m00: Double, m01: Double, m02: Double, m03: Double
  public var m10: Double, m11: Double, m12: Double, m13: Double
  public var m20: Double, m21: Double, m22: Double, m23: Double
  public var m30: Double, m31: Double, m32: Double, m33: Double

  public init(
    _ m00: Double, _ m01: Double, _ m02: Double, _ m03: Double,
    _ m10: Double, _ m11: Double, _ m12: Double, _ m13: Double,
    _ m20: Double, _ m21: Double, _ m22: Double, _ m23: Double,
    _ m30: Double, _ m31: Double, _ m32: Double, _ m33: Double)
  {
    self.m00 = m00; self.m01 = m01; self.m02 = m02; self.m03 = m03
    self.m10 = m10; self.m11 = m11; self.m12 = m12; self.m13 = m13
    self.m20 = m20; self.m21 = m21; self.m22 = m22; self.m23 = m23
    self.m30 = m30; self.m31 = m31; self.m32 = m32; self.m33 = m33
  }

  public static let identity = LatticeDouble4x4(
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1
  )
}

// MARK: - Zero-copy array view

/// An immutable, zero-copy view of a resolved USD array value.
///
/// This is what makes mirroring a scene's geometry (nearly) free: instead of
/// copying a `VtArray`'s contents into a Swift array, `USDStageSource` boxes
/// the `VtArray` *handle* as `owner` and views its buffer directly. `VtArray`
/// is refcounted copy-on-write, so the handle shares USD's storage rather than
/// duplicating it - and for crate (`.usdc`) layers, whose arrays point into the
/// file's mmap, the view references the same pages USD itself reads. The
/// handle keeps that storage alive on its own; the view stays valid even if
/// the stage is later dropped.
///
/// The view is deliberately read-only. The mirror never mutates USD's buffer
/// in place; a system that computes new values stores a *new*
/// ``LatticeUSDValue`` (e.g. built via ``init(copying:)``) and authors it back
/// through the write-back path.
///
/// Equality and hashing are by *content* (with a same-buffer fast path), the
/// same semantics a copied Swift array had - so prefetch binning, and tests
/// comparing against literals, behave identically regardless of which backing
/// a value carries.
public struct LatticeUSDArray<Element: Hashable>: @unchecked Sendable
{
  /// Whatever keeps `view`'s memory alive: a boxed `VtArray` handle for
  /// zero-copy views, or an ``OwnedBuffer`` for copied ones.
  private let owner: AnyObject
  private let view: UnsafeBufferPointer<Element>

  /// Wraps `view` without copying. `owner` must keep the viewed memory alive
  /// and unmutated for its own lifetime (a `VtArray` handle does both: it
  /// refcounts the buffer, and this side only ever reads it).
  public init(owner: AnyObject, view: UnsafeBufferPointer<Element>)
  {
    self.owner = owner
    self.view = view
  }

  /// Copies `elements` into storage this view owns. The escape hatch for
  /// values that don't originate in a `VtArray` - tests, hand-built fixtures,
  /// or computed results headed for write-back.
  public init(copying elements: [Element])
  {
    let buffer = OwnedBuffer<Element>(copying: elements)
    owner = buffer
    view = UnsafeBufferPointer(buffer.storage)
  }

  public var count: Int
  {
    view.count
  }

  public var isEmpty: Bool
  {
    view.isEmpty
  }

  public subscript(index: Int) -> Element
  {
    view[index]
  }

  /// The elements copied out into a standalone Swift array, for callers that
  /// need one; iterating the view directly avoids the copy.
  public var elements: [Element]
  {
    Array(view)
  }

  /// Direct access to the viewed buffer - e.g. to hand geometry straight to a
  /// GPU upload or a C API without an intermediate copy.
  public func withUnsafeBufferPointer<R>(_ body: (UnsafeBufferPointer<Element>) throws -> R) rethrows -> R
  {
    try body(view)
  }
}

extension LatticeUSDArray: Equatable, Hashable
{
  public static func == (lhs: Self, rhs: Self) -> Bool
  {
    guard lhs.view.count == rhs.view.count else { return false }
    // Same buffer (two views of one VtArray) short-circuits the compare.
    if lhs.view.baseAddress == rhs.view.baseAddress { return true }
    return lhs.view.elementsEqual(rhs.view)
  }

  public func hash(into hasher: inout Hasher)
  {
    hasher.combine(view.count)
    for element in view
    {
      hasher.combine(element)
    }
  }
}

extension LatticeUSDArray: Sequence
{
  public func makeIterator() -> UnsafeBufferPointer<Element>.Iterator
  {
    view.makeIterator()
  }
}

extension LatticeUSDArray: ExpressibleByArrayLiteral
{
  public init(arrayLiteral elements: Element...)
  {
    self.init(copying: elements)
  }
}

/// Manually-managed storage for ``LatticeUSDArray/init(copying:)``. A plain
/// Swift array can't back a long-lived view (its buffer pointer is only valid
/// inside `withUnsafeBufferPointer`), so owned views allocate their own buffer
/// and free it when the last reference goes away.
private final class OwnedBuffer<Element>
{
  let storage: UnsafeMutableBufferPointer<Element>

  init(copying elements: [Element])
  {
    storage = UnsafeMutableBufferPointer<Element>.allocate(capacity: elements.count)
    _ = storage.initialize(fromContentsOf: elements)
  }

  deinit
  {
    storage.deinitialize()
    storage.deallocate()
  }
}
