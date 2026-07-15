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

@main
struct LatticeHydraDemo: App
{
  typealias Backend = PlatformBackend
  
  let stage: UsdStage
  let engine: Hydra.RenderEngine

  let source: USDStageSource

  init()
  {
    Pixar.Bundler.shared.setup(.resources)
    
    // opens the stage specified by '--usd /path/to/stage.usda'
    // otherwise, falls back to a default '/hello/world' stage.
    if let scenePath = AppUtils.usdScenePathFromArguments()
    {
      stage = UsdStage.open(scenePath)
    }
    else
    {
      stage = UsdStage.createInMemory()
      
      // Hydra.Viewport does not yet have a default light, or
      // any option to add one yet - and without a light, you
      // wont be able to see anything except a pure black image.
      let domeLight = UsdLux.DomeLight.define(stage, path: "/hello/defaultDomeLight")
      if let hdxResources = Bundle.hdx?.resourcePath {
        let tex = "\(hdxResources)/textures/StinsonBeach.hdr"
        if FileManager.default.fileExists(atPath: tex) {
          let hdrAsset = Sdf.AssetPath(tex)
          domeLight.createTextureFileAttr().set(hdrAsset)
        }
      }
      
      UsdGeom.Xform.define(stage, path: "/hello")
      UsdGeom.Sphere.define(stage, path: "/hello/world")
    }

    source = USDStageSource(stage: stage)
    engine = Hydra.RenderEngine(stage: stage)
  }

  var body: some Scene
  {
    WindowGroup("Lattice Hydra Demo")
    {
      Hydra.Viewport(engine: engine)
    }
  }
}
