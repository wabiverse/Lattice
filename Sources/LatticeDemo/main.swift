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
import Lattice

// A minimal "physics" component pair, standing in for the kind of thing a
// game or simulation would update every frame at scale.

struct Transform: LatticeComponent
{
  var x: Float
  var y: Float
  var z: Float
}

struct Velocity: LatticeComponent
{
  var dx: Float
  var dy: Float
  var dz: Float
}

let store = LatticeStore()

let entityCount = 100_000
var entities: [LatticeEntity] = []
entities.reserveCapacity(entityCount)

// No registration; spawn lands each entity directly in its final archetype.
for i in 0 ..< entityCount
{
  entities.append(
    store.spawn(
      Transform(x: Float(i), y: 0, z: 0),
      Velocity(dx: 1, dy: 0.5, dz: 0)
    )
  )
}

let query = store.query(Transform.self, Velocity.self)
let dt: Float = 1.0 / 60.0
let frames = 120

func integrate(_ transform: inout Transform, _ velocity: Velocity)
{
  transform.x += velocity.dx * dt
  transform.y += velocity.dy * dt
  transform.z += velocity.dz * dt
}

/// Serial pass.
let serialStart = Date()
for _ in 0 ..< frames
{
  query.forEachMutatingFirst { _, transform, velocity in integrate(&transform, velocity) }
  store.advanceFrame()
}

let serialElapsed = Date().timeIntervalSince(serialStart)

/// Parallel pass (data-parallel value mutation across cores).
let parallelStart = Date()
for _ in 0 ..< frames
{
  query.forEachMutatingFirstParallel { transform, velocity in integrate(&transform, velocity) }
  store.advanceFrame()
}

let parallelElapsed = Date().timeIntervalSince(parallelStart)

print("Lattice demo")
print("Entities:                 \(entityCount)")
print("Frames:                    \(frames)")
print("Serial   per-frame avg:    \(String(format: "%.5f", serialElapsed / Double(frames) * 1000))ms")
print("Parallel per-frame avg:    \(String(format: "%.5f", parallelElapsed / Double(frames) * 1000))ms")
print("Parallel speedup:          \(String(format: "%.2f", serialElapsed / parallelElapsed))x")
print("Transform mutations:       \(store.mutationGeneration(of: Transform.self))")

if let sample = store.get(Transform.self, for: entities[0])
{
  print("entities[0].Transform after \(frames * 2) frames: (\(sample.x), \(sample.y), \(sample.z))")
}
