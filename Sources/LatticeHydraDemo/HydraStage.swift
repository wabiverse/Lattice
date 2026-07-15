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

import OpenUSDKit
import HydraKit
import SwiftCrossUI

@MainActor
public final class HydraStage: SwiftCrossUI.ObservableObject {
  @SwiftCrossUI.Published var stage: UsdStage?
  @SwiftCrossUI.Published var engine: Hydra.RenderEngine?
  
  public init() {
    Pixar.Bundler.shared.setup(.resources)
  }

  public func loadStage(_ path: String?) {
    Task.detached {
      let newStage: UsdStage
      if let path = path {
        newStage = UsdStage.open(path)
      } else {
        newStage = UsdStage.createInMemory()
      }
      
      // create render engine with opencolorio color management.
      let newEngine = Hydra.RenderEngine(stage: newStage, colorCorrectionMode: .openColorIO)
      
      // bump maxLights for the ALab-2.3.0 scene.
      newEngine.getEngine().SetRendererSetting(Tf.Token("maxLights"), VtValue(CInt(54)))
      // setup color correction matching aces ocio config.
      newEngine.getEngine().SetColorCorrectionSettings(
        .openColorIO,
        Tf.Token("Display P3 - Display"),
        Tf.Token("ACES 1.0 - SDR Video"),
        Tf.Token("ACEScg"),
        Tf.Token("")
      )
      
      await MainActor.run
      {
        self.stage = newStage
        self.engine = newEngine
      }
    }
  }
}
