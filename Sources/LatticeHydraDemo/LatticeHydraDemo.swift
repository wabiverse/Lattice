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
import OCIOBundle
import OpenColorIO

public typealias OCIO = OpenColorIO_v2_3

@main
struct LatticeHydraDemo: App
{
  typealias Backend = PlatformBackend
  
  let scenePath: String? = AppUtils.usdScenePathFromArguments()

  @State private var hydra = HydraStage()
  
  init()
  {
    OCIOBundler.override.ocioInit(config: .aces)
    if let ocio: OCIO.ConstConfigRcPtr = OCIOBundler.override.config {
      let config = Overlay.GetOCIOConfigSummary(ocio)
      print(config)
    }
  }
  
  var body: some Scene {
    WindowGroup("Lattice Hydra Demo") {
      VStack {
        if let engine = hydra.engine {
          Hydra.Viewport(engine: engine)
        } else {
          Text("Loading Stage...")
        }
      }
      .task {
        hydra.loadStage(scenePath)
      }
    }
  }
}

public extension OCIOBundler {
  @MainActor
  static var override: OCIOBundler {
    // hack, since OCIOBundler is not updated for swift 6 strict concurrency.
    nonisolated(unsafe) let instance = OCIOBundler.self[keyPath: \.shared]
    return instance
  }
}
