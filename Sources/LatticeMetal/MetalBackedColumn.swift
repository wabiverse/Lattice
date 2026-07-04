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

#if canImport(Metal)
  import Foundation
  import Lattice
  import Metal

  /// Marker protocol for component types that are safe to store directly in a
  /// Metal buffer: fixed-size, no reference semantics, no heap-allocated
  /// fields (arrays, strings, classes, existentials). Swift can't fully
  /// enforce this at compile time, so treat it as a contract - build these
  /// types out of `Float`, `SIMD*`, `Int32`, and similar, the same rules you'd
  /// already follow for a struct going into a Metal argument buffer.
  public protocol LatticeGPUComponent: LatticeComponent {}

  /// A column whose storage lives directly in an `MTLBuffer` instead of a
  /// Swift array.
  ///
  /// On Apple Silicon with unified memory, `.storageModeShared` means the
  /// CPU-side `get`/`set` calls here and the GPU's view of the same bytes are
  /// the *same* memory - there is no explicit upload step between "the
  /// simulation wrote this component" and "the renderer can bind it". That's
  /// the single biggest practical advantage this design has over a
  /// CUDA-oriented store on non-unified-memory hardware: Fabric has to think
  /// about CPU/GPU synchronization as a first-class concern; on an M-series
  /// Mac this column type mostly doesn't have to.
  ///
  /// Conforms to ``TypedColumnStorage``, so wiring it into the store is a
  /// one-liner at registration time:
  ///
  /// ```swift
  /// store.register(Particle.self) { MetalBackedColumn<Particle>(device: device) }
  /// ```
  ///
  /// After that, every `Query` over `Particle` iterates straight over this
  /// `MTLBuffer`'s contents, and the same bytes are what a render/compute pass
  /// binds - no upload step on unified memory.
  public final class MetalBackedColumn<T: LatticeGPUComponent>: TypedColumnStorage
  {
    public typealias Element = T

    private let device: MTLDevice
    private var buffer: MTLBuffer
    private var capacity: Int
    public private(set) var count: Int = 0
    public private(set) var mutationGeneration: UInt64 = 0
    public private(set) var wholeColumnTick: UInt64 = 0
    /// Per-row change ticks, mirrored CPU-side alongside the GPU buffer so
    /// change detection works identically to the array-backed column.
    private var ticks: [UInt64] = []

    /// Bumped every time ``metalBuffer`` is replaced by a larger allocation
    /// (see `growIfNeeded`). A renderer or compute pass that cached the buffer
    /// from a previous frame must compare this against the value it saw then:
    /// if it changed, the old `MTLBuffer` is stale and any binding to it needs
    /// to be re-fetched from ``metalBuffer``. Growth allocates a brand-new
    /// buffer rather than resizing in place, so the handle itself changes.
    public private(set) var bufferGeneration: UInt64 = 0

    private static var stride: Int
    {
      MemoryLayout<T>.stride
    }

    public init(device: MTLDevice, initialCapacity: Int = 64)
    {
      self.device = device
      capacity = max(initialCapacity, 1)
      guard let buffer = device.makeBuffer(length: Self.stride * capacity, options: .storageModeShared)
      else
      {
        fatalError("Lattice: failed to allocate initial Metal buffer for \(T.self)")
      }
      self.buffer = buffer
    }

    /// The raw buffer, for a render or compute pass to bind directly, e.g.
    /// `encoder.setVertexBuffer(column.metalBuffer, offset: 0, index: 0)`.
    /// Only bytes `0..<count * MemoryLayout<T>.stride` are meaningful.
    public var metalBuffer: MTLBuffer
    {
      buffer
    }

    private func typedPointer() -> UnsafeMutablePointer<T>
    {
      buffer.contents().bindMemory(to: T.self, capacity: capacity)
    }

    private func growIfNeeded()
    {
      guard count >= capacity else { return }
      let newCapacity = capacity * 2
      guard let newBuffer = device.makeBuffer(length: Self.stride * newCapacity, options: .storageModeShared)
      else
      {
        fatalError("Lattice: failed to grow Metal buffer for \(T.self)")
      }
      memcpy(newBuffer.contents(), buffer.contents(), Self.stride * count)
      buffer = newBuffer
      capacity = newCapacity
      // The MTLBuffer handle just changed; anything holding the old one must
      // rebind. See `bufferGeneration`.
      bufferGeneration &+= 1
    }

    @discardableResult
    public func append(_ value: T) -> Int
    {
      growIfNeeded()
      typedPointer()[count] = value
      ticks.append(0)
      count += 1
      mutationGeneration &+= 1
      return count - 1
    }

    @discardableResult
    public func appendPreservingTick(_ value: T, tick: UInt64) -> Int
    {
      growIfNeeded()
      typedPointer()[count] = value
      ticks.append(tick)
      count += 1
      mutationGeneration &+= 1
      return count - 1
    }

    public func get(_ index: Int) -> T
    {
      typedPointer()[index]
    }

    public func set(_ index: Int, _ value: T)
    {
      typedPointer()[index] = value
      mutationGeneration &+= 1
    }

    public func stamp(_ index: Int, tick: UInt64)
    {
      ticks[index] = tick
    }

    public func changeTick(at index: Int) -> UInt64
    {
      ticks[index]
    }
    
    public func markWholeColumnChanged(tick: UInt64)
    {
      mutationGeneration &+= 1
      wholeColumnTick = tick
    }

    @inline(__always)
    public func withUnsafeBufferPointer<R>(_ body: (UnsafeBufferPointer<T>) throws -> R) rethrows -> R
    {
      try body(UnsafeBufferPointer(start: typedPointer(), count: count))
    }

    /// Borrows the whole column as a contiguous *mutable* buffer for bulk
    /// mutation. Deliberately does not touch ``mutationGeneration`` or
    /// ``wholeColumnTick`` itself - see the protocol doc comment. Callers doing
    /// a real bulk write call ``markWholeColumnChanged(tick:)`` once afterward;
    /// every mutating `Query` method already does this.
    @inline(__always)
    public func withUnsafeMutableBufferPointer<R>(_ body: (UnsafeMutableBufferPointer<T>) throws -> R) rethrows -> R
    {
      return try body(UnsafeMutableBufferPointer(start: typedPointer(), count: count))
    }

    @discardableResult
    public func swapRemove(at index: Int) -> Bool
    {
      guard index < count else { return false }
      let lastIndex = count - 1
      let moved = index != lastIndex
      if moved
      {
        typedPointer()[index] = typedPointer()[lastIndex]
        ticks[index] = ticks[lastIndex]
      }
      ticks.removeLast()
      count -= 1
      // Structural relocation, not a content write - matches TypedColumn and
      // keeps mutationGeneration a true "did any value of T change" signal.
      return moved
    }
  }
#endif
