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

/// Maps stable external identifiers - most importantly USD `SdfPath`
/// strings - to dense ``LatticeEntity`` handles, and back.
///
/// The store itself never needs to know about USD, paths, or strings; it
/// only deals in `LatticeEntity` values, which is what keeps its inner loop
/// fast. This table is what lets a sync layer such as `LatticeUSD` - or an
/// editor, or a save/load system - translate between "the stable name a
/// human or a file format cares about" and "the dense handle the store
/// cares about".
public final class LatticePathTable
{
  private var pathToEntity: [String: LatticeEntity] = [:]
  private var entityToPath: [LatticeEntity: String] = [:]

  public init() {}

  public func entity(for path: String) -> LatticeEntity?
  {
    pathToEntity[path]
  }

  public func path(for entity: LatticeEntity) -> String?
  {
    entityToPath[entity]
  }

  public func bind(_ entity: LatticeEntity, to path: String)
  {
    pathToEntity[path] = entity
    entityToPath[entity] = path
  }

  @discardableResult
  public func unbind(_ entity: LatticeEntity) -> String?
  {
    guard let path = entityToPath.removeValue(forKey: entity) else { return nil }
    pathToEntity.removeValue(forKey: path)
    return path
  }

  /// The number of bound path<->entity pairs.
  public var count: Int
  {
    entityToPath.count
  }

  /// Visits every bound `(entity, path)` pair. Iteration order is
  /// unspecified. This is what lets a population pass walk the entities it
  /// previously bound from a stage and pull each one's attribute values -
  /// without the store or the sync layer holding a second copy of the path
  /// list.
  public func forEachBinding(_ body: (LatticeEntity, String) -> Void)
  {
    for (entity, path) in entityToPath
    {
      body(entity, path)
    }
  }
}
