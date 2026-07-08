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

import CxxStdlib
import Foundation
import Lattice
import LatticeUSD
import OpenUSDKit
import XCTest

/// A `USDStageSource` with no USD behind it - just canned paths and attribute
/// values - so the population layer can be exercised without opening a real stage.
/// `USDStageSource` is the production conformance; this proves the store-facing
/// half (`syncAll` + `populate`) in isolation.
private final class FakeStageSource: USDStageSourceRepresentable
{
  var attributes: [String: [String: LatticeUSDValue]]
  /// Captures what `setAttributeValue` authored, for write-back assertions.
  private(set) var written: [String: [String: LatticeUSDValue]] = [:]

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

  func attributeNames(at path: String) -> [String]
  {
    (attributes[path]?.keys).map { $0.sorted() } ?? []
  }

  func setAttributeValue(_ value: LatticeUSDValue, at path: String, attribute name: String) -> Bool
  {
    written[path, default: [:]][name] = value
    return true
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
  /// OpenUSD resolves its plugins/schemas from `plugInfo.json` files that must
  /// be registered before any USD API is touched; the real-stage tests below
  /// open a live `UsdStage`, so do it once here for the whole test case.
  ///
  /// `Pixar.Bundler.shared.setup(.resources)` can't be used from a test target:
  /// it locates the `swift-usd_*` resource bundles relative to
  /// `Bundle.main.resourcePath`, which in an `xctest` process is the test
  /// runner, not the directory SwiftPM copies those bundles into. Instead we
  /// find the bundles ourselves - they sit next to (or inside) the test bundle -
  /// and hand each one's `plugInfo.json` directory straight to USD's
  /// `PlugRegistry`, which is the same registration `Bundler` ultimately does.
  override class func setUp()
  {
    super.setUp()
    registerUSDPlugins()
  }

  private static func registerUSDPlugins()
  {
    let fm = FileManager.default
    let testBundle = Bundle(for: PopulationTests.self)
    // Where the copied resource bundles might live, most-likely first.
    let roots = [
      testBundle.bundleURL.deletingLastPathComponent(), // build products dir (siblings)
      testBundle.resourceURL, // resources nested inside the test bundle
      Bundle.main.resourceURL, // where Bundler itself would have looked
    ].compactMap { $0 }

    var registered: Set<String> = []
    for root in roots
    {
      guard let entries = try? fm.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil
      )
      else { continue }

      for bundle in entries
        where bundle.lastPathComponent.hasPrefix("swift-usd_")
        && ["bundle", "resources"].contains(bundle.pathExtension)
      {
        // Register each module's bundle only once, even if it appears in
        // more than one candidate root.
        guard registered.insert(bundle.lastPathComponent).inserted else { continue }

        // plugInfo.json sits either directly in the bundle (loose SwiftPM
        // `.resources`) or under `Contents/Resources` (a macOS `.bundle`).
        let nested = bundle.appendingPathComponent("Contents/Resources")
        let dir = fm.fileExists(atPath: nested.appendingPathComponent("plugInfo.json").path)
          ? nested : bundle
        guard fm.fileExists(atPath: dir.appendingPathComponent("plugInfo.json").path)
        else
        {
          registered.remove(bundle.lastPathComponent)
          continue
        }

        _ = Pixar.PlugRegistry.GetInstance().RegisterPlugins(std.string(dir.path))
      }
    }
  }

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

  func testPrefetchBringsInOnlyPrimsCarryingRequestedAttributes() throws
  {
    let store = LatticeStore()
    let paths = LatticePathTable()
    let source = FakeStageSource(attributes: [
      "/mesh": ["points": .float3Array([LatticeFloat3(0, 0, 0)]), "displayColor": .float3(1, 1, 1)],
      "/xform": ["xformOp:translate": .float3(1, 2, 3)],
      "/other": ["custom:tag": .string("ignored")], // none requested -> never enters
    ])
    let sync = USDPopulationSync(store: store, paths: paths, source: source)

    // Prefetch only transforms and points - the working set, not everything.
    let stats = sync.prefetch
    { name in
      name.hasPrefix("xformOp:") || name == "points"
    }

    // Two attributes mirrored, across the two prims that carry them.
    XCTAssertEqual(stats.mirrored, 2)
    XCTAssertEqual(store.entityCount, 2)

    // The prim carrying none of the requested attributes never got an entity.
    XCTAssertNil(paths.entity(for: "/other"))
    XCTAssertNotNil(paths.entity(for: "/mesh"))
    XCTAssertNotNil(paths.entity(for: "/xform"))

    // Only the requested attribute was mirrored on /mesh - displayColor was not.
    let mesh = try XCTUnwrap(paths.entity(for: "/mesh"))
    XCTAssertEqual(
      store.getDynamic(LatticeUSDValue.self, forKey: "points", for: mesh),
      .float3Array([LatticeFloat3(0, 0, 0)])
    )
    XCTAssertNil(store.getDynamic(LatticeUSDValue.self, forKey: "displayColor", for: mesh))
  }

  func testPrefetchBinsIdenticalArrayPayloads() throws
  {
    // Three "instances" of the same geometry - identical points arrays, the
    // way USD resolves a referenced mesh on every prim composed from it - plus
    // one prim with distinct geometry and one scalar (never binned).
    let sharedPoints: LatticeUSDValue = .float3Array([LatticeFloat3(1, 2, 3), LatticeFloat3(4, 5, 6)])
    let store = LatticeStore()
    let paths = LatticePathTable()
    let source = FakeStageSource(attributes: [
      "/instA": ["points": sharedPoints],
      "/instB": ["points": sharedPoints],
      "/instC": ["points": sharedPoints],
      "/unique": ["points": .float3Array([LatticeFloat3(9, 9, 9)]), "xformOp:translate": .float3(0, 0, 0)],
    ])
    let sync = USDPopulationSync(store: store, paths: paths, source: source)

    let stats = sync.prefetch { $0 == "points" || $0.hasPrefix("xformOp:") }

    // 5 values mirrored; 4 are arrays, of which 2 own buffers (the shared
    // geometry and the unique one) and 2 were binned onto the first-seen copy.
    // The scalar translate is stored inline and never enters the bins.
    XCTAssertEqual(stats, .init(mirrored: 5, uniqueArrays: 2, sharedArrays: 2))

    // Binning must not change what any entity reads back.
    let instC = try XCTUnwrap(paths.entity(for: "/instC"))
    XCTAssertEqual(store.getDynamic(LatticeUSDValue.self, forKey: "points", for: instC), sharedPoints)
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

  func testWriteBackChangedPushesOnlyChangedComponents() throws
  {
    let store = LatticeStore()
    let paths = LatticePathTable()
    let source = FakeStageSource(attributes: [
      "/a": ["xformOp:translate": .float3(0, 0, 0)],
      "/b": ["xformOp:translate": .float3(0, 0, 0)],
    ])
    let sync = USDPopulationSync(store: store, paths: paths, source: source)
    sync.syncAll()
    sync.populate(Transform.self, from: "xformOp:translate")
    { value in
      guard case let .float3(x, y, z) = value else { return nil }
      return Transform(x: x, y: y, z: z)
    }

    // Checkpoint, then mutate only /a's transform.
    let checkpoint = store.currentTick
    store.advanceChangeTick()
    let entityA = try XCTUnwrap(paths.entity(for: "/a"))
    store.set(Transform(x: 1, y: 2, z: 3), on: entityA)

    let written = sync.writeBackChanged(Transform.self, to: "xformOp:translate", since: checkpoint)
    { .float3($0.x, $0.y, $0.z) }

    // Only the changed entity is authored back to the stage.
    XCTAssertEqual(written, 1)
    XCTAssertEqual(source.written["/a"]?["xformOp:translate"], .float3(1, 2, 3))
    XCTAssertNil(source.written["/b"])
  }

  // MARK: - Real USDStageSource, backed by a live in-memory UsdStage

  /// Builds an anonymous in-memory stage and defines the given prim paths. Each
  /// path is defined explicitly so `traverse()` yields exactly this set, in a
  /// predictable depth-first order.
  private func makeStage(definingPrims paths: [String]) -> UsdStage
  {
    let stage = Usd.Stage.createInMemory()
    for path in paths
    {
      stage.definePrim(path)
    }
    return stage
  }

  func testRealSourcePrimPathsFollowTraversalOrder()
  {
    let stage = makeStage(definingPrims: ["/root", "/root/childA", "/root/childB"])
    let source = USDStageSource(stage: stage)

    // Depth-first traversal, pseudo-root excluded.
    XCTAssertEqual(source.primPaths(), ["/root", "/root/childA", "/root/childB"])
  }

  func testRealSourceReadsScalarAttributeTypes()
  {
    let stage = makeStage(definingPrims: ["/p"])
    let prim = stage.getPrim(at: "/p")
    prim.createAttribute(name: "size", typeName: .double, custom: true)?.set(2.5)
    prim.createAttribute(name: "visible", typeName: .bool, custom: true)?.set(true)
    prim.createAttribute(name: "label", typeName: .string, custom: true)?.set("hello")

    let source = USDStageSource(stage: stage)

    XCTAssertEqual(source.attributeValue(at: "/p", attribute: "size"), .double(2.5))
    XCTAssertEqual(source.attributeValue(at: "/p", attribute: "visible"), .bool(true))
    XCTAssertEqual(source.attributeValue(at: "/p", attribute: "label"), .string("hello"))
  }

  func testRealSourceReadsFloat3AndRoledVariants()
  {
    let stage = makeStage(definingPrims: ["/p"])
    let prim = stage.getPrim(at: "/p")
    prim.createAttribute(name: "xformOp:translate", typeName: .float3, custom: false)?
      .set(GfVec3f(1, 2, 3))
    // A roled float3 type (point3f) must map through the same GfVec3f path.
    prim.createAttribute(name: "points", typeName: .point3f, custom: true)?
      .set(GfVec3f(4, 5, 6))

    let source = USDStageSource(stage: stage)

    XCTAssertEqual(source.attributeValue(at: "/p", attribute: "xformOp:translate"), .float3(1, 2, 3))
    XCTAssertEqual(source.attributeValue(at: "/p", attribute: "points"), .float3(4, 5, 6))
  }

  func testRealSourceReadsDouble3AsFloat3()
  {
    let stage = makeStage(definingPrims: ["/p"])
    let prim = stage.getPrim(at: "/p")
    prim.createAttribute(name: "xformOp:translate", typeName: .double3, custom: false)?
      .set(GfVec3d(7, 8, 9))

    let source = USDStageSource(stage: stage)

    // double3 is narrowed to Float on the way into LatticeUSDValue.float3.
    XCTAssertEqual(source.attributeValue(at: "/p", attribute: "xformOp:translate"), .float3(7, 8, 9))
  }

  /// Arrays come back as zero-copy views over the VtArray's own buffer (via
  /// `Overlay.cdata`), so this proves the packed `LatticeFloat3` layout reads
  /// the right elements, the boxed handle keeps the buffer alive after `Get`
  /// returns, and content equality is indistinguishable from an owned copy.
  func testRealSourceReadsFloat3ArrayAsZeroCopyView() throws
  {
    let stage = makeStage(definingPrims: ["/mesh"])
    let prim = stage.getPrim(at: "/mesh")
    var points = Pixar.VtVec3fArray()
    points.push_back(GfVec3f(1, 2, 3))
    points.push_back(GfVec3f(4, 5, 6))
    let attribute = try XCTUnwrap(prim.createAttribute(name: "points", typeName: .point3fArray, custom: true))
    XCTAssertTrue(attribute.Set(points, UsdTimeCode.Default()))

    let source = USDStageSource(stage: stage)
    let value = try XCTUnwrap(source.attributeValue(at: "/mesh", attribute: "points"))

    guard case let .float3Array(view) = value
    else { return XCTFail("expected .float3Array, got \(value)") }

    // The 12-byte packed element must land every component, not just index 0.
    XCTAssertEqual(view.count, 2)
    XCTAssertEqual(view[0], LatticeFloat3(1, 2, 3))
    XCTAssertEqual(view[1], LatticeFloat3(4, 5, 6))

    // Backing must be invisible: a zero-copy view equals an owned literal.
    XCTAssertEqual(value, .float3Array([LatticeFloat3(1, 2, 3), LatticeFloat3(4, 5, 6)]))
  }

  func testRealSourceReturnsNilForMissingPrimAttributeOrValue()
  {
    let stage = makeStage(definingPrims: ["/p"])
    // Declared but never authored and has no fallback -> no value.
    stage.getPrim(at: "/p").createAttribute(name: "unset", typeName: .double, custom: true)

    let source = USDStageSource(stage: stage)

    XCTAssertNil(source.attributeValue(at: "/missing", attribute: "size"))
    XCTAssertNil(source.attributeValue(at: "/p", attribute: "nope"))
    XCTAssertNil(source.attributeValue(at: "/p", attribute: "unset"))
  }

  func testRealSourceSetAttributeValueRoundTrips()
  {
    let stage = makeStage(definingPrims: ["/p"])
    // The attribute must already exist; setAttributeValue authors, not creates.
    stage.getPrim(at: "/p").createAttribute(name: "xformOp:translate", typeName: .float3, custom: false)

    let source = USDStageSource(stage: stage)

    XCTAssertTrue(source.setAttributeValue(.float3(1, 2, 3), at: "/p", attribute: "xformOp:translate"))
    XCTAssertEqual(source.attributeValue(at: "/p", attribute: "xformOp:translate"), .float3(1, 2, 3))

    // Authoring again overwrites the prior value.
    XCTAssertTrue(source.setAttributeValue(.float3(9, 9, 9), at: "/p", attribute: "xformOp:translate"))
    XCTAssertEqual(source.attributeValue(at: "/p", attribute: "xformOp:translate"), .float3(9, 9, 9))
  }

  func testRealSourceSetAttributeValueFailsForMissingPrimOrAttribute()
  {
    let stage = makeStage(definingPrims: ["/p"])
    let source = USDStageSource(stage: stage)

    // No prim at path, and an existing prim without the named attribute.
    XCTAssertFalse(source.setAttributeValue(.double(1), at: "/missing", attribute: "size"))
    XCTAssertFalse(source.setAttributeValue(.double(1), at: "/p", attribute: "size"))
  }

  /// End-to-end: the same population/write-back loop the `FakeStageSource`
  /// tests exercise, but driven by the real OpenUSDKit-backed source against a
  /// live stage - proving the C++-interop read/write path wires up correctly.
  func testPopulationSyncDrivesRealStageEndToEnd() throws
  {
    let stage = makeStage(definingPrims: ["/a", "/b"])
    for path in ["/a", "/b"]
    {
      stage.getPrim(at: path).createAttribute(name: "xformOp:translate", typeName: .float3, custom: false)
    }
    stage.getPrim(at: "/a").attribute(named: "xformOp:translate")?.set(GfVec3f(1, 2, 3))
    stage.getPrim(at: "/b").attribute(named: "xformOp:translate")?.set(GfVec3f(4, 5, 6))

    let store = LatticeStore()
    let paths = LatticePathTable()
    let source = USDStageSource(stage: stage)
    let sync = USDPopulationSync(store: store, paths: paths, source: source)

    sync.syncAll()
    XCTAssertEqual(store.entityCount, 2)

    let populated = sync.populate(Transform.self, from: "xformOp:translate")
    { value in
      guard case let .float3(x, y, z) = value else { return nil }
      return Transform(x: x, y: y, z: z)
    }
    XCTAssertEqual(populated, 2)

    let entityA = try XCTUnwrap(paths.entity(for: "/a"))
    XCTAssertEqual(store.get(Transform.self, for: entityA), Transform(x: 1, y: 2, z: 3))

    // Mutate one entity in the store, then push only the change back onto USD.
    let checkpoint = store.currentTick
    store.advanceChangeTick()
    store.set(Transform(x: 10, y: 20, z: 30), on: entityA)

    let written = sync.writeBackChanged(Transform.self, to: "xformOp:translate", since: checkpoint)
    { .float3($0.x, $0.y, $0.z) }
    XCTAssertEqual(written, 1)

    // The authored value is visible when the stage is read back directly.
    XCTAssertEqual(source.attributeValue(at: "/a", attribute: "xformOp:translate"), .float3(10, 20, 30))
    XCTAssertEqual(source.attributeValue(at: "/b", attribute: "xformOp:translate"), .float3(4, 5, 6))
  }
}
