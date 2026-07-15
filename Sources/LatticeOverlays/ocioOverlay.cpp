#include "LatticeOverlays/ocioOverlay.h"

#include <memory>
#include <string>
#include <sstream>

namespace OCIO = OCIO_NAMESPACE;

namespace Overlay {
std::string GetOCIOConfigSummary(std::shared_ptr<const OCIO::Config> configPtr) {
  if (!configPtr) {
    return "Error: OCIO Config pointer is null.";
  }
  
  std::stringstream ss;
  ss << "=== OpenColorIO Config Summary ===\n";
  ss << "Version: " << configPtr->getMajorVersion() << "." << configPtr->getMinorVersion() << "\n";
  ss << "Total Color Spaces: " << configPtr->getNumColorSpaces() << "\n\n";
  
  ss << "Active Displays:\n";
  int numDisplays = configPtr->getNumDisplays();
  for (int i = 0; i < numDisplays; ++i) {
    const char* displayName = configPtr->getDisplay(i);
    ss << "  - " << displayName << "\n";
    
    int numViews = configPtr->getNumViews(displayName);
    for (int j = 0; j < numViews; ++j) {
      ss << "    * View: " << configPtr->getView(displayName, j) << "\n";
    }
  }
  
  ss << "\nAvailable Color Spaces:\n";
  int numSpaces = configPtr->getNumColorSpaces();
  for (int i = 0; i < numSpaces; ++i) {
    ss << "  [" << i << "] " << configPtr->getColorSpaceNameByIndex(i) << "\n";
  }
  
  ss << "==================================";
  return ss.str();
}
} // namespace Overlay
