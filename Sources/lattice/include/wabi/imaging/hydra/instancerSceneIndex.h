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

#ifndef __WABI_IMAGING_HYDRA_INSTANCER_SCENE_INDEX_H__
#define __WABI_IMAGING_HYDRA_INSTANCER_SCENE_INDEX_H__

#include <pxr/pxrns.h>

#include <Tf/declarePtrs.h>
#include <Tf/refPtr.h>

#include <Sdf/path.h>

#include <Vt/array.h>

#include <Hd/dataSource.h>

#include <Hd/filteringSceneIndex.h>

#include <mutex>

#include "wabi/core/lattice.h"
#include "wabi/scene/usd.h"

PXR_NAMESPACE_OPEN_SCOPE

TF_DECLARE_WEAK_AND_REF_PTRS(LatticeInstancerSceneIndex);

/// Answers one instancer prim out of a Lattice column, instead of answering N
/// prims out of it.
///
/// ``LatticeHydraSceneIndex`` overrides the xform of every moving prim, which
/// costs Hydra one `GetPrim()` and one dirtied prim per cube per frame - at a hundred
/// thousand cubes that sync dominates the frame by orders of magnitude, however fast the
/// store is. This overrides the three instance-rate primvars of a single `UsdGeomPointInstancer`
/// instead, so the frame's notification set is one path regardless of instance count, and Storm
/// draws the whole field in one indirect draw.
///
/// The primvars are `hydra:instanceTranslations`, `hydra:instanceScales` and
/// `hydra:instanceRotations` - `VtVec3fArray`, `VtVec3fArray` and `VtQuatfArray`.
/// All float, so the compute kernel's output needs no widening: the arrays are built by de-interleaving the
/// `InstanceXform` column directly.
class LatticeInstancerSceneIndex : public HdSingleInputFilteringSceneIndexBase {
 public:
  static LatticeInstancerSceneIndexRefPtr New(const HdSceneIndexBaseRefPtr &inputSceneIndex,
                                              LatticeUSD::LatticeInstanceSource *latticeSource);

  HdSceneIndexPrim GetPrim(const SdfPath &primPath) const override;

  SdfPathVector GetChildPrimPaths(const SdfPath &primPath) const override;

  /// Sends `PrimsDirtied` for the instancer if the source was marked this
  /// frame. Call once per frame from the mutation phase.
  void Tick();

 protected:
  LatticeInstancerSceneIndex(const HdSceneIndexBaseRefPtr &inputSceneIndex,
                             LatticeUSD::LatticeInstanceSource *latticeSource);

  ~LatticeInstancerSceneIndex();

  void _PrimsAdded(const HdSceneIndexBase &sender,
                   const HdSceneIndexObserver::AddedPrimEntries &entries) override;

  void _PrimsRemoved(const HdSceneIndexBase &sender,
                     const HdSceneIndexObserver::RemovedPrimEntries &entries) override;

  void _PrimsDirtied(const HdSceneIndexBase &sender,
                     const HdSceneIndexObserver::DirtiedPrimEntries &entries) override;

 private:
  LatticeUSD::LatticeInstanceSource *_latticeSource;

  /// Instance indices narrowed to the live count, cached on that count.
  ///
  /// `GetPrim` is const but runs every frame, while this only changes when the
  /// live count does. `mutable`, so the O(count) filter is skipped on every frame
  /// that did not move the slider.
  ///
  /// Guarded, because Storm syncs prims in parallel and so calls `GetPrim` on
  /// this instancer from several threads at once. The handle is a `shared_ptr`,
  /// and concurrently reading one while another thread assigns it races on the
  /// control block - the losing thread ends up holding a pointer the winner has
  /// already freed, which reaches the GPU as a garbage buffer address.
  mutable std::mutex _indicesMutex;
  mutable HdVectorDataSourceHandle _instanceIndices;
  mutable size_t _indicesCount = 0;
};

PXR_NAMESPACE_CLOSE_SCOPE

#endif  // __WABI_IMAGING_HYDRA_INSTANCER_SCENE_INDEX_H__
