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

#ifndef __WABI_IMAGING_HYDRA_SCENE_INDEX_H__
#define __WABI_IMAGING_HYDRA_SCENE_INDEX_H__

#include <pxr/pxrns.h>

#include <Tf/declarePtrs.h>
#include <Tf/refPtr.h>

#include <Gf/matrix4d.h>

#include <Sdf/path.h>
#include <Usd/stage.h>

#include <Hd/containerDataSourceEditor.h>
#include <Hd/filteringSceneIndex.h>
#include <Hd/retainedDataSource.h>
#include <Hd/xformSchema.h>

#include "wabi/core/lattice.h"
#include "wabi/gpu/metal.h"
#include "wabi/scene/usd.h"

PXR_NAMESPACE_OPEN_SCOPE

TF_DECLARE_WEAK_AND_REF_PTRS(LatticeHydraSceneIndex);

class LatticeHydraSceneIndex : public HdSingleInputFilteringSceneIndexBase {
 public:
  static LatticeHydraSceneIndexRefPtr New(const HdSceneIndexBaseRefPtr &inputSceneIndex,
                                          LatticeUSD::LatticeXformSource *latticeSource);

  HdSceneIndexPrim GetPrim(const SdfPath &primPath) const override;

  SdfPathVector GetChildPrimPaths(const SdfPath &primPath) const override;

  void NotifyLatticeMutations(const SdfPathVector &dirtiedPaths);

  void Tick();

 protected:
  LatticeHydraSceneIndex(const HdSceneIndexBaseRefPtr &inputSceneIndex,
                         LatticeUSD::LatticeXformSource *latticeSource);

  ~LatticeHydraSceneIndex();

  void _PrimsAdded(const HdSceneIndexBase &sender,
                   const HdSceneIndexObserver::AddedPrimEntries &entries) override;

  void _PrimsRemoved(const HdSceneIndexBase &sender,
                     const HdSceneIndexObserver::RemovedPrimEntries &entries) override;

  void _PrimsDirtied(const HdSceneIndexBase &sender,
                     const HdSceneIndexObserver::DirtiedPrimEntries &entries) override;

 private:
  LatticeUSD::LatticeXformSource *_latticeSource;
};

PXR_NAMESPACE_CLOSE_SCOPE

#endif  // __WABI_IMAGING_HYDRA_SCENE_INDEX_H__
