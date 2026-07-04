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

import Dispatch
import Foundation

/// A pointer wrapper that asserts thread-safety the type system can't see.
///
/// The parallel query paths below hand each worker a disjoint, non-overlapping
/// slice of the same column, so the raw base pointers are safe to share across
/// threads even though `UnsafeMutablePointer`/`UnsafePointer` aren't `Sendable`.
/// Confining that unchecked assertion to this one box keeps it auditable.
private struct UnsafeSendable<P>: @unchecked Sendable
{
  let pointer: P
  init(_ pointer: P) { self.pointer = pointer }
}

/// A read-only view over every entity that has a component of type `A`.
///
/// Constructing a query snapshots which archetypes currently match; it does
/// not re-check on every call. For starting out this is fine - build a fresh query
/// each frame (they're cheap, just a lookup into the store's component->archetype
/// index, not a scan over entities) rather than holding one across structural changes.
public struct Query1<A: LatticeComponent>
{
  private let archetypes: [Archetype]

  init(store: LatticeStore)
  {
    archetypes = store.matchingArchetypes(required: [ObjectIdentifier(A.self)])
  }

  public func forEach(_ body: (LatticeEntity, A) -> Void)
  {
    for archetype in archetypes
    {
      guard let column = archetype.column(A.self) else { continue }
      let entities = archetype.entities
      column.withUnsafeBufferPointer
      { a in
        for row in 0 ..< a.count
        {
          body(entities[row], a[row])
        }
      }
    }
  }

  /// Visits only the entities whose `A` was written strictly after `tick` -
  /// Lattice's per-row change detection. Record `store.currentTick` when you
  /// last ran, then pass it here next time to touch only what changed since:
  /// the shape of a "push just the dirty rows back to USD / re-upload only the
  /// changed slice of a GPU buffer" pass.
  public func forEachChanged(since tick: UInt64, _ body: (LatticeEntity, A) -> Void)
  {
    for archetype in archetypes
    {
      guard let column = archetype.column(A.self) else { continue }
      let entities = archetype.entities
      column.withUnsafeBufferPointer
      { a in
        for row in 0 ..< a.count where column.changeTick(at: row) > tick
        {
          body(entities[row], a[row])
        }
      }
    }
  }
}

/// A read-only view over every entity that has components of both type `A`
/// and type `B`.
public struct Query2<A: LatticeComponent, B: LatticeComponent>
{
  private let archetypes: [Archetype]

  init(store: LatticeStore)
  {
    archetypes = store.matchingArchetypes(required: [ObjectIdentifier(A.self), ObjectIdentifier(B.self)])
  }

  /// Calls `body` once per matching entity, in archetype/row order.
  public func forEach(_ body: (LatticeEntity, A, B) -> Void)
  {
    for archetype in archetypes
    {
      guard let columnA = archetype.column(A.self), let columnB = archetype.column(B.self) else { continue }
      let entities = archetype.entities
      columnA.withUnsafeBufferPointer
      { a in
        columnB.withUnsafeBufferPointer
        { b in
          for row in 0 ..< a.count
          {
            body(entities[row], a[row], b[row])
          }
        }
      }
    }
  }

  /// Bulk-mutates `A` in place using the current value of `B`, without any
  /// per-entity lookups. This is the shape a transform-integration or
  /// physics-response system should use: mutate the thing driven by
  /// simulation, read the thing driving it. Iterates over contiguous buffers
  /// so the loop body can vectorize.
  public func forEachMutatingFirst(_ body: (LatticeEntity, inout A, B) -> Void)
  {
    for archetype in archetypes
    {
      guard let columnA = archetype.column(A.self), let columnB = archetype.column(B.self) else { continue }
      let entities = archetype.entities
      columnA.withUnsafeMutableBufferPointer
      { a in
        columnB.withUnsafeBufferPointer
        { b in
          for row in 0 ..< a.count
          {
            body(entities[row], &a[row], b[row])
          }
        }
      }
    }
  }

  /// Same as `forEachMutatingFirst`, mutating `B` instead of `A`.
  public func forEachMutatingSecond(_ body: (LatticeEntity, A, inout B) -> Void)
  {
    for archetype in archetypes
    {
      guard let columnA = archetype.column(A.self), let columnB = archetype.column(B.self) else { continue }
      let entities = archetype.entities
      columnB.withUnsafeMutableBufferPointer
      { b in
        columnA.withUnsafeBufferPointer
        { a in
          for row in 0 ..< b.count
          {
            body(entities[row], a[row], &b[row])
          }
        }
      }
    }
  }

  /// Parallel counterpart to ``forEachMutatingFirst``: splits each matching
  /// archetype's rows into contiguous batches and runs them across the global
  /// concurrent queue. Each worker owns a disjoint row range, so mutating `A`
  /// while reading `B` needs no locking.
  ///
  /// This is where Lattice's columnar layout pays off the way Fabric's does:
  /// a per-frame simulation pass over hundreds of thousands of entities is
  /// embarrassingly parallel as long as **no structural change runs at the
  /// same time**. `LatticeStore` is single-writer for structure - `spawn`,
  /// `despawn`, `set`-that-adds-a-type, and `remove` must not overlap with a
  /// running query. Value mutation through these query paths is the only thing
  /// safe to fan out.
  ///
  /// The entity handle is intentionally omitted here: the parallel shape is
  /// meant for data-parallel math on the components themselves, not for work
  /// that reaches back into the store per row. `batchSize` trades scheduling
  /// overhead against load balance; the default suits cheap per-row math.
  public func forEachMutatingFirstParallel(
    batchSize: Int = 4096,
    _ body: @Sendable (inout A, B) -> Void
  ) where A: Sendable, B: Sendable
  {
    for archetype in archetypes
    {
      guard let columnA = archetype.column(A.self), let columnB = archetype.column(B.self) else { continue }
      let count = archetype.rowCount
      guard count > 0 else { continue }

      columnA.withUnsafeMutableBufferPointer
      { a in
        columnB.withUnsafeBufferPointer
        { b in
          guard let aBase = a.baseAddress, let bBase = b.baseAddress else { return }

          // Below the batch threshold, threading overhead isn't worth it.
          if count <= batchSize
          {
            for row in 0 ..< count
            {
              body(&aBase[row], bBase[row])
            }
            return
          }

          let boxA = UnsafeSendable(aBase)
          let boxB = UnsafeSendable(bBase)
          let batches = (count + batchSize - 1) / batchSize

          DispatchQueue.concurrentPerform(iterations: batches)
          { batch in
            let start = batch * batchSize
            let end = min(start + batchSize, count)
            let ap = boxA.pointer
            let bp = boxB.pointer
            for row in start ..< end
            {
              body(&ap[row], bp[row])
            }
          }
        }
      }
    }
  }
}

/// A view over every entity that has components `A`, `B`, and `C`.
public struct Query3<A: LatticeComponent, B: LatticeComponent, C: LatticeComponent>
{
  private let archetypes: [Archetype]

  init(store: LatticeStore)
  {
    archetypes = store.matchingArchetypes(required: [
      ObjectIdentifier(A.self), ObjectIdentifier(B.self), ObjectIdentifier(C.self),
    ])
  }

  public func forEach(_ body: (LatticeEntity, A, B, C) -> Void)
  {
    for archetype in archetypes
    {
      guard
        let columnA = archetype.column(A.self),
        let columnB = archetype.column(B.self),
        let columnC = archetype.column(C.self)
      else { continue }
      let entities = archetype.entities
      columnA.withUnsafeBufferPointer { a in
        columnB.withUnsafeBufferPointer { b in
          columnC.withUnsafeBufferPointer { c in
            for row in 0 ..< a.count
            {
              body(entities[row], a[row], b[row], c[row])
            }
          }
        }
      }
    }
  }

  /// Bulk-mutates `A` in place using the current values of `B` and `C`.
  public func forEachMutatingFirst(_ body: (LatticeEntity, inout A, B, C) -> Void)
  {
    for archetype in archetypes
    {
      guard
        let columnA = archetype.column(A.self),
        let columnB = archetype.column(B.self),
        let columnC = archetype.column(C.self)
      else { continue }
      let entities = archetype.entities
      columnA.withUnsafeMutableBufferPointer { a in
        columnB.withUnsafeBufferPointer { b in
          columnC.withUnsafeBufferPointer { c in
            for row in 0 ..< a.count
            {
              body(entities[row], &a[row], b[row], c[row])
            }
          }
        }
      }
    }
  }
}

/// A view over every entity that has components `A`, `B`, `C`, and `D`.
public struct Query4<A: LatticeComponent, B: LatticeComponent, C: LatticeComponent, D: LatticeComponent>
{
  private let archetypes: [Archetype]

  init(store: LatticeStore)
  {
    archetypes = store.matchingArchetypes(required: [
      ObjectIdentifier(A.self), ObjectIdentifier(B.self),
      ObjectIdentifier(C.self), ObjectIdentifier(D.self),
    ])
  }

  public func forEach(_ body: (LatticeEntity, A, B, C, D) -> Void)
  {
    for archetype in archetypes
    {
      guard
        let columnA = archetype.column(A.self),
        let columnB = archetype.column(B.self),
        let columnC = archetype.column(C.self),
        let columnD = archetype.column(D.self)
      else { continue }
      let entities = archetype.entities
      columnA.withUnsafeBufferPointer { a in
        columnB.withUnsafeBufferPointer { b in
          columnC.withUnsafeBufferPointer { c in
            columnD.withUnsafeBufferPointer { d in
              for row in 0 ..< a.count
              {
                body(entities[row], a[row], b[row], c[row], d[row])
              }
            }
          }
        }
      }
    }
  }

  /// Bulk-mutates `A` in place using the current values of `B`, `C`, and `D`.
  public func forEachMutatingFirst(_ body: (LatticeEntity, inout A, B, C, D) -> Void)
  {
    for archetype in archetypes
    {
      guard
        let columnA = archetype.column(A.self),
        let columnB = archetype.column(B.self),
        let columnC = archetype.column(C.self),
        let columnD = archetype.column(D.self)
      else { continue }
      let entities = archetype.entities
      columnA.withUnsafeMutableBufferPointer { a in
        columnB.withUnsafeBufferPointer { b in
          columnC.withUnsafeBufferPointer { c in
            columnD.withUnsafeBufferPointer { d in
              for row in 0 ..< a.count
              {
                body(entities[row], &a[row], b[row], c[row], d[row])
              }
            }
          }
        }
      }
    }
  }
}

public extension LatticeStore
{
  func query<A: LatticeComponent>(_: A.Type) -> Query1<A>
  {
    Query1<A>(store: self)
  }

  func query<A: LatticeComponent, B: LatticeComponent>(_: A.Type, _: B.Type) -> Query2<A, B>
  {
    Query2<A, B>(store: self)
  }

  func query<A: LatticeComponent, B: LatticeComponent, C: LatticeComponent>(
    _: A.Type, _: B.Type, _: C.Type
  ) -> Query3<A, B, C>
  {
    Query3<A, B, C>(store: self)
  }

  func query<A: LatticeComponent, B: LatticeComponent, C: LatticeComponent, D: LatticeComponent>(
    _: A.Type, _: B.Type, _: C.Type, _: D.Type
  ) -> Query4<A, B, C, D>
  {
    Query4<A, B, C, D>(store: self)
  }
}
