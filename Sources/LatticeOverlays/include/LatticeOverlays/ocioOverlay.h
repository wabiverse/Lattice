#ifndef __LATTICE_OVERLAYS_OCIO_OVERLAY_H__
#define __LATTICE_OVERLAYS_OCIO_OVERLAY_H__

#include <OpenColorIO/OpenColorIO.h>

#include <memory>
#include <string>

namespace Overlay
{
std::string GetOCIOConfigSummary(std::shared_ptr<const OpenColorIO_v2_3::Config> configPtr);
} // namespace Overlay

#endif // __LATTICE_OVERLAYS_OCIO_OVERLAY_H__
