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
public protocol USDStageSource
{
  /// Every prim path currently on the composed stage, in traversal order.
  func primPaths() -> [String]

  /// Reads a named attribute's current resolved value at `path`, if the
  /// prim and attribute exist.
  func attributeValue(at path: String, attribute name: String) -> LatticeUSDValue?
}

/// A small, closed set of value types Lattice knows how to copy into its
/// own columns.
public enum LatticeUSDValue
{
  case double(Double)
  case float3(Float, Float, Float)
  case bool(Bool)
  case string(String)
}
