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

/// A small, closed set of value types Lattice knows how to copy into its
/// own columns.
public enum LatticeUSDValue: Equatable, Sendable
{
  case double(Double)
  case float3(Float, Float, Float)
  case bool(Bool)
  case string(String)
}
