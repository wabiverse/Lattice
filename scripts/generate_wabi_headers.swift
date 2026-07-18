#!/usr/bin/env swift
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

let fm = FileManager.default
let includeRoot = "Sources/lattice/include/wabi"

let modules: [(target: String, module: String, header: String)] = [
  ("LatticeCore", "core", "lattice.h"),
  ("LatticeMetal", "gpu", "metal.h"),
  ("LatticeUSD", "scene", "usd.h"),
]

func run(_ args: [String]) throws
{
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = args
  try process.run()
  process.waitUntilExit()
  guard process.terminationStatus == 0
  else
  {
    throw NSError(domain: "foundation.wabiverse.lattice.generate_wabi_headers", code: Int(process.terminationStatus),
                  userInfo: [NSLocalizedDescriptionKey: "\(args.joined(separator: " ")) failed"])
  }
}

print("Preparing include/wabi/ subdirectories...")
for (_, module, _) in modules
{
  try fm.createDirectory(atPath: "\(includeRoot)/\(module)", withIntermediateDirectories: true)
}

try fm.createDirectory(atPath: "\(includeRoot)/imaging", withIntermediateDirectories: true)

// comment this back in if headers are being generated for the wrong swift target...
// print("Priming a full release build so dependencies are cached...")
// try run(["swift", "build", "-c", "release"])

for (target, module, header) in modules
{
  print("Generating \(module)/\(header) from target \(target)...")
  try run([
    "swift", "build", "-c", "release", "--target", target,
    "-Xswiftc", "-emit-clang-header-path",
    "-Xswiftc", "\(includeRoot)/\(module)/\(header)"
  ])

  let expected = "\(includeRoot)/\(module)/\(header)"
  guard fm.fileExists(atPath: expected)
  else
  {
    print("""
      ⚠️  Expected \(expected) after building \(target), but it isn't there.
      """)
    exit(1)
  }
  print("  -> \(expected)")
}

let umbrella = """
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
  #ifndef __WABI_H__
  #define __WABI_H__

  #include <wabi/core/lattice.h>
  #include <wabi/gpu/metal.h>
  #include <wabi/scene/usd.h>
  #include <wabi/imaging/hydra.h>

  #endif // __WABI_H__
  """
try umbrella.write(toFile: "\(includeRoot)/wabi.h", atomically: true, encoding: .utf8)
print("Wrote \(includeRoot)/wabi.h")
print("Done. Generated headers to '\(includeRoot)/'.")
