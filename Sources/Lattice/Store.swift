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

/// The runtime store: Lattice's Swift-native analogue of Fabric's bucketed
/// data model. Owns every archetype, tracks where each ``LatticeEntity``
/// currently lives, and is the only place that performs structural changes
/// - adding or removing a component type moves an entity from one
/// archetype to another.
///
/// `LatticeStore` is designed to sit *next to* whatever owns your composed
/// scene description (a `UsdStage`, or nothing at all if you're not using
/// USD), the same way Fabric sits next to a stage: it does not know how to
/// compose layers, resolve variants, or read a `.usda` file. It only knows
/// how to store and iterate values fast, and to move entities between
/// archetypes cheaply when their component set changes.
public final class LatticeStore
{
  private struct Location
  {
    var archetypeIndex: Int
    var row: Int
  }

  private var archetypes: [Archetype] = []
  private var archetypeIndexBySignature: [Set<ComponentTypeID>: Int] = [:]
  /// For each component type, the indices of every archetype whose signature
  /// contains it. Lets ``matchingArchetypes(required:)`` start from the set of
  /// archetypes that could possibly match instead of scanning all of them.
  private var archetypeIndicesByComponent: [ComponentTypeID: [Int]] = [:]
  private var locations: [UInt32: Location] = [:]
  private var generations: [UInt32] = []
  private var freeIndices: [UInt32] = []
  private var componentCopiers: [ComponentTypeID: (Archetype, Int, Archetype) -> Void] = [:]
  /// How to create the backing column for each registered component type.
  /// Defaults to a plain array-backed ``TypedColumn``; ``register(_:columnFactory:)``
  /// overrides it (e.g. to GPU-backed storage).
  private var columnFactories: [ComponentTypeID: () -> any ColumnStorage] = [:]

  /// Stable identity tokens for dynamic, runtime-named columns. A schema-less
  /// source - a `UsdStage`'s attributes, say - names its fields with strings,
  /// not Swift types, so there's no `ObjectIdentifier(T.self)` to key their
  /// columns on. Interning one token object per name gives each name a stable
  /// ``ComponentTypeID`` (`ObjectIdentifier(token)`) that drops into the exact
  /// same archetype/column machinery every static component already uses.
  private final class DynamicColumnKey {}
  private var dynamicColumnKeys: [String: DynamicColumnKey] = [:]

  /// Frame counter, bumped once per tick by whoever drives the main loop.
  /// Lattice doesn't use this internally yet; it's exposed so systems can
  /// stamp "last ran at frame N" style book keeping without each one
  /// needing to keep its own clock.
  public private(set) var frame: UInt64 = 0

  /// Monotonic change-detection clock. Every value written through the store
  /// (or a tracked query) stamps the touched row with this value, so a system
  /// can later ask a query for only the rows that changed since the tick it
  /// last observed - Lattice's per-row analogue of Bevy's change detection,
  /// and the fine-grained counterpart to ``mutationGeneration(of:)``.
  ///
  /// It advances on every ``advanceFrame()`` so per-frame change detection
  /// works with no extra book keeping; call ``advanceChangeTick()`` directly
  /// if you want finer, per-system boundaries within a frame.
  public private(set) var currentTick: UInt64 = 1

  public init()
  {
    // Every entity starts in the archetype with no components at all.
    _ = archetypeIndex(for: [])
  }

  public func advanceFrame()
  {
    frame &+= 1
    advanceChangeTick()
  }

  /// Advances ``currentTick`` by one. Values written after this get the new
  /// tick, so a reader that recorded the old tick sees them as changed.
  public func advanceChangeTick()
  {
    currentTick &+= 1
  }

  // MARK: - Component registration

  /// Registers a component type, optionally choosing how its column is backed.
  ///
  /// Registration is **optional**: `set`/`spawn` register a component the
  /// first time they see it, defaulting to array-backed ``TypedColumn``
  /// storage. Call this explicitly only to opt a component into a different
  /// backing - most usefully `LatticeMetal.MetalBackedColumn`, so its values
  /// live directly in an `MTLBuffer`:
  ///
  /// ```swift
  /// store.register(Particle.self) { MetalBackedColumn<Particle>(device: device) }
  /// ```
  ///
  /// Do this once, before spawning entities with that component, so every
  /// archetype builds the intended column type. `columnFactory` must return a
  /// column whose element type is `T`.
  public func register<T: LatticeComponent>(
    _ type: T.Type,
    columnFactory: (() -> any ColumnStorage)? = nil
  )
  {
    let typeID = ObjectIdentifier(type)
    let factory: () -> any ColumnStorage = columnFactory ?? columnFactories[typeID] ?? { TypedColumn<T>() }
    columnFactories[typeID] = factory
    componentCopiers[typeID] = { oldArchetype, row, newArchetype in
      guard let source = oldArchetype.column(T.self) else { return }
      // Preserve the row's change tick across the move: relocating a value
      // isn't a fresh write, so it shouldn't look changed to a reader.
      _ = newArchetype.ensureColumn(T.self, factory: factory)
        .appendPreservingTick(source.get(row), tick: source.changeTick(at: row))
    }
  }

  /// Ensures `T` has a copier and column factory, registering defaults if it's
  /// the first time the store has seen it.
  private func ensureRegistered(_ type: (some LatticeComponent).Type)
  {
    if columnFactories[ObjectIdentifier(type)] == nil
    {
      register(type)
    }
  }

  /// The column factory for `T`, falling back to array-backed storage.
  private func columnFactory<T: LatticeComponent>(for type: T.Type) -> () -> any ColumnStorage
  {
    columnFactories[ObjectIdentifier(type)] ?? { TypedColumn<T>() }
  }

  // MARK: - Entity lifecycle

  public func spawn() -> LatticeEntity
  {
    let emptyArchetype = archetypeIndex(for: [])
    let entity = allocateEntity()
    let row = archetypes[emptyArchetype].appendEntityRow(entity)
    locations[entity.index] = Location(archetypeIndex: emptyArchetype, row: row)
    return entity
  }

  /// Spawns an entity that already has component `a`, placing it directly in
  /// the archetype for `{A}` in one step.
  ///
  /// Prefer this (and its multi-component overloads) over `spawn()` followed
  /// by `set(_:on:)` when you know an entity's components up front: `spawn()`
  /// then two `set` calls would move the entity through the empty archetype
  /// and one intermediate archetype, copying columns at each hop. Landing it
  /// in the final archetype directly is what keeps bulk population - the
  /// hot path when mirroring a large stage - from thrashing.
  @discardableResult
  public func spawn<A: LatticeComponent>(_ a: A) -> LatticeEntity
  {
    ensureRegistered(A.self)
    let signature: Set<ComponentTypeID> = [ObjectIdentifier(A.self)]
    let archetypeIdx = archetypeIndex(for: signature)
    let entity = allocateEntity()
    let archetype = archetypes[archetypeIdx]
    let row = archetype.appendEntityRow(entity)
    appendStamped(a, into: archetype, expectedRow: row)
    locations[entity.index] = Location(archetypeIndex: archetypeIdx, row: row)
    return entity
  }

  /// Spawns an entity that already has components `a` and `b`, placing it
  /// directly in the archetype for `{A, B}` in one step. See ``spawn(_:)``.
  @discardableResult
  public func spawn<A: LatticeComponent, B: LatticeComponent>(_ a: A, _ b: B) -> LatticeEntity
  {
    ensureRegistered(A.self)
    ensureRegistered(B.self)
    let signature: Set<ComponentTypeID> = [ObjectIdentifier(A.self), ObjectIdentifier(B.self)]
    let archetypeIdx = archetypeIndex(for: signature)
    let entity = allocateEntity()
    let archetype = archetypes[archetypeIdx]
    let row = archetype.appendEntityRow(entity)
    appendStamped(a, into: archetype, expectedRow: row)
    appendStamped(b, into: archetype, expectedRow: row)
    locations[entity.index] = Location(archetypeIndex: archetypeIdx, row: row)
    return entity
  }

  /// Appends `value` to its column in `archetype` and stamps the new row with
  /// the current change tick. `expectedRow` is the entity row it should land
  /// on (they stay in lockstep because every column grows with the entity).
  private func appendStamped<T: LatticeComponent>(_ value: T, into archetype: Archetype, expectedRow: Int)
  {
    let column = archetype.ensureColumn(T.self, factory: columnFactory(for: T.self))
    let row = column.append(value)
    // Every column grows in lockstep with the entity row; if this ever fires,
    // a column got out of sync with its archetype's entity list.
    assert(row == expectedRow, "Lattice: column row \(row) diverged from entity row \(expectedRow) for \(T.self).")
    column.stamp(row, tick: currentTick)
  }

  /// Reserves an entity handle (recycling a freed index when possible)
  /// without placing it in any archetype. Callers must append its row.
  private func allocateEntity() -> LatticeEntity
  {
    if let recycled = freeIndices.popLast()
    {
      return LatticeEntity(index: recycled, generation: generations[Int(recycled)])
    }
    let index = UInt32(generations.count)
    generations.append(0)
    return LatticeEntity(index: index, generation: 0)
  }

  public func despawn(_ entity: LatticeEntity)
  {
    guard isAlive(entity), let location = locations[entity.index] else { return }
    if let moved = archetypes[location.archetypeIndex].removeRow(location.row)
    {
      locations[moved.index] = location
    }
    locations.removeValue(forKey: entity.index)
    generations[Int(entity.index)] &+= 1
    freeIndices.append(entity.index)
  }

  public func isAlive(_ entity: LatticeEntity) -> Bool
  {
    guard Int(entity.index) < generations.count else { return false }
    return generations[Int(entity.index)] == entity.generation
  }

  /// Total number of live entities across every archetype.
  public var entityCount: Int
  {
    generations.count - freeIndices.count
  }

  // MARK: - Components

  public func has(_ type: (some LatticeComponent).Type, on entity: LatticeEntity) -> Bool
  {
    guard isAlive(entity), let location = locations[entity.index] else { return false }
    return archetypes[location.archetypeIndex].signature.contains(ObjectIdentifier(type))
  }

  public func get<T: LatticeComponent>(_ type: T.Type, for entity: LatticeEntity) -> T?
  {
    guard isAlive(entity), let location = locations[entity.index] else { return nil }
    return archetypes[location.archetypeIndex].column(type)?.get(location.row)
  }

  /// Sets `component` on `entity`. If `entity` already has a value of type
  /// `T`, this simply overwrites it in place. Otherwise, `entity` is moved
  /// into the archetype for its old signature plus `T`.
  public func set<T: LatticeComponent>(_ component: T, on entity: LatticeEntity)
  {
    ensureRegistered(T.self)
    setValue(component, typeID: ObjectIdentifier(T.self), on: entity)
  }

  /// Shared body of ``set(_:on:)`` and ``setDynamic(_:forKey:on:)``: writes
  /// `component` into the column identified by `typeID`, overwriting in place
  /// if the entity's archetype already has that column, otherwise moving the
  /// entity into the archetype that adds it. The caller must have registered a
  /// column factory and copier for `typeID` first.
  private func setValue<T: LatticeComponent>(_ component: T, typeID: ComponentTypeID, on entity: LatticeEntity)
  {
    guard isAlive(entity), let location = locations[entity.index] else { return }
    let currentArchetype = archetypes[location.archetypeIndex]

    if currentArchetype.signature.contains(typeID)
    {
      if let column: any TypedColumnStorage<T> = currentArchetype.column(id: typeID)
      {
        column.set(location.row, component)
        column.stamp(location.row, tick: currentTick)
      }
      return
    }

    let factory = columnFactories[typeID] ?? { TypedColumn<T>() }
    moveEntity(entity, from: location, addingSignature: typeID)
    { newArchetype in
      let column: any TypedColumnStorage<T> = newArchetype.ensureColumn(id: typeID, factory: factory)
      let row = column.append(component)
      column.stamp(row, tick: self.currentTick)
    }
  }

  // MARK: - Dynamic (runtime-named) columns

  /// Sets a value in the column named `key`, creating that column on first use.
  ///
  /// This is the runtime-named counterpart to ``set(_:on:)``: where `set` keys
  /// the column on the Swift type `T`, this keys it on a string. A source whose
  /// schema is only known at runtime - the attributes on a `UsdStage`, say -
  /// can then land each named field in its own dense column (one column per
  /// name, the entity as the row), exactly the layout a static component gets
  /// and the same layout Fabric uses to mirror a stage. Every value written
  /// under the same `key` must share the element type `T`.
  public func setDynamic<T: LatticeComponent>(_ value: T, forKey key: String, on entity: LatticeEntity)
  {
    let typeID = dynamicTypeID(for: key)
    ensureRegisteredDynamic(T.self, typeID: typeID)
    setValue(value, typeID: typeID, on: entity)
  }

  /// Reads the value in the column named `key` for `entity`, or `nil` if it has
  /// none. The runtime-named counterpart to ``get(_:for:)``.
  public func getDynamic<T: LatticeComponent>(_: T.Type, forKey key: String, for entity: LatticeEntity) -> T?
  {
    guard let token = dynamicColumnKeys[key],
          isAlive(entity), let location = locations[entity.index]
    else { return nil }
    let column: (any TypedColumnStorage<T>)? = archetypes[location.archetypeIndex].column(id: ObjectIdentifier(token))
    return column?.get(location.row)
  }

  /// The interned ``ComponentTypeID`` for a dynamic column name, minting a
  /// stable token on first use so the id is identical every later time the same
  /// name is set or read.
  private func dynamicTypeID(for key: String) -> ComponentTypeID
  {
    if let token = dynamicColumnKeys[key]
    {
      return ObjectIdentifier(token)
    }
    let token = DynamicColumnKey()
    dynamicColumnKeys[key] = token
    return ObjectIdentifier(token)
  }

  /// Registers the column factory and archetype-move copier for a dynamic
  /// column id the first time it's seen - the runtime-named analogue of
  /// ``register(_:columnFactory:)``, keyed on the interned id instead of
  /// `ObjectIdentifier(T.self)` and reading/writing its column by that id.
  private func ensureRegisteredDynamic<T: LatticeComponent>(_: T.Type, typeID: ComponentTypeID)
  {
    guard columnFactories[typeID] == nil else { return }
    let factory: () -> any ColumnStorage = { TypedColumn<T>() }
    columnFactories[typeID] = factory
    componentCopiers[typeID] = { oldArchetype, row, newArchetype in
      guard let source: any TypedColumnStorage<T> = oldArchetype.column(id: typeID) else { return }
      let destination: any TypedColumnStorage<T> = newArchetype.ensureColumn(id: typeID, factory: factory)
      _ = destination.appendPreservingTick(source.get(row), tick: source.changeTick(at: row))
    }
  }

  /// Removes any value of type `T` from `entity`, moving it back to the
  /// archetype for its remaining components. No-op if `entity` never had
  /// one.
  public func remove(_ type: (some LatticeComponent).Type, from entity: LatticeEntity)
  {
    guard isAlive(entity), let location = locations[entity.index] else { return }
    let currentArchetype = archetypes[location.archetypeIndex]
    let typeID = ObjectIdentifier(type)
    guard currentArchetype.signature.contains(typeID) else { return }

    moveEntity(entity, from: location, removingSignature: typeID, skipValueFor: typeID)
  }

  // MARK: - Queries

  /// Every archetype whose signature is a superset of `required` - i.e.
  /// every archetype whose entities have at least these component types.
  /// `Query1`/`Query2` (see Query.swift) iterate the columns of the
  /// archetypes returned here directly, which is what keeps bulk
  /// iteration cache-friendly: no per-entity dictionary lookups, no
  /// branching on "does this entity actually have this component".
  func matchingArchetypes(required: Set<ComponentTypeID>) -> [Archetype]
  {
    matchingArchetypes(required: required, excluded: [])
  }

  /// Every archetype whose signature is a superset of `required` **and**
  /// contains none of `excluded`. The exclusion set is how a query says
  /// "entities with A but *without* B" - the standard ECS negative filter,
  /// useful for tag-style opt-outs (a `Disabled`/`Hidden` marker component).
  func matchingArchetypes(required: Set<ComponentTypeID>, excluded: Set<ComponentTypeID>) -> [Archetype]
  {
    guard let anchor = required.first
    else
    {
      return excluded.isEmpty ? archetypes : archetypes.filter { $0.signature.isDisjoint(with: excluded) }
    }

    // Start from the archetypes that at least contain one required type
    // (the rarest would be ideal; the first is a cheap approximation), then
    // confirm each is a full superset and holds none of the excluded types.
    guard let candidates = archetypeIndicesByComponent[anchor] else { return [] }
    return candidates.compactMap
    { index in
      let archetype = archetypes[index]
      guard archetype.signature.isSuperset(of: required),
            archetype.signature.isDisjoint(with: excluded)
      else { return nil }
      return archetype
    }
  }

  // MARK: - Internal archetype management

  private func archetypeIndex(for signature: Set<ComponentTypeID>) -> Int
  {
    if let existing = archetypeIndexBySignature[signature]
    {
      return existing
    }
    let archetype = Archetype(signature: signature)
    archetypes.append(archetype)
    let index = archetypes.count - 1
    archetypeIndexBySignature[signature] = index
    for typeID in signature
    {
      archetypeIndicesByComponent[typeID, default: []].append(index)
    }
    return index
  }

  /// Shared implementation for the "add a component type" and "remove a
  /// component type" structural changes. Both need to: compute the new
  /// signature, find or create that archetype, copy every shared column's
  /// value across (skipping the type being removed, if any), swap-remove
  /// the old row, and fix up the location table for both `entity` and
  /// whichever entity got swapped into its old row.
  private func moveEntity(
    _ entity: LatticeEntity,
    from location: Location,
    addingSignature added: ComponentTypeID? = nil,
    removingSignature removed: ComponentTypeID? = nil,
    skipValueFor skipType: ComponentTypeID? = nil,
    populateNewColumn: ((Archetype) -> Void)? = nil
  )
  {
    let oldArchetype = archetypes[location.archetypeIndex]
    var newSignature = oldArchetype.signature
    if let added { newSignature.insert(added) }
    if let removed { newSignature.remove(removed) }

    let newArchetypeIndex = archetypeIndex(for: newSignature)
    let newArchetype = archetypes[newArchetypeIndex]

    for typeID in oldArchetype.signature where typeID != skipType
    {
      guard let copier = componentCopiers[typeID]
      else
      {
        assertionFailure("Lattice: no copier registered for a component type already in use. This should not happen if every type was registered before first use.")
        continue
      }
      copier(oldArchetype, location.row, newArchetype)
    }

    let newRow = newArchetype.appendEntityRow(entity)
    populateNewColumn?(newArchetype)

    if let moved = oldArchetype.removeRow(location.row)
    {
      locations[moved.index] = location
    }
    locations[entity.index] = Location(archetypeIndex: newArchetypeIndex, row: newRow)
  }
}
