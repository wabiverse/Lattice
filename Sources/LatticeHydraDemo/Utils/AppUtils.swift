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
import HydraKit
import OpenUSDKit
import OCIOBundle
import OpenColorIO

public typealias OCIO = OpenColorIO_v2_3

#if os(Android)
  import AndroidBackend
  public typealias PlatformBackend = AndroidBackend
#elseif os(Linux)
  import GtkBackend
  public typealias PlatformBackend = GtkBackend
#elseif os(Windows)
  import WinUIBackend
  public typealias PlatformBackend = WinUIBackend
#elseif os(macOS)
  import AppKitBackend
  public typealias PlatformBackend = AppKitBackend
#else
  import UIKitBackend
  public typealias PlatformBackend = UIKitBackend
#endif

public enum AppUtils
{
  public static func usdScenePathFromArguments() -> String?
  {
    let arguments = CommandLine.arguments
    if let index = arguments.firstIndex(of: "--usd"), index + 1 < arguments.count
    {
      return arguments[index + 1]
    }
    if let path = ProcessInfo.processInfo.environment["LATTICE_USD_SCENE"], !path.isEmpty
    {
      return path
    }
    return nil
  }
  
  /// How many cubes the demo should spawn.
  ///
  /// Defaults to a hundred thousand. Worth turning down on a machine
  /// that cannot keep a hundred thousand rprims interactive - the mutation
  /// cost Lattice is being measured on scales linearly, while Hydra's per-prim
  /// sync cost is what actually falls over first.
  public static func cubeCountFromArguments() -> Int
  {
    let arguments = CommandLine.arguments
    if let index = arguments.firstIndex(of: "--count"),
       index + 1 < arguments.count,
       let parsed = Int(arguments[index + 1]), parsed > 0
    {
      return parsed
    }
    if let raw = ProcessInfo.processInfo.environment["LATTICE_CUBE_COUNT"],
       let parsed = Int(raw), parsed > 0
    {
      return parsed
    }
    return 100_000
  }

  /// Adds the dome light the demo stages need to be visible at all.
  @discardableResult
  public static func addDomeLight(to stage: UsdStage,
                                  path: String = "/World/DefaultDomeLight") -> Bool
  {
    let domeLight = UsdLux.DomeLight.define(stage, path: path)

    let texture: String? = {
      guard let hdxResources = Bundle.hdx?.resourcePath
      else
      {
        print("[lattice] no Hdx resource bundle - dome light is untextured")
        return nil
      }

      let tex = "\(hdxResources)/textures/StinsonBeach.hdr"
      guard FileManager.default.fileExists(atPath: tex)
      else
      {
        print("[lattice] dome HDR missing at \(tex) - dome light is untextured")
        return nil
      }
      return tex
    }()

    guard let texture
    else
    {
      domeLight.CreateIntensityAttr(VtValue(), false).Set(domeFallbackIntensity,
                                                         UsdTimeCode.Default())
      return false
    }

    domeLight.createTextureFileAttr().set(Sdf.AssetPath(texture))
    domeLight.CreateIntensityAttr(VtValue(), false).Set(domeTexturedIntensity,
                                                       UsdTimeCode.Default())
    return true
  }

  /// Neutral multiplier over an HDR's own radiance. Turn this up or down to
  /// expose the field against the environment.
  public static let domeTexturedIntensity: Float = 1.0

  /// Gain for the untextured white-dome fallback, which is otherwise nearly
  /// black.
  public static let domeFallbackIntensity: Float = 1000.0

  /// Selects the per-prim scene shape - one `Cube` prim per cube, each with its
  /// own overridden xform.
  ///
  /// Off by default. It is the honest "what naive per-prim scene-graph updates
  /// cost" comparison, not the demo: at a hundred thousand prims Hydra spends
  /// its entire frame re-syncing them, whatever the store does. Kept so the two
  /// can be shown back to back.
  public static func usesPerPrimPath() -> Bool
  {
    CommandLine.arguments.contains("--per-prim")
      || ProcessInfo.processInfo.environment["LATTICE_PER_PRIM"] == "1"
  }

  /// Forces the parallel-CPU path even where Metal is available, so the two can
  /// be compared back to back on stage.
  public static func forcesCPUPath() -> Bool
  {
    CommandLine.arguments.contains("--cpu")
      || ProcessInfo.processInfo.environment["LATTICE_FORCE_CPU"] == "1"
  }

  public static func openOrCreateStage() -> UsdStage
  {
    if let path = AppUtils.usdScenePathFromArguments()
    {
      return UsdStage.open(path)
    }
    else
    {
      return UsdStage.createInMemory()
    }
  }
  
  public static func setupColorManagement(config ocio: OCIOConfigProfileType)
  {
    guard let ocioConfig = ocio.config
    else { return print("Could not find OCIO config.") }

    #if os(macOS)
      /* setup ocio color config. */
      setenv("OCIO", ocioConfig, 1)
    #endif /* macOS */

    print(Overlay.GetOCIOConfigSummary(OCIO.GetCurrentConfig()))
  }
}
