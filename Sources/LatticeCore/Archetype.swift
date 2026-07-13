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

/// A bucket holding every entity that has exactly the same set of component
/// types, plus one densely packed ``ColumnStorage`` per component type.
///
/// This is the core performance idea borrowed from archetype-based ECS
/// designs, and the closest Lattice concept to a Fabric "bucket": because
/// every entity in an archetype shares the same component signature,
/// systems can iterate a whole archetype's columns as flat arrays with no
/// per-entity type checks or branching.
public final class Archetype
{
  /// The set of component types every entity in this archetype has.
  public let signature: Set<ComponentTypeID>

  private var entitiesStorage: [LatticeEntity] = []
  private var columns: [ComponentTypeID: any ColumnStorage] = [:]

  init(signature: Set<ComponentTypeID>)
  {
    self.signature = signature
  }

  /// Entities in this archetype, in row order. Row `i` here corresponds to
  /// index `i` in every column belonging to this archetype.
  var entities: [LatticeEntity]
  {
    entitiesStorage
  }

  var rowCount: Int
  {
    entitiesStorage.count
  }

  func column<T: LatticeComponent>(_ type: T.Type) -> (any TypedColumnStorage<T>)?
  {
    column(id: ObjectIdentifier(type))
  }

  /// Column lookup by an explicit ``ComponentTypeID`` rather than a Swift
  /// metatype. Static components key on `ObjectIdentifier(T.self)`; dynamic,
  /// runtime-named columns (see ``LatticeStore/setDynamic(_:forKey:on:)``) key
  /// on an interned per-name id - both share this one storage path.
  func column<T: LatticeComponent>(id: ComponentTypeID) -> (any TypedColumnStorage<T>)?
  {
    columns[id] as? any TypedColumnStorage<T>
  }

  /// Returns the column for `T`, creating it via `factory` if this archetype
  /// doesn't have one yet. The store passes the factory so the backing storage
  /// (plain array vs. GPU buffer) is chosen per component type, not hardcoded
  /// here.
  func ensureColumn<T: LatticeComponent>(
    _ type: T.Type,
    factory: () -> any ColumnStorage
  ) -> any TypedColumnStorage<T>
  {
    ensureColumn(id: ObjectIdentifier(type), factory: factory)
  }

  /// The create-if-absent counterpart to ``column(id:)``, keyed by an explicit
  /// id so static and dynamic columns share one code path.
  func ensureColumn<T: LatticeComponent>(
    id: ComponentTypeID,
    factory: () -> any ColumnStorage
  ) -> any TypedColumnStorage<T>
  {
    if let existing = columns[id] as? any TypedColumnStorage<T>
    {
      return existing
    }
    let created = factory()
    columns[id] = created
    guard let typed = created as? any TypedColumnStorage<T>
    else
    {
      preconditionFailure("Lattice: column factory for \(T.self) produced storage that isn't a TypedColumnStorage<\(T.self)>.")
    }
    return typed
  }

  /// Appends a new, empty row for `entity` and returns its row index.
  /// Callers are responsible for populating every column's new slot
  /// before this archetype is read again.
  @discardableResult
  func appendEntityRow(_ entity: LatticeEntity) -> Int
  {
    entitiesStorage.append(entity)
    return entitiesStorage.count - 1
  }

  /// Removes `row`, swap-filling it from the last row across every
  /// column. Returns the entity that was moved into `row`, if any, so the
  /// caller (``LatticeStore``) can update its location table.
  @discardableResult
  func removeRow(_ row: Int) -> LatticeEntity?
  {
    let lastRow = entitiesStorage.count - 1
    let movedEntity: LatticeEntity? = (row != lastRow) ? entitiesStorage[lastRow] : nil

    for column in columns.values
    {
      column.swapRemove(at: row)
    }
    if row != lastRow
    {
      entitiesStorage.swapAt(row, lastRow)
    }
    entitiesStorage.removeLast()

    return movedEntity
  }
}
