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

/// A lightweight, dense identifier for a single object tracked by a
/// ``LatticeStore``.
///
/// `LatticeEntity` intentionally carries no data of its own. It is a packed
/// index/generation pair, the same shape used by archetype-based ECS
/// designs (Bevy, EnTT, Unity DOTS). The generation guards against stale
/// handles after an index has been recycled by ``LatticeStore/despawn(_:)``.
///
/// This is the thing everything else in Lattice is keyed by. A USD prim
/// path is *not* an entity - see ``LatticePathTable`` for how the two are
/// bridged.
public struct LatticeEntity: Hashable, Sendable
{
  /// Index into the store's entity location table.
  public let index: UInt32
  /// Incremented every time `index` is recycled, so old handles become
  /// distinguishable from whatever now occupies that slot.
  public let generation: UInt32

  public init(index: UInt32, generation: UInt32)
  {
    self.index = index
    self.generation = generation
  }
}

extension LatticeEntity: CustomStringConvertible
{
  public var description: String
  {
    "Entity(\(index)#\(generation))"
  }
}
