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
import XCTest

private struct Position: LatticeComponent, Equatable
{
  var x: Float
  var y: Float
}

private struct Tag: LatticeComponent, Equatable
{
  var name: String
}

private struct Vel: LatticeComponent, Equatable
{
  var dx: Float
  var dy: Float
}

final class StoreTests: XCTestCase
{
  func testSpawnAndGet()
  {
    let store = LatticeStore()
    store.register(Position.self)

    let entity = store.spawn()
    store.set(Position(x: 1, y: 2), on: entity)

    XCTAssertEqual(store.get(Position.self, for: entity), Position(x: 1, y: 2))
  }

  func testAddingComponentMovesArchetype()
  {
    let store = LatticeStore()
    store.register(Position.self)
    store.register(Tag.self)

    let entity = store.spawn()
    store.set(Position(x: 0, y: 0), on: entity)
    XCTAssertTrue(store.has(Position.self, on: entity))
    XCTAssertFalse(store.has(Tag.self, on: entity))

    store.set(Tag(name: "player"), on: entity)
    XCTAssertTrue(store.has(Position.self, on: entity))
    XCTAssertTrue(store.has(Tag.self, on: entity))
    XCTAssertEqual(store.get(Position.self, for: entity), Position(x: 0, y: 0))
    XCTAssertEqual(store.get(Tag.self, for: entity), Tag(name: "player"))
  }

  func testRemovingComponentMovesArchetype()
  {
    let store = LatticeStore()
    store.register(Position.self)
    store.register(Tag.self)

    let entity = store.spawn()
    store.set(Position(x: 3, y: 4), on: entity)
    store.set(Tag(name: "enemy"), on: entity)

    store.remove(Tag.self, from: entity)

    XCTAssertTrue(store.has(Position.self, on: entity))
    XCTAssertFalse(store.has(Tag.self, on: entity))
    XCTAssertEqual(store.get(Position.self, for: entity), Position(x: 3, y: 4))
  }

  func testDespawnRecyclesIndexAndInvalidatesHandle()
  {
    let store = LatticeStore()
    store.register(Position.self)

    let first = store.spawn()
    store.set(Position(x: 1, y: 1), on: first)
    store.despawn(first)

    XCTAssertFalse(store.isAlive(first))

    let second = store.spawn()
    XCTAssertEqual(second.index, first.index)
    XCTAssertNotEqual(second.generation, first.generation)
    XCTAssertNil(store.get(Position.self, for: first))
  }

  func testSwapRemoveKeepsOtherEntitiesIntact()
  {
    let store = LatticeStore()
    store.register(Position.self)

    let a = store.spawn()
    let b = store.spawn()
    let c = store.spawn()
    store.set(Position(x: 1, y: 1), on: a)
    store.set(Position(x: 2, y: 2), on: b)
    store.set(Position(x: 3, y: 3), on: c)

    store.despawn(a)

    XCTAssertEqual(store.get(Position.self, for: b), Position(x: 2, y: 2))
    XCTAssertEqual(store.get(Position.self, for: c), Position(x: 3, y: 3))
  }

  func testQueryIteratesOnlyMatchingArchetype()
  {
    let store = LatticeStore()
    store.register(Position.self)
    store.register(Tag.self)

    let withBoth = store.spawn()
    store.set(Position(x: 5, y: 5), on: withBoth)
    store.set(Tag(name: "both"), on: withBoth)

    let positionOnly = store.spawn()
    store.set(Position(x: 9, y: 9), on: positionOnly)

    var seen: [LatticeEntity] = []
    store.query(Position.self, Tag.self).forEach
    { entity, _, _ in
      seen.append(entity)
    }

    XCTAssertEqual(seen, [withBoth])
  }

  func testMutatingQueryWritesBackThroughColumn()
  {
    let store = LatticeStore()
    store.register(Position.self)

    let entity = store.spawn()
    store.set(Position(x: 0, y: 0), on: entity)

    struct Delta: LatticeComponent { var dx: Float; var dy: Float }
    store.register(Delta.self)
    store.set(Delta(dx: 1, dy: 2), on: entity)

    store.query(Position.self, Delta.self).forEachMutatingFirst
    { _, position, delta in
      position.x += delta.dx
      position.y += delta.dy
    }

    XCTAssertEqual(store.get(Position.self, for: entity), Position(x: 1, y: 2))
  }

  func testMutationGenerationIncreasesOnWrite()
  {
    let store = LatticeStore()
    store.register(Position.self)
    let entity = store.spawn()

    let before = store.mutationGeneration(of: Position.self)
    store.set(Position(x: 0, y: 0), on: entity)
    let afterFirstWrite = store.mutationGeneration(of: Position.self)
    store.set(Position(x: 1, y: 1), on: entity)
    let afterSecondWrite = store.mutationGeneration(of: Position.self)

    XCTAssertGreaterThan(afterFirstWrite, before)
    XCTAssertGreaterThan(afterSecondWrite, afterFirstWrite)
  }

  func testEntityCountTracksSpawnsAndDespawns()
  {
    let store = LatticeStore()
    XCTAssertEqual(store.entityCount, 0)

    let a = store.spawn()
    let b = store.spawn()
    XCTAssertEqual(store.entityCount, 2)

    store.despawn(a)
    XCTAssertEqual(store.entityCount, 1)

    _ = b
  }

  func testSpawnWithComponentsLandsInFinalArchetype()
  {
    let store = LatticeStore()
    store.register(Position.self)
    store.register(Vel.self)

    let entity = store.spawn(Position(x: 1, y: 2), Vel(dx: 3, dy: 4))

    XCTAssertTrue(store.has(Position.self, on: entity))
    XCTAssertTrue(store.has(Vel.self, on: entity))
    XCTAssertEqual(store.get(Position.self, for: entity), Position(x: 1, y: 2))
    XCTAssertEqual(store.get(Vel.self, for: entity), Vel(dx: 3, dy: 4))

    // A single-component spawn overload should match the two-arg one's layout.
    let single = store.spawn(Position(x: 5, y: 6))
    XCTAssertTrue(store.has(Position.self, on: single))
    XCTAssertFalse(store.has(Vel.self, on: single))
    XCTAssertEqual(store.get(Position.self, for: single), Position(x: 5, y: 6))
  }

  func testSpawnedWithComponentsIsVisibleToQuery()
  {
    let store = LatticeStore()
    store.register(Position.self)
    store.register(Vel.self)

    let expected = 50
    for i in 0 ..< expected
    {
      store.spawn(Position(x: Float(i), y: 0), Vel(dx: 1, dy: 0))
    }

    var seen = 0
    store.query(Position.self, Vel.self).forEach { _, _, _ in seen += 1 }
    XCTAssertEqual(seen, expected)
  }

  func testDespawnDoesNotBumpMutationGeneration()
  {
    let store = LatticeStore()
    store.register(Position.self)

    let a = store.spawn(Position(x: 0, y: 0))
    let b = store.spawn(Position(x: 1, y: 1))

    let generationBeforeDespawn = store.mutationGeneration(of: Position.self)
    store.despawn(b)

    // Removing an entity relocates rows but changes no value, so the
    // "did any Position change" counter must be unaffected.
    XCTAssertEqual(store.mutationGeneration(of: Position.self), generationBeforeDespawn)
    XCTAssertEqual(store.get(Position.self, for: a), Position(x: 0, y: 0))
  }

  func testParallelMutationMatchesSerialResult()
  {
    let store = LatticeStore()
    store.register(Position.self)
    store.register(Vel.self)

    // Exceed the parallel batch size so the concurrent path is actually taken.
    let count = 20000
    for i in 0 ..< count
    {
      store.spawn(Position(x: Float(i), y: 0), Vel(dx: 2, dy: -1))
    }

    store.query(Position.self, Vel.self).forEachMutatingFirstParallel
    { position, velocity in
      position.x += velocity.dx
      position.y += velocity.dy
    }

    var checked = 0
    var mismatches = 0
    store.query(Position.self, Vel.self).forEach
    { _, position, _ in
      if position.x != Float(checked) + 2 || position.y != -1 { mismatches += 1 }
      checked += 1
    }

    XCTAssertEqual(checked, count)
    XCTAssertEqual(mismatches, 0)
  }

  func testSetAndSpawnWorkWithoutExplicitRegistration()
  {
    // Registration is now optional; set/spawn auto-register on first use.
    let store = LatticeStore()

    let a = store.spawn(Position(x: 1, y: 2))
    XCTAssertEqual(store.get(Position.self, for: a), Position(x: 1, y: 2))

    let b = store.spawn()
    store.set(Position(x: 3, y: 4), on: b)
    store.set(Tag(name: "unregistered"), on: b) // adds a second, never-registered type
    XCTAssertEqual(store.get(Position.self, for: b), Position(x: 3, y: 4))
    XCTAssertEqual(store.get(Tag.self, for: b), Tag(name: "unregistered"))
    // The archetype move for `b` must have carried Position across intact.
    XCTAssertTrue(store.has(Position.self, on: b))
  }

  func testChangedSinceTracksPerRowWrites()
  {
    let store = LatticeStore()
    let a = store.spawn(Position(x: 0, y: 0))
    let b = store.spawn(Position(x: 0, y: 0))

    let checkpoint = store.currentTick
    store.advanceChangeTick()
    store.set(Position(x: 9, y: 9), on: b) // only b changes after the checkpoint

    var changed: [LatticeEntity] = []
    store.query(Position.self).forEachChanged(since: checkpoint)
    { entity, _ in
      changed.append(entity)
    }
    XCTAssertEqual(changed, [b])
    XCTAssertFalse(changed.contains(a))
  }

  func testChangeTickIsPreservedAcrossArchetypeMove()
  {
    let store = LatticeStore()
    let entity = store.spawn(Position(x: 1, y: 1))

    let afterSpawn = store.currentTick
    store.advanceChangeTick()
    // Adding a *different* component moves the entity's archetype but must not
    // make its unchanged Position look freshly written.
    store.set(Tag(name: "x"), on: entity)

    var changedPositions = 0
    store.query(Position.self).forEachChanged(since: afterSpawn) { _, _ in changedPositions += 1 }
    XCTAssertEqual(changedPositions, 0)
  }

  func testQuery3AndQuery4()
  {
    struct C: LatticeComponent, Equatable { var v: Float }
    struct D: LatticeComponent, Equatable { var v: Float }

    let store = LatticeStore()
    let e = store.spawn(Position(x: 1, y: 1), Vel(dx: 2, dy: 2))
    store.set(C(v: 3), on: e)
    store.set(D(v: 4), on: e)

    var seen3 = 0
    store.query(Position.self, Vel.self, C.self).forEachMutatingFirst
    { _, position, vel, c in
      position.x += vel.dx + c.v
      seen3 += 1
    }
    XCTAssertEqual(seen3, 1)
    XCTAssertEqual(store.get(Position.self, for: e), Position(x: 6, y: 1))

    var seen4 = 0
    store.query(Position.self, Vel.self, C.self, D.self).forEach { _, _, _, _, _ in seen4 += 1 }
    XCTAssertEqual(seen4, 1)
  }

  func testCustomColumnFactoryIsUsed()
  {
    var factoryInvocations = 0
    let store = LatticeStore()
    store.register(Position.self)
    { () -> any ColumnStorage in
      factoryInvocations += 1
      return TypedColumn<Position>()
    }

    let entity = store.spawn(Position(x: 7, y: 8))
    XCTAssertGreaterThan(factoryInvocations, 0)
    XCTAssertEqual(store.get(Position.self, for: entity), Position(x: 7, y: 8))
  }

  func testQueryExclusionFilter()
  {
    let store = LatticeStore()
    let plain = store.spawn(Position(x: 1, y: 1))
    let tagged = store.spawn(Position(x: 2, y: 2))
    store.set(Tag(name: "hidden"), on: tagged)

    var seen: [LatticeEntity] = []
    store.query(Position.self, excluding: Tag.self).forEach { entity, _ in seen.append(entity) }
    XCTAssertEqual(seen, [plain])
    XCTAssertFalse(seen.contains(tagged))

    // Without exclusion, both match.
    var all = 0
    store.query(Position.self).forEach { _, _ in all += 1 }
    XCTAssertEqual(all, 2)
  }

  func testSchedulerBatchesDisjointSystemsIntoOneWave()
  {
    struct Health: LatticeComponent, Equatable { var hp: Float }

    let store = LatticeStore()
    for i in 0 ..< 500
    {
      store.spawn(Position(x: Float(i), y: 0), Vel(dx: 1, dy: 0))
    }
    for _ in 0 ..< 500
    {
      store.spawn(Health(hp: 10))
    }

    let scheduler = LatticeScheduler()
    scheduler.add(LatticeSystem("integrate", reads: [Vel.self], writes: [Position.self])
    { s in
      s.query(Position.self, Vel.self).forEachMutatingFirst { _, p, v in p.x += v.dx }
    })
    scheduler.add(LatticeSystem("regen", writes: [Health.self])
    { s in
      s.query(Health.self).forEachMutating { _, h in h.hp += 1 }
    })

    // Disjoint access sets -> a single concurrent wave.
    XCTAssertEqual(scheduler.waves().count, 1)
    XCTAssertEqual(scheduler.waves().first?.count, 2)

    scheduler.run(on: store)

    var integrated = 0
    store.query(Position.self, Vel.self).forEach
    { _, p, _ in
      if p.x == Float(integrated) + 1 { integrated += 1 }
    }
    XCTAssertEqual(integrated, 500)

    var regenerated = 0
    store.query(Health.self).forEach { _, h in if h.hp == 11 { regenerated += 1 } }
    XCTAssertEqual(regenerated, 500)
  }

  func testSchedulerOrdersConflictingSystemsIntoSeparateWaves()
  {
    let store = LatticeStore()
    store.spawn(Position(x: 0, y: 0), Vel(dx: 0, dy: 0))

    let scheduler = LatticeScheduler()
    // A writes Position; B reads Position and writes Vel - they conflict on
    // Position, so B must run in a later wave than A.
    scheduler.add(LatticeSystem("a", writes: [Position.self]) { _ in })
    scheduler.add(LatticeSystem("b", reads: [Position.self], writes: [Vel.self]) { _ in })
    scheduler.add(LatticeSystem("c", writes: [Vel.self]) { _ in }) // conflicts b on Vel

    let waves = scheduler.waves()
    XCTAssertEqual(waves.count, 3)
    XCTAssertEqual(waves[0].map(\.label), ["a"])
    XCTAssertEqual(waves[1].map(\.label), ["b"])
    XCTAssertEqual(waves[2].map(\.label), ["c"])
  }

  func testPathTableBindingIteration()
  {
    let table = LatticePathTable()
    let a = LatticeEntity(index: 0, generation: 0)
    let b = LatticeEntity(index: 1, generation: 0)
    table.bind(a, to: "/root/a")
    table.bind(b, to: "/root/b")

    XCTAssertEqual(table.count, 2)

    var visited: [LatticeEntity: String] = [:]
    table.forEachBinding { entity, path in visited[entity] = path }
    XCTAssertEqual(visited, [a: "/root/a", b: "/root/b"])

    table.unbind(a)
    XCTAssertEqual(table.count, 1)
    var afterUnbind: [LatticeEntity: String] = [:]
    table.forEachBinding { entity, path in afterUnbind[entity] = path }
    XCTAssertEqual(afterUnbind, [b: "/root/b"])
  }
}
