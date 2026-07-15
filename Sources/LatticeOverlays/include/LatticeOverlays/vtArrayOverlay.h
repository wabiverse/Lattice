#ifndef __LATTICE_OVERLAYS_VT_ARRAY_OVERLAY_H__
#define __LATTICE_OVERLAYS_VT_ARRAY_OVERLAY_H__

#include "pxr/pxrns.h"

#include "Gf/vec2f.h"
#include "Gf/vec3f.h"
#include "Gf/vec4f.h"
#include "Gf/vec2d.h"
#include "Gf/vec3d.h"
#include "Gf/vec4d.h"

#include "Vt/types.h"
#include "Vt/array.h"

#include <cstdint>

#define VT_ARRAY_OVERLOADS(SCALAR, ARRAYTYPE)                               \
  inline const SCALAR *cdata(const Pixar::ARRAYTYPE &array)                 \
  {                                                                         \
    return array.cdata();                                                   \
  }                                                                         \
  inline Pixar::ARRAYTYPE vtArray(const SCALAR *src, std::size_t count)     \
  {                                                                         \
    return count ? Pixar::ARRAYTYPE(src, src + count) : Pixar::ARRAYTYPE(); \
  }

namespace Overlay
{
VT_ARRAY_OVERLOADS(bool, VtBoolArray)
VT_ARRAY_OVERLOADS(int, VtIntArray)
VT_ARRAY_OVERLOADS(unsigned int, VtUIntArray)
VT_ARRAY_OVERLOADS(int64_t, VtInt64Array)
VT_ARRAY_OVERLOADS(uint64_t, VtUInt64Array)
VT_ARRAY_OVERLOADS(float, VtFloatArray)
VT_ARRAY_OVERLOADS(double, VtDoubleArray)
VT_ARRAY_OVERLOADS(Pixar::GfVec2f, VtVec2fArray)
VT_ARRAY_OVERLOADS(Pixar::GfVec3f, VtVec3fArray)
VT_ARRAY_OVERLOADS(Pixar::GfVec4f, VtVec4fArray)
VT_ARRAY_OVERLOADS(Pixar::GfVec2d, VtVec2dArray)
VT_ARRAY_OVERLOADS(Pixar::GfVec3d, VtVec3dArray)
VT_ARRAY_OVERLOADS(Pixar::GfVec4d, VtVec4dArray)
} // namespace Overlay

#undef VT_ARRAY_OVERLOADS

#endif // __LATTICE_OVERLAYS_VT_ARRAY_OVERLAY_H__
