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

import LatticeCore

/// The minimal surface Lattice needs from any USD binding in order to
/// populate a ``LatticeStore``.
public protocol USDStageSourceRepresentable
{
  /// Every prim path currently on the composed stage, in traversal order.
  func primPaths() -> [String]

  /// Reads a named attribute's current resolved value at `path`, if the
  /// prim and attribute exist.
  func attributeValue(at path: String, attribute name: String) -> LatticeUSDValue?

  /// The names of every attribute authored on the prim at `path`, *without*
  /// resolving their values - cheap metadata, so a prefetch can decide which
  /// attributes to pull before paying to read any. Empty when the prim doesn't
  /// exist. This is deliberately a name lister, not a value puller: population
  /// is meant to mirror a bounded, prefetched working set - the way a prim only
  /// enters Fabric because something asked for specific attributes - never a
  /// blanket whole-prim mirror.
  func attributeNames(at path: String) -> [String]

  /// Writes `value` to the named attribute at `path`, returning whether the
  /// write landed. The reverse direction - pushing computed runtime values
  /// back onto the stage - used by `USDPopulationSync.writeBackChanged(...)`.
  ///
  /// Read-only sources can leave this at the default (a no-op returning
  /// `false`); only sources meant to author back into USD implement it.
  func setAttributeValue(_ value: LatticeUSDValue, at path: String, attribute name: String) -> Bool
}

public extension USDStageSourceRepresentable
{
  func setAttributeValue(_: LatticeUSDValue, at _: String, attribute _: String) -> Bool
  {
    false
  }
}

/// The set of value types Lattice knows how to mirror into its own columns.
///
/// The scalar cases are cheap; the **array** cases are where a real asset's
/// memory lives - `points`/`normals`/`primvars` (`.float3Array`), UVs
/// (`.float2Array`), and topology indices (`.intArray`) are the bulk of a
/// real production scene. That's why they're carried as ``LatticeUSDArray``
/// **zero-copy views** rather than Swift arrays: the view holds USD's own
/// refcounted `VtArray` buffer (for crate layers, the file's mmap pages)
/// instead of a second copy, so mirroring a scene's geometry costs handles,
/// not payloads. `.stringArray` is the exception - strings can't be viewed
/// across the C++ boundary, so token/string arrays are copied.
///
/// `Hashable` is what enables population to *bin* array payloads (see
/// `USDPopulationSync.prefetch`): equality is by content with a same-buffer
/// fast path, so two views of one instanced `VtArray` bin in O(1).
///
/// Note `.intArray` carries `Int32` - USD's `int[]`/`uint[]` element width,
/// viewed in place (`uint[]` by bit pattern) - while `int64[]`/`uint64[]`
/// land in `.int64Array`. Scalar ints still widen to `.int(Int64)`.
public enum LatticeUSDValue: Hashable, Sendable
{
  // Scalars.
  case double(Double)
  case int(Int64)
  case bool(Bool)
  case string(String)
  case float2(Float, Float)
  case float3(Float, Float, Float)
  case float4(Float, Float, Float, Float)
  case double16(LatticeDouble4x4)

  // Arrays - the heavy geometry/topology data, viewed zero-copy.
  case floatArray(LatticeUSDArray<Float>)
  case doubleArray(LatticeUSDArray<Double>)
  case intArray(LatticeUSDArray<Int32>)
  case int64Array(LatticeUSDArray<Int64>)
  case boolArray(LatticeUSDArray<Bool>)
  case stringArray([String])
  case float2Array(LatticeUSDArray<LatticeFloat2>)
  case float3Array(LatticeUSDArray<LatticeFloat3>)
  case float4Array(LatticeUSDArray<LatticeFloat4>)
  case double3Array(LatticeUSDArray<LatticeDouble3>)
}

extension LatticeUSDValue
{
  /// Whether this value carries a heap-allocated array payload - the cases
  /// worth binning through an interner. Scalars are stored inline in the enum,
  /// so interning them would spend hash-table entries to share nothing.
  var isArrayBacked: Bool
  {
    switch self
    {
      case .floatArray, .doubleArray, .intArray, .int64Array, .boolArray,
           .stringArray, .float2Array, .float3Array, .float4Array, .double3Array:
        true
      default:
        false
    }
  }
}
