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
}
