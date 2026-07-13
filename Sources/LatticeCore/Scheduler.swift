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

/// A unit of per-frame work with a declared component access set.
///
/// A system reads some component types and writes others. Two systems can run
/// at the same time exactly when their accesses don't collide - no two writers
/// of the same type, and no reader running against a concurrent writer. By
/// declaring that access up front, a ``LatticeScheduler`` can prove which
/// systems are independent and run them in parallel, which is how Fabric keeps
/// a frame's worth of systems busy across cores without hand-written locking.
///
/// The body does value mutation through queries; it must **not** perform
/// structural changes (`spawn`/`despawn`/adding or removing a component type),
/// because those mutate shared indices and aren't safe to run concurrently.
/// Do structural edits between scheduler runs, not inside a system.
public struct LatticeSystem: Sendable
{
  public let label: String
  public let reads: Set<ComponentTypeID>
  public let writes: Set<ComponentTypeID>
  private let body: @Sendable (LatticeStore) -> Void

  public init(
    _ label: String,
    reads: [any LatticeComponent.Type] = [],
    writes: [any LatticeComponent.Type] = [],
    body: @escaping @Sendable (LatticeStore) -> Void
  )
  {
    self.label = label
    self.reads = Set(reads.map(ObjectIdentifier.init))
    self.writes = Set(writes.map(ObjectIdentifier.init))
    self.body = body
  }

  func run(on store: LatticeStore)
  {
    body(store)
  }

  /// Two systems conflict if they can't safely run at the same time: a
  /// write-write overlap, or a write on one side against a read on the other.
  /// Two pure readers of the same type never conflict.
  func conflicts(with other: LatticeSystem) -> Bool
  {
    !writes.isDisjoint(with: other.writes)
      || !writes.isDisjoint(with: other.reads)
      || !reads.isDisjoint(with: other.writes)
  }
}

/// Lets a `LatticeStore` cross into a concurrent `DispatchQueue.concurrentPerform`
/// closure. Safe because the scheduler only ever runs systems together when
/// their declared accesses are disjoint, so no two concurrent bodies touch the
/// same component column.
private struct UncheckedSendableStore: @unchecked Sendable
{
  let store: LatticeStore
}

/// Runs a set of ``LatticeSystem``s each frame, extracting parallelism from
/// their declared accesses.
///
/// Systems are grouped into ordered *waves*: every system in a wave is mutually
/// non-conflicting, so the whole wave runs concurrently, and waves execute in
/// sequence with a barrier between them. Grouping preserves registration order
/// for any conflicting pair - if system *B* was added after system *A* and the
/// two conflict, *B* always runs in a later wave than *A* - so a
/// write-then-read dependency between two systems resolves the way you wrote
/// it, while independent systems still overlap.
///
/// This is the across-systems counterpart to `Query.forEachMutatingFirstParallel`'s
/// within-a-system parallelism.
public final class LatticeScheduler
{
  private var systems: [LatticeSystem] = []

  public init() {}

  /// Registers a system. Order matters only between systems that conflict.
  public func add(_ system: LatticeSystem)
  {
    systems.append(system)
  }

  public var systemCount: Int
  {
    systems.count
  }

  /// The computed execution schedule: an ordered list of waves, each a set of
  /// systems safe to run together. Exposed so callers (and tests) can inspect
  /// the parallelism the scheduler found.
  public func waves() -> [[LatticeSystem]]
  {
    var waves: [[LatticeSystem]] = []
    var waveIndexOf: [Int] = []

    for index in systems.indices
    {
      let system = systems[index]

      // The system must land after every earlier system it conflicts with.
      var lastConflictingWave = -1
      for earlier in 0 ..< index where systems[earlier].conflicts(with: system)
      {
        lastConflictingWave = max(lastConflictingWave, waveIndexOf[earlier])
      }

      let target = lastConflictingWave + 1
      if target == waves.count
      {
        waves.append([])
      }
      waves[target].append(system)
      waveIndexOf.append(target)
    }

    return waves
  }

  /// Runs every system once, wave by wave: each wave's systems run
  /// concurrently, with a barrier before the next wave begins.
  public func run(on store: LatticeStore)
  {
    for wave in waves()
    {
      if wave.count == 1
      {
        wave[0].run(on: store)
        continue
      }

      let boxed = UncheckedSendableStore(store: store)
      DispatchQueue.concurrentPerform(iterations: wave.count)
      { index in
        wave[index].run(on: boxed.store)
      }
    }
  }
}
