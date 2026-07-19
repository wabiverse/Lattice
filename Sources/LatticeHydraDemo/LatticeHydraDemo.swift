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
import OpenUSDKit
import HydraKit
import LatticeCore
import LatticeUSD
import SwiftCrossUI
import lattice

/// A Hydra viewport driven by Lattice.
///
/// A hundred thousand cubes sit on a `UsdStage` that is authored once and never
/// touched again. Every frame, Lattice recomputes all hundred thousand transforms
/// in its own columnar store and publishes them to Hydra through ``LatticeHydraSceneIndex``
/// a filtering scene index that answers `GetPrim()` out of the store instead of the
/// stage.
///
/// Nothing is written back to USD. That is the point: the stage stays the
/// authoritative, composed scene description, and the per-frame motion lives
/// somewhere built for per-frame rates, exactly the split Fabric draws inside
/// Omniverse.
@main
struct LatticeHydraDemo: App
{
  typealias Backend = PlatformBackend

  let hydra: Hydra.RenderEngine
  /// Strong: `Hydra.RenderEngine.frameDelegate` is weak, so the app
  /// owns the driver. Dropping it here would stop the animation.
  let driver: any LatticeDriving
  let itemCount: Int
  let itemNoun: String

  @State var isReady: Bool = false
  @State var stats = LatticeFrameStats()
  /// Mirrors the driver's kernel so the buttons can show which one is live.
  /// The driver is the source of truth, this only drives the UI's highlight.
  @State var kernel: LatticeKernel = .ripple
  /// Mirrors `driver.notifiesHydra` for the toggle's own state.
  @State var notifies: Bool = true
  /// Mirrors `driver.activeCount` for the slider's own state.
  @State var active: Int = 0

  init()
  {
    Pixar.Bundler.shared.setup(.resources)

    let count = AppUtils.cubeCountFromArguments()
    let useGPU = !AppUtils.forcesCPUPath()
    let buildStart = CFAbsoluteTimeGetCurrent()

    // the two paths differ only in the *shape of the scene* - one prim per cube
    // versus one instancer holding them all. Store, kernel and frame contract
    // are the same either way, what changes is how many prims hydra has to be
    // told about, which is what decides the frame time at this scale.
    let stage: UsdStage
    let driver: any LatticeDriving
    let liveCount: () -> Int

    if AppUtils.usesPerPrimPath()
    {
      let scene = LatticeSceneBuilder.build(cubeCount: count, useGPU: useGPU)
      stage = scene.stage
      itemCount = scene.cubeCount
      itemNoun = "cubes (per-prim)"

      // before the engine, not after. Hydra consults the scene index registry
      // exactly once, while building the render index inside the engine's
      // constructor - registering afterwards is silently a no-op, and the
      // viewport would just show the rest pose forever.
      //
      // retained rather than unretained: the bridge holds this for the process
      // lifetime and Hydra may pull through it from threads that know nothing
      // about the app's lifetime.
      LatticeHydraRegisterSceneIndex(Unmanaged.passRetained(scene.source).toOpaque())
      driver = LatticeFrameDriver(scene: scene)
      liveCount = { Int(LatticeHydraLiveSceneIndexCount()) }
      print("[lattice] drive path: \(scene.drivePath.rawValue), scene: per-prim")
    }
    else
    {
      let scene = LatticeInstancerSceneBuilder.build(instanceCount: count, useGPU: useGPU)
      stage = scene.stage
      itemCount = scene.instanceCount
      itemNoun = "instances"

      LatticeHydraRegisterInstancerSceneIndex(Unmanaged.passRetained(scene.source).toOpaque())
      driver = LatticeInstancerDriver(scene: scene)
      liveCount = { Int(LatticeHydraLiveInstancerSceneIndexCount()) }
      print("[lattice] drive path: \(scene.drivePath.rawValue), scene: instancer")
    }

    let buildMs = (CFAbsoluteTimeGetCurrent() - buildStart) * 1000.0
    print("[lattice] authored + mirrored \(itemCount) \(itemNoun) in \(String(format: "%.0f", buildMs)) ms")

    self.hydra = Hydra.RenderEngine(stage: stage)
    self.driver = driver
    self.hydra.frameDelegate = driver

    // hides the dome from camera rays while
    // it still lights the scene (makes our
    // tiny prim cubes easier to see).
    self.hydra.getEngine().SetRendererSetting(
      Tf.Token("domeLightCameraVisibility"),
      VtValue(false)
    )

    let live = liveCount()
    print("[lattice] scene index live on \(live) render index(es)")
    if live == 0
    {
      print("[lattice] warning: nothing registered - the viewport will show the rest pose")
    }
  }

  var body: some Scene
  {
    WindowGroup("Lattice - 100k live transforms through Hydra")
    {
      Hydra.Viewport(engine: hydra)
        .frame(minWidth: 640, minHeight: 360)
        .overlay(alignment: .topLeading)
        {
          if isReady
          {
            VStack(alignment: .leading, spacing: 3)
            {
              Text("\(String(format: "%.0f", stats.framesPerSecond)) fps")
                .font(.system(size: 30, weight: .bold).monospaced())
              Text("\(itemCount) \(itemNoun)")
                .font(.system(size: 12))
                .foregroundColor(Color(white: 0.62))

              LatticeHUDRow("path", stats.drivePath)
              LatticeHUDRow("kernel", "\(stats.kernelLabel)  (\(stats.kernelCost))")
              LatticeHUDRow("xform compute", String(format: "%.2f ms", stats.mutateMilliseconds))
              LatticeHUDRow("dirty + notify", String(format: "%.2f ms", stats.notifyMilliseconds))
              LatticeHUDRow("frame", String(format: "%.2f ms", stats.frameMilliseconds))
              LatticeHUDRow("throughput",
                            String(format: "%.1f M xforms/sec",
                                   stats.transformsPerSecond / 1_000_000.0))

              if driver.supportsKernelSwitching
              {
                Text("MOTION FIELD")
                  .font(.system(size: 10, weight: .bold))
                  .foregroundColor(Color(white: 0.55))
                  .padding(.top, 8)

                HStack(spacing: 4)
                {
                  ForEach(LatticeKernel.allCases, id: \.rawValue)
                  { option in
                    Toggle(option.label, isOn: $kernel.isEqualTo(option) { selectedOption in
                      driver.kernel = selectedOption
                    })
                  }
                }
              }
              else
              {
                Text("kernel switching is instancer + gpu only")
                  .font(.system(size: 10))
                  .foregroundColor(Color(white: 0.55))
                  .padding(.top, 8)
              }

              if driver.supportsKernelSwitching
              {
                Text("LIVE INSTANCES  \(active.formatted())")
                  .font(.system(size: 10, weight: .bold))
                  .foregroundColor(Color(white: 0.55))
                  .padding(.top, 8)

                HStack(spacing: 4)
                {
                  ForEach(LatticeHydraDemo.countPresets(upTo: driver.maximumCount), id: \.self)
                  { preset in
                    Button(LatticeHydraDemo.presetLabel(preset))
                    {
                      active = preset
                      driver.activeCount = preset
                    }
                  }
                }

                Slider(
                  value: $active,
                  in: 1000 ... max(1000, driver.maximumCount)
                )
                .frame(width: 260.0)
              }

              Text("PUBLISH TO HYDRA")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Color(white: 0.55))
                .padding(.top, 8)

              Toggle("Notify", isOn: $notifies.onChange { on in
                driver.notifiesHydra = on
              })
              .toggleStyle(.switch)
            }
            .padding(14)
            .background(Color(white: 0.24, opacity: 0.62))
            .cornerRadius(10)
            .foregroundColor(Color(white: 0.96))
            .padding(16)
          }
          else
          {
            ProgressView("Loading \(itemCount) \(itemNoun)...")
          }
        }
        .task
        {
          await hydra.waitUntilSceneReady()
          active = driver.activeCount
          isReady = true

          // the driver is written from the render thread, poll a copy rather than
          // pushing from there, so the HUD never reaches into a frame in flight.
          var activeInstanceCount: Int? = nil
          var stableTicks = 0

          while !Task.isCancelled
          {
            stats = driver.snapshot()

            if active != driver.activeCount
            {
              if activeInstanceCount == active
              {
                stableTicks += 1
              }
              else
              {
                activeInstanceCount = active
                stableTicks = 0
              }

              // two ticks indicate the drag has actually ended.
              if stableTicks >= 2
              {
                driver.activeCount = active
                activeInstanceCount = nil
                stableTicks = 0
              }
            }

            try? await Task.sleep(for: .milliseconds(120))
          }
        }
    }
  }
}

/// One `label value` line of the HUD.
extension LatticeHydraDemo
{
  /// Round counts to jump between, capped at what was allocated at launch.
  static func countPresets(upTo maximum: Int) -> [Int]
  {
    let candidates = [50_000, 100_000, 250_000, 500_000, 1_000_000]
    var presets = candidates.filter { $0 < maximum }
    presets.append(maximum)
    return presets
  }

  static func presetLabel(_ count: Int) -> String
  {
    count >= 1_000_000
      ? "\(count / 1_000_000)M"
      : "\(max(1, count / 1_000))k"
  }
}

struct LatticeHUDRow: View
{
  let label: String
  let value: String

  init(_ label: String, _ value: String)
  {
    self.label = label
    self.value = value
  }

  var body: some View
  {
    HStack(spacing: 8)
    {
      Text(label)
        .font(.system(size: 11))
        .foregroundColor(Color(white: 0.6))
        .frame(width: 104.0, alignment: .leading)
      Text(value)
        .font(.system(size: 11).monospaced())
    }
  }
}

extension Binding {
  /// Passes the new value on to `onChange` after storing it.
  func onChange(_ onChange: @escaping (Value) -> Void) -> Binding<Value> {
    Binding<Value>(
      get: { self.wrappedValue },
      set: { newValue in
        self.wrappedValue = newValue
        onChange(newValue)
      }
    )
  }
}

extension Binding where Value: Equatable {
  /// Checks if the wrapped value is equal to `expectedValue`,
  /// and passes the new value on to `onChange` after storing it.
  func isEqualTo(_ expectedValue: Value, onChange: @escaping (Value) -> Void) -> Binding<Bool> {
    Binding<Bool>(
      get: { self.wrappedValue == expectedValue },
      set: { isSelected in
        if isSelected {
          self.wrappedValue = expectedValue
          onChange(expectedValue)
        }
      }
    )
  }
}
