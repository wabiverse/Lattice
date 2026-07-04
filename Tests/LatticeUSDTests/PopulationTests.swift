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
import LatticeUSD
import XCTest

/// A `USDStageSource` with no USD behind it - just canned paths and attribute
/// values - so the population layer can be exercised without opening a real
/// stage. `OpenUSDStageSource` is the production conformance; this proves the
/// store-facing half (`syncAll` + `populate`) in isolation.
private final class FakeStageSource: USDStageSource
{
  var attributes: [String: [String: LatticeUSDValue]]

  init(attributes: [String: [String: LatticeUSDValue]])
  {
    self.attributes = attributes
  }

  func primPaths() -> [String]
  {
    attributes.keys.sorted()
  }

  func attributeValue(at path: String, attribute name: String) -> LatticeUSDValue?
  {
    attributes[path]?[name]
  }
}

private struct Transform: LatticeComponent, Equatable
{
  var x: Float
  var y: Float
  var z: Float
}

final class PopulationTests: XCTestCase
{
  func testSyncAllBindsOneEntityPerPrim()
  {
    let store = LatticeStore()
    let paths = LatticePathTable()
    let source = FakeStageSource(attributes: [
      "/root": [:],
      "/root/childA": [:],
      "/root/childB": [:],
    ])
    let sync = USDPopulationSync(store: store, paths: paths, source: source)

    sync.syncAll()

    XCTAssertEqual(store.entityCount, 3)
    XCTAssertEqual(paths.count, 3)
    XCTAssertNotNil(paths.entity(for: "/root/childA"))

    // Re-running is idempotent: already-bound prims are not re-spawned.
    sync.syncAll()
    XCTAssertEqual(store.entityCount, 3)
  }

  func testPopulateReadsFloat3IntoComponent() throws
  {
    let store = LatticeStore()
    store.register(Transform.self)
    let paths = LatticePathTable()
    let source = FakeStageSource(attributes: [
      "/a": ["xformOp:translate": .float3(1, 2, 3)],
      "/b": ["xformOp:translate": .float3(4, 5, 6)],
      "/c": [:], // no translate authored - should be skipped
    ])
    let sync = USDPopulationSync(store: store, paths: paths, source: source)
    sync.syncAll()

    let populated = sync.populate(Transform.self, from: "xformOp:translate")
    { value in
      guard case let .float3(x, y, z) = value else { return nil }
      return Transform(x: x, y: y, z: z)
    }

    XCTAssertEqual(populated, 2)

    let entityA = try XCTUnwrap(paths.entity(for: "/a"))
    let entityC = try XCTUnwrap(paths.entity(for: "/c"))
    XCTAssertEqual(store.get(Transform.self, for: entityA), Transform(x: 1, y: 2, z: 3))
    XCTAssertFalse(store.has(Transform.self, on: entityC))
  }

  func testSyncIncrementalSpawnsAndDespawnsOnlyTheDelta() throws
  {
    let store = LatticeStore()
    let paths = LatticePathTable()
    let source = FakeStageSource(attributes: ["/a": [:], "/b": [:]])
    let sync = USDPopulationSync(store: store, paths: paths, source: source)

    // Baseline.
    let first = sync.syncIncremental()
    XCTAssertEqual(first, .init(added: 2, removed: 0))
    XCTAssertEqual(store.entityCount, 2)
    let entityA = try XCTUnwrap(paths.entity(for: "/a"))

    // Stage gains /c and loses /b.
    source.attributes["/c"] = [:]
    source.attributes["/b"] = nil

    let second = sync.syncIncremental()
    XCTAssertEqual(second, .init(added: 1, removed: 1))
    XCTAssertEqual(store.entityCount, 2)
    XCTAssertNil(paths.entity(for: "/b"))
    XCTAssertNotNil(paths.entity(for: "/c"))
    // Untouched prim keeps its original entity handle.
    XCTAssertEqual(paths.entity(for: "/a"), entityA)

    // No change -> no work.
    XCTAssertTrue(sync.syncIncremental().isEmpty)
  }
}
