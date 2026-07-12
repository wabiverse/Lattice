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

#ifndef LATTICE_HYDRA_XFORM_SOURCE_H
#define LATTICE_HYDRA_XFORM_SOURCE_H

#include <pxr/pxrns.h>

#include <Gf/matrix4d.h>
#include <Sdf/path.h>

#include <optional>
#include <vector>

namespace LatticeUSD {

class LatticeXformSource {
 public:
  std::optional<Pixar::GfMatrix4d> getLiveXform(const Pixar::SdfPath &path);
  std::vector<Pixar::SdfPath> drainDirtiedPaths();
};

}  // namespace LatticeUSD

#endif  // LATTICE_HYDRA_XFORM_SOURCE_H
