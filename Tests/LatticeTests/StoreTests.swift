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

import LatticeCore
import Testing

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

@Suite("Store")
struct StoreTests
{
  // MARK: - Entity lifecycle

  @Test("a spawned entity reads back the component it was set")
  func spawnAndGet()
  {
    let store = LatticeStore()
    store.register(Position.self)

    let entity = store.spawn()
    store.set(Position(x: 1, y: 2), on: entity)

    #expect(store.get(Position.self, for: entity) == Position(x: 1, y: 2))
  }

  @Test("adding a component moves the entity's archetype, carrying existing values across")
  func addingComponentMovesArchetype()
  {
    let store = LatticeStore()
    store.register(Position.self)
    store.register(Tag.self)

    let entity = store.spawn()
    store.set(Position(x: 0, y: 0), on: entity)
    #expect(store.has(Position.self, on: entity))
    #expect(store.has(Tag.self, on: entity) == false)

    store.set(Tag(name: "player"), on: entity)
    #expect(store.has(Position.self, on: entity))
    #expect(store.has(Tag.self, on: entity))
    #expect(store.get(Position.self, for: entity) == Position(x: 0, y: 0))
    #expect(store.get(Tag.self, for: entity) == Tag(name: "player"))
  }

  @Test("removing a component moves the archetype back, keeping the rest")
  func removingComponentMovesArchetype()
  {
    let store = LatticeStore()
    store.register(Position.self)
    store.register(Tag.self)

    let entity = store.spawn()
    store.set(Position(x: 3, y: 4), on: entity)
    store.set(Tag(name: "enemy"), on: entity)

    store.remove(Tag.self, from: entity)

    #expect(store.has(Position.self, on: entity))
    #expect(store.has(Tag.self, on: entity) == false)
    #expect(store.get(Position.self, for: entity) == Position(x: 3, y: 4))
  }

  @Test("despawn recycles the index but bumps the generation, invalidating the old handle")
  func despawnRecyclesIndexAndInvalidatesHandle()
  {
    let store = LatticeStore()
    store.register(Position.self)

    let first = store.spawn()
    store.set(Position(x: 1, y: 1), on: first)
    store.despawn(first)

    #expect(store.isAlive(first) == false)

    let second = store.spawn()
    #expect(second.index == first.index)
    #expect(second.generation != first.generation)
    #expect(store.get(Position.self, for: first) == nil)
  }

  @Test("the swap-remove on despawn leaves other entities' values intact")
  func swapRemoveKeepsOtherEntitiesIntact()
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

    #expect(store.get(Position.self, for: b) == Position(x: 2, y: 2))
    #expect(store.get(Position.self, for: c) == Position(x: 3, y: 3))
  }

  @Test("entityCount tracks spawns and despawns")
  func entityCountTracksSpawnsAndDespawns()
  {
    let store = LatticeStore()
    #expect(store.entityCount == 0)

    let a = store.spawn()
    let b = store.spawn()
    #expect(store.entityCount == 2)

    store.despawn(a)
    #expect(store.entityCount == 1)

    _ = b
  }

  @Test("spawning with components lands the entity directly in its final archetype")
  func spawnWithComponentsLandsInFinalArchetype()
  {
    let store = LatticeStore()
    store.register(Position.self)
    store.register(Vel.self)

    let entity = store.spawn(Position(x: 1, y: 2), Vel(dx: 3, dy: 4))

    #expect(store.has(Position.self, on: entity))
    #expect(store.has(Vel.self, on: entity))
    #expect(store.get(Position.self, for: entity) == Position(x: 1, y: 2))
    #expect(store.get(Vel.self, for: entity) == Vel(dx: 3, dy: 4))

    // A single-component spawn overload should match the two-arg one's layout.
    let single = store.spawn(Position(x: 5, y: 6))
    #expect(store.has(Position.self, on: single))
    #expect(store.has(Vel.self, on: single) == false)
    #expect(store.get(Position.self, for: single) == Position(x: 5, y: 6))
  }

  @Test("entities spawned with components are visible to a matching query")
  func spawnedWithComponentsIsVisibleToQuery()
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
    #expect(seen == expected)
  }

  @Test("registration is optional - set and spawn auto-register on first use")
  func setAndSpawnWorkWithoutExplicitRegistration()
  {
    let store = LatticeStore()

    let a = store.spawn(Position(x: 1, y: 2))
    #expect(store.get(Position.self, for: a) == Position(x: 1, y: 2))

    let b = store.spawn()
    store.set(Position(x: 3, y: 4), on: b)
    store.set(Tag(name: "unregistered"), on: b) // adds a second, never-registered type
    #expect(store.get(Position.self, for: b) == Position(x: 3, y: 4))
    #expect(store.get(Tag.self, for: b) == Tag(name: "unregistered"))
    // The archetype move for `b` must have carried Position across intact.
    #expect(store.has(Position.self, on: b))
  }

  @Test("a custom column factory is used to back the component's storage")
  func customColumnFactoryIsUsed()
  {
    var factoryInvocations = 0
    let store = LatticeStore()
    store.register(Position.self)
    { () -> any ColumnStorage in
      factoryInvocations += 1
      return TypedColumn<Position>()
    }

    let entity = store.spawn(Position(x: 7, y: 8))
    #expect(factoryInvocations > 0)
    #expect(store.get(Position.self, for: entity) == Position(x: 7, y: 8))
  }

  // MARK: - Queries

  @Test("a query iterates only the archetypes matching its full signature")
  func queryIteratesOnlyMatchingArchetype()
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

    #expect(seen == [withBoth])
  }

  @Test("a mutating query writes back through the column")
  func mutatingQueryWritesBackThroughColumn()
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

    #expect(store.get(Position.self, for: entity) == Position(x: 1, y: 2))
  }

  @Test("3- and 4-component queries iterate and mutate correctly")
  func query3AndQuery4()
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
    #expect(seen3 == 1)
    #expect(store.get(Position.self, for: e) == Position(x: 6, y: 1))

    var seen4 = 0
    store.query(Position.self, Vel.self, C.self, D.self).forEach { _, _, _, _, _ in seen4 += 1 }
    #expect(seen4 == 1)
  }

  @Test("an exclusion filter skips entities carrying the excluded type")
  func queryExclusionFilter()
  {
    let store = LatticeStore()
    let plain = store.spawn(Position(x: 1, y: 1))
    let tagged = store.spawn(Position(x: 2, y: 2))
    store.set(Tag(name: "hidden"), on: tagged)

    var seen: [LatticeEntity] = []
    store.query(Position.self, excluding: Tag.self).forEach { entity, _ in seen.append(entity) }
    #expect(seen == [plain])
    #expect(seen.contains(tagged) == false)

    // Without exclusion, both match.
    var all = 0
    store.query(Position.self).forEach { _, _ in all += 1 }
    #expect(all == 2)
  }

  @Test("the parallel mutation path produces the same result as the serial one")
  func parallelMutationMatchesSerialResult()
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

    #expect(checked == count)
    #expect(mismatches == 0)
  }

  // MARK: - Change detection

  @Test("the per-type mutation generation increases on every write")
  func mutationGenerationIncreasesOnWrite()
  {
    let store = LatticeStore()
    store.register(Position.self)
    let entity = store.spawn()

    let before = store.mutationGeneration(of: Position.self)
    store.set(Position(x: 0, y: 0), on: entity)
    let afterFirstWrite = store.mutationGeneration(of: Position.self)
    store.set(Position(x: 1, y: 1), on: entity)
    let afterSecondWrite = store.mutationGeneration(of: Position.self)

    #expect(afterFirstWrite > before)
    #expect(afterSecondWrite > afterFirstWrite)
  }

  @Test("despawn relocates rows but changes no value, so the mutation generation holds")
  func despawnDoesNotBumpMutationGeneration()
  {
    let store = LatticeStore()
    store.register(Position.self)

    let a = store.spawn(Position(x: 0, y: 0))
    let b = store.spawn(Position(x: 1, y: 1))

    let generationBeforeDespawn = store.mutationGeneration(of: Position.self)
    store.despawn(b)

    #expect(store.mutationGeneration(of: Position.self) == generationBeforeDespawn)
    #expect(store.get(Position.self, for: a) == Position(x: 0, y: 0))
  }

  @Test("forEachChanged reports only the rows written after the checkpoint tick")
  func changedSinceTracksPerRowWrites()
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
    #expect(changed == [b])
    #expect(changed.contains(a) == false)
  }

  @Test("an archetype move preserves the row's change tick - relocating isn't writing")
  func changeTickIsPreservedAcrossArchetypeMove()
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
    #expect(changedPositions == 0)
  }

  // MARK: - Scheduler

  @Test("systems with disjoint access sets batch into a single concurrent wave")
  func schedulerBatchesDisjointSystemsIntoOneWave()
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

    #expect(scheduler.waves().count == 1)
    #expect(scheduler.waves().first?.count == 2)

    scheduler.run(on: store)

    var integrated = 0
    store.query(Position.self, Vel.self).forEach
    { _, p, _ in
      if p.x == Float(integrated) + 1 { integrated += 1 }
    }
    #expect(integrated == 500)

    var regenerated = 0
    store.query(Health.self).forEach { _, h in if h.hp == 11 { regenerated += 1 } }
    #expect(regenerated == 500)
  }

  @Test("conflicting systems are ordered into separate waves")
  func schedulerOrdersConflictingSystemsIntoSeparateWaves()
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
    #expect(waves.count == 3)
    #expect(waves[0].map(\.label) == ["a"])
    #expect(waves[1].map(\.label) == ["b"])
    #expect(waves[2].map(\.label) == ["c"])
  }

  // MARK: - Path table

  @Test("the path table binds, iterates, and unbinds path<->entity pairs")
  func pathTableBindingIteration()
  {
    let store = LatticeStore()
    let table = LatticePathTable(framePhase: store.framePhase)
    let a = LatticeEntity(index: 0, generation: 0)
    let b = LatticeEntity(index: 1, generation: 0)
    table.bind(a, to: "/root/a", lookupKey: 1)
    table.bind(b, to: "/root/b", lookupKey: 2)

    #expect(table.count == 2)

    var visited: [LatticeEntity: String] = [:]
    table.forEachBinding { entity, path in visited[entity] = path }
    #expect(visited == [a: "/root/a", b: "/root/b"])

    table.unbind(a)
    #expect(table.count == 1)

    var afterUnbind: [LatticeEntity: String] = [:]
    table.forEachBinding { entity, path in afterUnbind[entity] = path }
    #expect(afterUnbind == [b: "/root/b"])

    // Unbind must clear *both* forward indices, not just the string one - a
    // stale lookup key would resolve to a recycled entity rather than nothing.
    #expect(table.entity(forLookupKey: 1) == nil)
    #expect(table.entity(forLookupKey: 2) == b)
  }
}
