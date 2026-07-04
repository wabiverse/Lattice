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

/// Coarse-grained change detection for `LatticeStore`.
///
/// USD's `TfNotice` pushes a callback per change, which is exactly the kind
/// of per-value overhead Fabric was built to avoid. Lattice takes the same
/// position: instead of subscribing to individual writes, a system asks
/// "has anything of this component type changed since I last checked" by
/// comparing a cheap integer.
public extension LatticeStore
{
  /// Sum of every matching archetype's mutation counter for component
  /// type `T`. Compare this against a value you cached last frame: if it
  /// is unchanged, no entity's `T` was written to since then, and a
  /// downstream system (re-uploading a GPU buffer, re-running a bounds
  /// pass) can skip entirely.
  ///
  /// Because the per-column counter only advances on *content* writes
  /// (append/overwrite/bulk-mutation) and never on the swap-remove that
  /// despawns and archetype moves perform, this won't report a spurious
  /// change just because some unrelated entity's component set changed.
  ///
  /// This is deliberately whole-store, not per-entity - it answers "did
  /// *anything* change", not "did *this* entity change". Per-entity
  /// change ticks (the way Bevy's change detection works) are a
  /// reasonable next step once a real workload needs finer granularity;
  /// they'd need a generation stamped per row rather than per column.
  func mutationGeneration(of type: (some LatticeComponent).Type) -> UInt64
  {
    let typeID = ObjectIdentifier(type)
    return matchingArchetypes(required: [typeID]).reduce(UInt64(0))
    { partial, archetype in
      guard let column = archetype.column(type) else { return partial }
      return partial + column.mutationGeneration
    }
  }
}
