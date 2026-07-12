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

#include "LatticeHydra/XformSource.h"

#include <Gf/matrix4d.h>
#include <Sdf/path.h>

// opaque swift array type
struct _SwiftArrayBuffer;

extern "C" {
void swift_getLiveXform(void *outOptionalMatrix, const Pixar::SdfPath *sdfPath, void *selfPtr) asm(
    "_$s10LatticeUSD0A11XformSourceC07getLiveC0ySo5PixarO10GfMatrix4dVSgAF7SdfPathVF");

_SwiftArrayBuffer *swift_drainDirtiedPaths(void *selfPtr) asm(
    "_$s10LatticeUSD0A11XformSourceC17drainDirtiedPathsSaySo5PixarO7SdfPathVGyF");

void swift_release(void *value);
}

namespace LatticeUSD {

struct _SwiftOptionalMatrix {
  Pixar::GfMatrix4d matrix;
  bool hasValue;
};

struct _SwiftArrayHeader {
  void *heapMetadata;
  size_t count;
  size_t capacityAndFlags;
  Pixar::SdfPath firstElement;
};

std::optional<Pixar::GfMatrix4d> LatticeXformSource::getLiveXform(const Pixar::SdfPath &path)
{
  _SwiftOptionalMatrix buffer = {};

  // forward the hidden out-pointer and 'this' pointer context automatically
  swift_getLiveXform(&buffer, &path, this);

  // convert swift nil/value state to standard c++ optional
  if (buffer.hasValue) {
    return buffer.matrix;
  }
  return std::nullopt;
}

std::vector<Pixar::SdfPath> LatticeXformSource::drainDirtiedPaths()
{
  _SwiftArrayBuffer *rawArrayPtr = swift_drainDirtiedPaths(this);

  std::vector<Pixar::SdfPath> result;
  if (!rawArrayPtr) {
    return result;
  }

  auto *header = reinterpret_cast<_SwiftArrayHeader *>(rawArrayPtr);
  size_t totalElements = header->count;

  if (totalElements > 0) {
    const Pixar::SdfPath *dataStart = &(header->firstElement);
    result.assign(dataStart, dataStart + totalElements);
  }

  // execute the standard reference counter release
  // function to destroy the intermediate array
  // buffer allocation safely.
  swift_release(rawArrayPtr);
  return result;
}

}  // namespace LatticeUSD
