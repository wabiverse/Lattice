#ifndef __LATTICE_OVERLAYS_VT_ARRAY_OVERLAY_H__
#define __LATTICE_OVERLAYS_VT_ARRAY_OVERLAY_H__

#if __has_include(<pxr/pxrns.h>)
# include <pxr/pxrns.h>
# include <Gf/vec2f.h>
# include <Gf/vec3f.h>
# include <Gf/vec4f.h>
# include <Gf/vec2d.h>
# include <Gf/vec3d.h>
# include <Gf/vec4d.h>
# include <Vt/types.h>
# include <Vt/array.h>
#else
# include <pxr/pxr.h>
# include <pxr/base/gf/vec2f.h>
# include <pxr/base/gf/vec3f.h>
# include <pxr/base/gf/vec4f.h>
# include <pxr/base/gf/vec2d.h>
# include <pxr/base/gf/vec3d.h>
# include <pxr/base/gf/vec4d.h>
# include <pxr/base/vt/types.h>
# include <pxr/base/vt/array.h>
#endif

#include <cstdint>
#include <cstddef>

#define VT_ARRAY_OVERLOADS(SCALAR, ARRAYTYPE)                                  \
  inline const SCALAR *cdata(const PXR_NS::ARRAYTYPE &array)                   \
  {                                                                            \
    return array.cdata();                                                      \
  }                                                                            \
  inline PXR_NS::ARRAYTYPE vtArray(const SCALAR *src, std::size_t count)       \
  {                                                                            \
    return count ? PXR_NS::ARRAYTYPE(src, src + count) : PXR_NS::ARRAYTYPE();  \
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
VT_ARRAY_OVERLOADS(PXR_NS::GfVec2f, VtVec2fArray)
VT_ARRAY_OVERLOADS(PXR_NS::GfVec3f, VtVec3fArray)
VT_ARRAY_OVERLOADS(PXR_NS::GfVec4f, VtVec4fArray)
VT_ARRAY_OVERLOADS(PXR_NS::GfVec2d, VtVec2dArray)
VT_ARRAY_OVERLOADS(PXR_NS::GfVec3d, VtVec3dArray)
VT_ARRAY_OVERLOADS(PXR_NS::GfVec4d, VtVec4dArray)
} // namespace Overlay

#undef VT_ARRAY_OVERLOADS

#endif // __LATTICE_OVERLAYS_VT_ARRAY_OVERLAY_H__
