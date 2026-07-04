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

/// Type-erased, per-component-type column of data, indexed by row.
///
/// A column is the "structure of arrays" half of the store: every entity in
/// an archetype occupies the same row across all of that archetype's
/// columns, so iterating one component type touches a single, densely
/// packed sequence with no pointer chasing between entities. This protocol
/// only exposes the structural operations the store itself needs
/// (`count`, `swapRemove`, change tracking); typed reads and writes go
/// through ``TypedColumnStorage``.
public protocol ColumnStorage: AnyObject
{
  /// Number of rows currently stored.
  var count: Int { get }

  /// Removes the row at `index` by moving the last row into its place
  /// (swap-remove), keeping the column dense. Returns whether a row was
  /// actually moved (`false` when removing the last row, or an
  /// out-of-range index).
  @discardableResult
  func swapRemove(at index: Int) -> Bool

  /// Monotonically increasing counter, bumped on every *content* write to
  /// this column - appending a value or overwriting one - but **not** on the
  /// swap-remove that structural changes (despawn, moving an entity between
  /// archetypes) perform. This is Lattice's stand-in for USD's `TfNotice`:
  /// instead of subscribing to a callback per value change, a system compares
  /// this number against the value it last observed to decide whether it has
  /// any work to do at all this frame.
  ///
  /// This is the coarse, whole-column signal. For "*which* rows changed", see
  /// the per-row change ticks on ``TypedColumnStorage``.
  var mutationGeneration: UInt64 { get }

  /// The change tick stamped on `index`. Exposed on the type-erased protocol
  /// so structural code (archetype moves) can read and preserve a row's tick
  /// without knowing its concrete element type.
  func changeTick(at index: Int) -> UInt64
}

/// A column with a statically known element type, supporting typed reads,
/// writes, and contiguous bulk access.
///
/// Both the default array-backed ``TypedColumn`` and
/// `LatticeMetal.MetalBackedColumn` (an `MTLBuffer`-backed column) conform, so
/// the store can hold either behind `any ColumnStorage` and queries can drive
/// either through `any TypedColumnStorage<Element>` - this is what lets a
/// component opt into GPU-resident storage without the query or store code
/// knowing which backing it got.
public protocol TypedColumnStorage<Element>: ColumnStorage
{
  associatedtype Element: LatticeComponent

  /// Appends a value with an unset (`0`) change tick and returns its row.
  @discardableResult
  func append(_ value: Element) -> Int

  /// Appends a value carrying an explicit change tick - used when an entity
  /// moves between archetypes so the relocated value keeps its original
  /// "last changed" stamp instead of looking freshly written.
  @discardableResult
  func appendPreservingTick(_ value: Element, tick: UInt64) -> Int

  func get(_ index: Int) -> Element
  func set(_ index: Int, _ value: Element)

  /// Stamps `index` with `tick`, marking that row's value as changed as of
  /// that tick. The store calls this after each write it performs.
  func stamp(_ index: Int, tick: UInt64)

  /// Read-only contiguous access for vectorizable bulk iteration.
  func withUnsafeBufferPointer<R>(_ body: (UnsafeBufferPointer<Element>) throws -> R) rethrows -> R

  /// Mutable contiguous access for vectorizable bulk mutation. Bumps
  /// ``mutationGeneration`` once for the whole pass.
  func withUnsafeMutableBufferPointer<R>(_ body: (UnsafeMutableBufferPointer<Element>) throws -> R) rethrows -> R
}

/// Concrete, densely packed storage for a single component type `T`, backed
/// by a plain Swift array. This is the default column type every archetype
/// uses unless you opt a component into GPU-backed storage (see
/// `LatticeMetal.MetalBackedColumn`).
public final class TypedColumn<T: LatticeComponent>: TypedColumnStorage
{
  public typealias Element = T

  private var values: [T] = []
  /// Per-row "last changed" ticks, kept parallel to `values`.
  private var ticks: [UInt64] = []
  public private(set) var mutationGeneration: UInt64 = 0

  public init() {}

  public var count: Int
  {
    values.count
  }

  @discardableResult
  public func append(_ value: T) -> Int
  {
    values.append(value)
    ticks.append(0)
    mutationGeneration &+= 1
    return values.count - 1
  }

  @discardableResult
  public func appendPreservingTick(_ value: T, tick: UInt64) -> Int
  {
    values.append(value)
    ticks.append(tick)
    mutationGeneration &+= 1
    return values.count - 1
  }

  public func get(_ index: Int) -> T
  {
    values[index]
  }

  public func set(_ index: Int, _ value: T)
  {
    values[index] = value
    mutationGeneration &+= 1
  }

  public func stamp(_ index: Int, tick: UInt64)
  {
    ticks[index] = tick
  }

  public func changeTick(at index: Int) -> UInt64
  {
    ticks[index]
  }

  /// Borrows the whole column as a contiguous buffer for read-only bulk
  /// iteration. This is the "structure of arrays" payoff: the closure sees a
  /// flat `UnsafeBufferPointer<T>` the optimizer can walk (and vectorize)
  /// without a bounds-checked class-method call per element.
  @inline(__always)
  public func withUnsafeBufferPointer<R>(_ body: (UnsafeBufferPointer<T>) throws -> R) rethrows -> R
  {
    try values.withUnsafeBufferPointer(body)
  }

  /// Borrows the whole column as a contiguous *mutable* buffer for bulk
  /// mutation. Bumps ``mutationGeneration`` once for the whole pass - the
  /// caller is assumed to write - rather than once per element, which both
  /// keeps the change counter coarse (as intended) and lets the inner loop
  /// stay branch- and call-free.
  @inline(__always)
  public func withUnsafeMutableBufferPointer<R>(_ body: (UnsafeMutableBufferPointer<T>) throws -> R) rethrows -> R
  {
    mutationGeneration &+= 1
    return try values.withUnsafeMutableBufferPointer { try body($0) }
  }

  @discardableResult
  public func swapRemove(at index: Int) -> Bool
  {
    guard index < values.count else { return false }
    let lastIndex = values.count - 1
    let moved = index != lastIndex
    if moved
    {
      values.swapAt(index, lastIndex)
      ticks.swapAt(index, lastIndex)
    }
    values.removeLast()
    ticks.removeLast()
    // Deliberately does *not* bump mutationGeneration: relocating/dropping a
    // row is a structural change, not a value edit. See the protocol comment.
    return moved
  }
}
