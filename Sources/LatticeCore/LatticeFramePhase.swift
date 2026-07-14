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

import Synchronization

/// The frame's read/write phase, shared by every structure that Hydra may pull
/// through concurrently.
///
/// Hydra calls `GetPrim()` from multiple threads. Concurrent *reads* of the
/// store and path table are safe; a read overlapping a *write* is not - a
/// `Dictionary` mutation racing a reader is memory corruption, not a torn
/// value. Nothing in the type system enforces the split, so it is asserted:
/// violations trap in debug and compile out in release.
///
///     mutate → advanceChangeTick() → Tick() → beginReadPhase()
///            → Hydra pulls GetPrim() → endReadPhase()
public final class LatticeFramePhase: Sendable
{
  public enum Phase: Sendable
  {
    /// Systems may mutate; Hydra must not be pulling.
    case mutable
    /// Hydra may pull concurrently; nothing may mutate.
    case readable
  }

  private let protected = Mutex<Phase>(.mutable)

  public init() {}

  public var current: Phase
  {
    protected.withLock { $0 }
  }

  public func beginReadPhase()
  {
    protected.withLock { $0 = .readable }
  }

  public func endReadPhase()
  {
    protected.withLock { $0 = .mutable }
  }
}
