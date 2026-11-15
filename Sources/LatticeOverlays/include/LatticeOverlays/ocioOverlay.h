#ifndef __LATTICE_OVERLAYS_OCIO_OVERLAY_H__
#define __LATTICE_OVERLAYS_OCIO_OVERLAY_H__

#if __has_include(<OpenColorIO/OpenColorIO.h>)
# include <OpenColorIO/OpenColorIO.h>

# include <memory>
# include <string>

namespace Overlay
{
std::string GetOCIOConfigSummary(std::shared_ptr<const OpenColorIO_v2_3::Config> configPtr);
} // namespace Overlay

#endif // __has_include(<OpenColorIO/OpenColorIO.h>)

#endif // __LATTICE_OVERLAYS_OCIO_OVERLAY_H__
