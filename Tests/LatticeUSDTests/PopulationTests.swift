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
import LatticeCore
import LatticeUSD
import OpenUSDKit
import Testing

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

  /// `String.hashValue` is sound *here only* because nothing in this fake ever
  /// derives a key from an `SdfPath` - both sides of the bind/query pair are
  /// strings, so the key trivially agrees with itself. `USDStageSource` must use
  /// `SdfPath(path).GetHash()`, which is what `LatticeXformSource` derives at
  /// runtime from the `SdfPath` Hydra hands it. Copying this implementation into
  /// a real conformance would leave the runtime read path unable to find any
  /// prim, silently.
  func lookupKey(for path: String) -> Int
  {
    path.hashValue
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
    attributes[path]?.keys.sorted() ?? []
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

/// Decodes the `.float3` a `Transform` is mirrored from. Shared by every test
/// that populates or writes back transforms.
private func decodeTransform(_ value: LatticeUSDValue) -> Transform?
{
  guard case let .float3(x, y, z) = value else { return nil }
  return Transform(x: x, y: y, z: z)
}

@Suite("USD population")
struct PopulationTests
{
  /// OpenUSD resolves its plugins/schemas from `plugInfo.json` files that must
  /// be registered before any USD API is touched, and the real-stage tests below
  /// open a live `UsdStage`.
  ///
  /// `Pixar.Bundler.shared.setup(.resources)` can't be used from a test target:
  /// it locates the `swift-usd_*` resource bundles relative to
  /// `Bundle.main.resourcePath`, which in a test process is the runner, not the
  /// directory SwiftPM copies those bundles into. Instead we find the bundles
  /// ourselves - they sit next to (or inside) the test bundle - and hand each
  /// one's `plugInfo.json` directory straight to USD's `PlugRegistry`, which is
  /// the same registration `Bundler` ultimately performs.
  private static let usdPluginsRegistered: Void = registerUSDPlugins()

  init()
  {
    _ = Self.usdPluginsRegistered
  }

  private static func registerUSDPlugins()
  {
    let fm = FileManager.default
    let testBundle = Bundle(for: BundleAnchor.self)
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

  /// `Bundle(for:)` needs a class to locate the test bundle, and a swift-testing
  /// suite is a struct - so this exists purely as something to point it at.
  private final class BundleAnchor {}

  // MARK: - Population, against a fake source

  @Test("syncAll binds exactly one entity per prim, and is idempotent")
  func syncAllBindsOneEntityPerPrim() throws
  {
    let store = LatticeStore()
    let paths = LatticePathTable(framePhase: store.framePhase)
    let source = FakeStageSource(attributes: [
      "/root": [:],
      "/root/childA": [:],
      "/root/childB": [:],
    ])
    let sync = USDPopulationSync(store: store, paths: paths, source: source)

    sync.syncAll()

    #expect(store.entityCount == 3)
    #expect(paths.count == 3)
    #expect(paths.entity(for: "/root/childA") != nil)

    // Re-running is idempotent: already-bound prims are not re-spawned.
    sync.syncAll()
    #expect(store.entityCount == 3)
  }

  @Test("populate reads a float3 into a component, skipping prims without the attribute")
  func populateReadsFloat3IntoComponent() throws
  {
    let store = LatticeStore()
    store.register(Transform.self)
    let paths = LatticePathTable(framePhase: store.framePhase)
    let source = FakeStageSource(attributes: [
      "/a": ["xformOp:translate": .float3(1, 2, 3)],
      "/b": ["xformOp:translate": .float3(4, 5, 6)],
      "/c": [:], // no translate authored - should be skipped
    ])
    let sync = USDPopulationSync(store: store, paths: paths, source: source)
    sync.syncAll()

    let populated = sync.populate(Transform.self, from: "xformOp:translate", decode: decodeTransform)
    #expect(populated == 2)

    let entityA = try #require(paths.entity(for: "/a"))
    let entityC = try #require(paths.entity(for: "/c"))
    #expect(store.get(Transform.self, for: entityA) == Transform(x: 1, y: 2, z: 3))
    #expect(store.has(Transform.self, on: entityC) == false)
  }

  @Test("prefetch brings in only the prims carrying a requested attribute")
  func prefetchBringsInOnlyPrimsCarryingRequestedAttributes() throws
  {
    let store = LatticeStore()
    let paths = LatticePathTable(framePhase: store.framePhase)
    let source = FakeStageSource(attributes: [
      "/mesh": ["points": .float3Array([LatticeFloat3(0, 0, 0)]), "displayColor": .float3(1, 1, 1)],
      "/xform": ["xformOp:translate": .float3(1, 2, 3)],
      "/other": ["custom:tag": .string("ignored")], // none requested -> never enters
    ])
    let sync = USDPopulationSync(store: store, paths: paths, source: source)

    // Prefetch only transforms and points - the working set, not everything.
    let stats = sync.prefetch { name in
      name.hasPrefix("xformOp:") || name == "points"
    }

    // Two attributes mirrored, across the two prims that carry them.
    #expect(stats.mirrored == 2)
    #expect(store.entityCount == 2)

    // The prim carrying none of the requested attributes never got an entity.
    #expect(paths.entity(for: "/other") == nil)
    #expect(paths.entity(for: "/mesh") != nil)
    #expect(paths.entity(for: "/xform") != nil)

    // Only the requested attribute was mirrored on /mesh - displayColor was not.
    let mesh = try #require(paths.entity(for: "/mesh"))
    #expect(
      store.getDynamic(LatticeUSDValue.self, forKey: "points", for: mesh)
        == .float3Array([LatticeFloat3(0, 0, 0)])
    )
    #expect(store.getDynamic(LatticeUSDValue.self, forKey: "displayColor", for: mesh) == nil)
  }

  @Test("prefetch bins byte-identical array payloads onto one shared buffer")
  func prefetchBinsIdenticalArrayPayloads() throws
  {
    // Three "instances" of the same geometry - identical points arrays, the
    // way USD resolves a referenced mesh on every prim composed from it - plus
    // one prim with distinct geometry and one scalar (never binned).
    let sharedPoints: LatticeUSDValue = .float3Array([LatticeFloat3(1, 2, 3), LatticeFloat3(4, 5, 6)])
    let store = LatticeStore()
    let paths = LatticePathTable(framePhase: store.framePhase)
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
    #expect(stats == .init(mirrored: 5, uniqueArrays: 2, sharedArrays: 2))

    // Binning must not change what any entity reads back.
    let instC = try #require(paths.entity(for: "/instC"))
    #expect(store.getDynamic(LatticeUSDValue.self, forKey: "points", for: instC) == sharedPoints)
  }

  @Test("syncIncremental spawns and despawns only the delta, clearing both indices")
  func syncIncrementalSpawnsAndDespawnsOnlyTheDelta() throws
  {
    let store = LatticeStore()
    let paths = LatticePathTable(framePhase: store.framePhase)
    let source = FakeStageSource(attributes: ["/a": [:], "/b": [:]])
    let sync = USDPopulationSync(store: store, paths: paths, source: source)

    // Baseline.
    let first = sync.syncIncremental()
    #expect(first == .init(added: 2, removed: 0))
    #expect(store.entityCount == 2)
    let entityA = try #require(paths.entity(for: "/a"))

    // Stage gains /c and loses /b.
    source.attributes["/c"] = [:]
    source.attributes["/b"] = nil

    let second = sync.syncIncremental()
    #expect(second == .init(added: 1, removed: 1))
    #expect(store.entityCount == 2)
    #expect(paths.entity(for: "/b") == nil)
    #expect(paths.entity(for: "/c") != nil)

    // The *lookup-key* index must be cleared too, not just the string one: a
    // stale key would resolve to a recycled entity handle rather than nothing,
    // which is worse than a miss.
    #expect(paths.entity(forLookupKey: source.lookupKey(for: "/b")) == nil)

    // Untouched prim keeps its original entity handle.
    #expect(paths.entity(for: "/a") == entityA)

    // No change -> no work.
    #expect(sync.syncIncremental().isEmpty)
  }

  @Test("writeBackChanged pushes only the components that changed since the tick")
  func writeBackChangedPushesOnlyChangedComponents() throws
  {
    let store = LatticeStore()
    let paths = LatticePathTable(framePhase: store.framePhase)
    let source = FakeStageSource(attributes: [
      "/a": ["xformOp:translate": .float3(0, 0, 0)],
      "/b": ["xformOp:translate": .float3(0, 0, 0)],
    ])
    let sync = USDPopulationSync(store: store, paths: paths, source: source)
    sync.syncAll()
    sync.populate(Transform.self, from: "xformOp:translate", decode: decodeTransform)

    // Checkpoint, then mutate only /a's transform.
    let checkpoint = store.currentTick
    store.advanceChangeTick()
    let entityA = try #require(paths.entity(for: "/a"))
    store.set(Transform(x: 1, y: 2, z: 3), on: entityA)

    let written = sync.writeBackChanged(Transform.self, to: "xformOp:translate", since: checkpoint)
    { .float3($0.x, $0.y, $0.z) }

    // Only the changed entity is authored back to the stage.
    #expect(written == 1)
    #expect(source.written["/a"]?["xformOp:translate"] == .float3(1, 2, 3))
    #expect(source.written["/b"] == nil)
  }

  // MARK: - Frame phase

  @Test("a full mutate -> tick -> read -> end cycle completes and leaves the phase mutable")
  func framePhaseCycleCompletes() throws
  {
    let store = LatticeStore()
    let paths = LatticePathTable(framePhase: store.framePhase)
    let source = FakeStageSource(attributes: ["/a": ["xformOp:translate": .float3(1, 2, 3)]])
    let sync = USDPopulationSync(store: store, paths: paths, source: source)

    // ── mutation phase ──
    #expect(store.framePhase.current == .mutable)
    sync.syncAll()
    sync.populate(Transform.self, from: "xformOp:translate", decode: decodeTransform)
    store.advanceChangeTick()

    // ── read phase ──
    store.framePhase.beginReadPhase()
    #expect(store.framePhase.current == .readable)

    // Reads must stay legal here - this is what GetPrim() does, once per prim
    // per frame. If a phase assertion ever landed on the read path by mistake,
    // this is what would catch it.
    let entity = try #require(paths.entity(forLookupKey: source.lookupKey(for: "/a")))
    #expect(store.get(Transform.self, for: entity) == Transform(x: 1, y: 2, z: 3))

    store.framePhase.endReadPhase()

    // Must return to .mutable, or the *next* frame's mutation traps - one frame
    // away from the actual cause.
    #expect(store.framePhase.current == .mutable)
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

  /// The load-bearing invariant of the whole lookup-key scheme, and the one whose
  /// failure is *silent*.
  ///
  /// Population binds with a key derived from a path **string**
  /// (`USDPopulationSync` -> `USDStageSource.lookupKey(for:)`). The Hydra read
  /// path queries with a key derived from an **`SdfPath`**
  /// (`LatticeXformSource.getLiveXform` -> `path.GetHash()`). Those are different
  /// call sites in different modules; if they ever stop agreeing, every lookup
  /// misses, Lattice quietly overrides nothing, and not one thing errors.
  @Test("the population-side lookup key agrees with the SdfPath-derived runtime key")
  func lookupKeyAgreesAcrossStringAndSdfPathDerivation()
  {
    let stage = makeStage(definingPrims: ["/root/childA"])
    let source = USDStageSource(stage: stage)

    #expect(source.lookupKey(for: "/root/childA") == SdfPath("/root/childA").GetHash())
  }

  @Test("primPaths follows depth-first traversal order, excluding the pseudo-root")
  func realSourcePrimPathsFollowTraversalOrder()
  {
    let stage = makeStage(definingPrims: ["/root", "/root/childA", "/root/childB"])
    let source = USDStageSource(stage: stage)

    #expect(source.primPaths() == ["/root", "/root/childA", "/root/childB"])
  }

  @Test("scalar attribute types read back through the real source")
  func realSourceReadsScalarAttributeTypes()
  {
    let stage = makeStage(definingPrims: ["/p"])
    let prim = stage.getPrim(at: "/p")
    prim.createAttribute(name: "size", typeName: .double, custom: true)?.set(2.5)
    prim.createAttribute(name: "visible", typeName: .bool, custom: true)?.set(true)
    prim.createAttribute(name: "label", typeName: .string, custom: true)?.set("hello")

    let source = USDStageSource(stage: stage)

    #expect(source.attributeValue(at: "/p", attribute: "size") == .double(2.5))
    #expect(source.attributeValue(at: "/p", attribute: "visible") == .bool(true))
    #expect(source.attributeValue(at: "/p", attribute: "label") == .string("hello"))
  }

  @Test("a roled float3 (point3f) maps through the same GfVec3f path as float3")
  func realSourceReadsFloat3AndRoledVariants()
  {
    let stage = makeStage(definingPrims: ["/p"])
    let prim = stage.getPrim(at: "/p")
    prim.createAttribute(name: "xformOp:translate", typeName: .float3, custom: false)?
      .set(GfVec3f(1, 2, 3))
    prim.createAttribute(name: "points", typeName: .point3f, custom: true)?
      .set(GfVec3f(4, 5, 6))

    let source = USDStageSource(stage: stage)

    #expect(source.attributeValue(at: "/p", attribute: "xformOp:translate") == .float3(1, 2, 3))
    #expect(source.attributeValue(at: "/p", attribute: "points") == .float3(4, 5, 6))
  }

  @Test("double3 is narrowed to float3 on the way in")
  func realSourceReadsDouble3AsFloat3()
  {
    let stage = makeStage(definingPrims: ["/p"])
    stage.getPrim(at: "/p")
      .createAttribute(name: "xformOp:translate", typeName: .double3, custom: false)?
      .set(GfVec3d(7, 8, 9))

    let source = USDStageSource(stage: stage)

    #expect(source.attributeValue(at: "/p", attribute: "xformOp:translate") == .float3(7, 8, 9))
  }

  /// Arrays come back as zero-copy views over the VtArray's own buffer (via
  /// `Overlay.cdata`), so this proves the packed `LatticeFloat3` layout reads
  /// the right elements, the boxed handle keeps the buffer alive after `Get`
  /// returns, and content equality is indistinguishable from an owned copy.
  @Test("float3[] reads back as a zero-copy view with correct element layout")
  func realSourceReadsFloat3ArrayAsZeroCopyView() throws
  {
    let stage = makeStage(definingPrims: ["/mesh"])
    let prim = stage.getPrim(at: "/mesh")
    var points = Pixar.VtVec3fArray()
    points.push_back(GfVec3f(1, 2, 3))
    points.push_back(GfVec3f(4, 5, 6))
    let attribute = try #require(prim.createAttribute(name: "points", typeName: .point3fArray, custom: true))
    #expect(attribute.Set(points, UsdTimeCode.Default()))

    let source = USDStageSource(stage: stage)
    let value = try #require(source.attributeValue(at: "/mesh", attribute: "points"))

    guard case let .float3Array(view) = value
    else
    {
      Issue.record("expected .float3Array, got \(value)")
      return
    }

    // The 12-byte packed element must land every component, not just index 0.
    #expect(view.count == 2)
    #expect(view[0] == LatticeFloat3(1, 2, 3))
    #expect(view[1] == LatticeFloat3(4, 5, 6))

    // Backing must be invisible: a zero-copy view equals an owned literal.
    #expect(value == .float3Array([LatticeFloat3(1, 2, 3), LatticeFloat3(4, 5, 6)]))
  }

  @Test("a missing prim, missing attribute, or unauthored value all read as nil")
  func realSourceReturnsNilForMissingPrimAttributeOrValue()
  {
    let stage = makeStage(definingPrims: ["/p"])
    // Declared but never authored and has no fallback -> no value.
    stage.getPrim(at: "/p").createAttribute(name: "unset", typeName: .double, custom: true)

    let source = USDStageSource(stage: stage)

    #expect(source.attributeValue(at: "/missing", attribute: "size") == nil)
    #expect(source.attributeValue(at: "/p", attribute: "nope") == nil)
    #expect(source.attributeValue(at: "/p", attribute: "unset") == nil)
  }

  @Test("setAttributeValue authors onto the stage and overwrites on re-author")
  func realSourceSetAttributeValueRoundTrips()
  {
    let stage = makeStage(definingPrims: ["/p"])
    // The attribute must already exist; setAttributeValue authors, not creates.
    stage.getPrim(at: "/p").createAttribute(name: "xformOp:translate", typeName: .float3, custom: false)

    let source = USDStageSource(stage: stage)

    #expect(source.setAttributeValue(.float3(1, 2, 3), at: "/p", attribute: "xformOp:translate"))
    #expect(source.attributeValue(at: "/p", attribute: "xformOp:translate") == .float3(1, 2, 3))

    #expect(source.setAttributeValue(.float3(9, 9, 9), at: "/p", attribute: "xformOp:translate"))
    #expect(source.attributeValue(at: "/p", attribute: "xformOp:translate") == .float3(9, 9, 9))
  }

  /// The write path is the read path's type mapping in reverse: `.int` must
  /// coerce to the attribute's exact int width, and array values must build
  /// the exact VtArray type. Round-tripping through a live stage proves both
  /// directions agree.
  @Test("int widths narrow and arrays build the exact VtArray type on write-back")
  func realSourceSetAttributeValueRoundTripsWidthsAndArrays() throws
  {
    let stage = makeStage(definingPrims: ["/p"])
    let prim = stage.getPrim(at: "/p")
    prim.createAttribute(name: "count", typeName: .int, custom: true)
    prim.createAttribute(name: "points", typeName: .point3fArray, custom: true)

    let source = USDStageSource(stage: stage)

    // `.int` carries Int64; the attribute is 32-bit `int` - Set must narrow.
    #expect(source.setAttributeValue(.int(7), at: "/p", attribute: "count"))
    #expect(source.attributeValue(at: "/p", attribute: "count") == .int(7))

    // An owned array value authors a VtVec3fArray and reads back as an
    // (equal-by-content) zero-copy view.
    let points: LatticeUSDValue = .float3Array([LatticeFloat3(1, 2, 3), LatticeFloat3(4, 5, 6)])
    #expect(source.setAttributeValue(points, at: "/p", attribute: "points"))
    #expect(source.attributeValue(at: "/p", attribute: "points") == points)
  }

  @Test("setAttributeValue fails for a missing prim or a missing attribute")
  func realSourceSetAttributeValueFailsForMissingPrimOrAttribute()
  {
    let stage = makeStage(definingPrims: ["/p"])
    let source = USDStageSource(stage: stage)

    #expect(source.setAttributeValue(.double(1), at: "/missing", attribute: "size") == false)
    #expect(source.setAttributeValue(.double(1), at: "/p", attribute: "size") == false)
  }

  /// End-to-end: the same population/write-back loop the `FakeStageSource`
  /// tests exercise, but driven by the real OpenUSDKit-backed source against a
  /// live stage - proving the C++-interop read/write path wires up correctly.
  @Test("population sync drives a real stage end to end")
  func populationSyncDrivesRealStageEndToEnd() throws
  {
    let stage = makeStage(definingPrims: ["/a", "/b"])
    for path in ["/a", "/b"]
    {
      stage.getPrim(at: path).createAttribute(name: "xformOp:translate", typeName: .float3, custom: false)
    }
    stage.getPrim(at: "/a").attribute(named: "xformOp:translate")?.set(GfVec3f(1, 2, 3))
    stage.getPrim(at: "/b").attribute(named: "xformOp:translate")?.set(GfVec3f(4, 5, 6))

    let store = LatticeStore()
    let paths = LatticePathTable(framePhase: store.framePhase)
    let source = USDStageSource(stage: stage)
    let sync = USDPopulationSync(store: store, paths: paths, source: source)

    sync.syncAll()
    #expect(store.entityCount == 2)

    let populated = sync.populate(Transform.self, from: "xformOp:translate", decode: decodeTransform)
    #expect(populated == 2)

    // Look the entity up the way the *runtime* does - through an SdfPath-derived
    // key - not the way population bound it. Anything else would only prove
    // lookupKey agrees with itself.
    let entityA = try #require(paths.entity(forLookupKey: SdfPath("/a").GetHash()))
    #expect(store.get(Transform.self, for: entityA) == Transform(x: 1, y: 2, z: 3))

    // Mutate one entity in the store, then push only the change back onto USD.
    let checkpoint = store.currentTick
    store.advanceChangeTick()
    store.set(Transform(x: 10, y: 20, z: 30), on: entityA)

    let written = sync.writeBackChanged(Transform.self, to: "xformOp:translate", since: checkpoint)
    { .float3($0.x, $0.y, $0.z) }
    #expect(written == 1)

    // The authored value is visible when the stage is read back directly.
    #expect(source.attributeValue(at: "/a", attribute: "xformOp:translate") == .float3(10, 20, 30))
    #expect(source.attributeValue(at: "/b", attribute: "xformOp:translate") == .float3(4, 5, 6))
  }
}
