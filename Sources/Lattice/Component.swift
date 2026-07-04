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

/// Marker protocol for any value type that can be stored as a column in the
/// runtime store.
///
/// Conforming types should be plain value types (structs) with no reference
/// semantics, so columns can be freely copied and moved between archetypes,
/// and so they're eligible for direct GPU-buffer backing later (see
/// `LatticeMetal.LatticeGPUComponent`, a stricter refinement of this
/// protocol for types that also need a fixed, POD-like memory layout).
public protocol LatticeComponent {}

/// The stable identity used to key columns and archetype signatures.
/// A type alias over `ObjectIdentifier` rather than a custom type, since
/// `ObjectIdentifier(SomeComponent.self)` is already a cheap, stable,
/// hashable key with no registration step required.
public typealias ComponentTypeID = ObjectIdentifier
