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

import Lattice

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

/// The set of value types Lattice knows how to copy into its own columns.
///
/// The scalar cases are cheap; the **array** cases are where a real asset's
/// memory lives - `points`/`normals`/`primvars` (`.float3Array`), UVs
/// (`.float2Array`), and topology indices (`.intArray`) are the bulk of a
/// real production scene.
public enum LatticeUSDValue: Equatable, Sendable
{
  // Scalars.
  case double(Double)
  case int(Int64)
  case bool(Bool)
  case string(String)
  case float2(Float, Float)
  case float3(Float, Float, Float)
  case float4(Float, Float, Float, Float)
  case double16(SIMD16<Double>)

  // Arrays - the heavy geometry/topology data.
  case floatArray([Float])
  case doubleArray([Double])
  case intArray([Int64])
  case boolArray([Bool])
  case stringArray([String])
  case float2Array([SIMD2<Float>])
  case float3Array([SIMD3<Float>])
  case float4Array([SIMD4<Float>])
  case double3Array([SIMD3<Double>])
}
