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

#include "wabi/imaging/hydra/sceneIndex.h"

PXR_NAMESPACE_OPEN_SCOPE

LatticeHydraSceneIndexRefPtr LatticeHydraSceneIndex::New(
    const HdSceneIndexBaseRefPtr &inputSceneIndex, LatticeUSD::LatticeXformSource *latticeSource)
{
  return TfCreateRefPtr(new LatticeHydraSceneIndex(inputSceneIndex, latticeSource));
}

LatticeHydraSceneIndex::LatticeHydraSceneIndex(const HdSceneIndexBaseRefPtr &inputSceneIndex,
                                               LatticeUSD::LatticeXformSource *latticeSource)
    : HdSingleInputFilteringSceneIndexBase(inputSceneIndex), _latticeSource(latticeSource)
{}

LatticeHydraSceneIndex::~LatticeHydraSceneIndex()
{}

HdSceneIndexPrim LatticeHydraSceneIndex::GetPrim(const SdfPath &primPath) const
{
  HdSceneIndexPrim prim = _GetInputSceneIndex()->GetPrim(primPath);
  if (!prim.dataSource || !_latticeSource) {
    return prim;
  }

  Pixar::GfMatrix4d xf(1.0);
  if (_latticeSource->didGetLiveXform(xf, primPath)) {
    HdContainerDataSourceEditor editor(prim.dataSource);
    editor.Set(HdXformSchema::GetDefaultLocator(),
               HdXformSchema::Builder()
                   .SetMatrix(HdRetainedTypedSampledDataSource<GfMatrix4d>::New(xf))
                   .SetResetXformStack(HdRetainedTypedSampledDataSource<bool>::New(true))
                   .Build());
    prim.dataSource = editor.Finish();
  }
  return prim;
}

SdfPathVector LatticeHydraSceneIndex::GetChildPrimPaths(const SdfPath &primPath) const
{
  return _GetInputSceneIndex()->GetChildPrimPaths(primPath);
}

void LatticeHydraSceneIndex::NotifyLatticeMutations(const SdfPathVector &dirtiedPaths)
{
  static const HdDataSourceLocatorSet dirtyLocators =
      HdContainerDataSourceEditor::ComputeDirtyLocators(HdXformSchema::GetDefaultLocator());

  HdSceneIndexObserver::DirtiedPrimEntries entries;
  entries.reserve(dirtiedPaths.size());
  for (const auto &path : dirtiedPaths) {
    entries.emplace_back(path, dirtyLocators);
  }

  if (!entries.empty()) {
    _SendPrimsDirtied(entries);
  }
}

void LatticeHydraSceneIndex::Tick()
{
  if (!_latticeSource) {
    return;
  }
  
  NotifyLatticeMutations(_latticeSource->drainDirtiedPaths());
}

void LatticeHydraSceneIndex::_PrimsAdded(const HdSceneIndexBase &sender,
                                         const HdSceneIndexObserver::AddedPrimEntries &entries)
{
  _SendPrimsAdded(entries);
}

void LatticeHydraSceneIndex::_PrimsRemoved(const HdSceneIndexBase &sender,
                                           const HdSceneIndexObserver::RemovedPrimEntries &entries)
{
  _SendPrimsRemoved(entries);
}

void LatticeHydraSceneIndex::_PrimsDirtied(const HdSceneIndexBase &sender,
                                           const HdSceneIndexObserver::DirtiedPrimEntries &entries)
{
  _SendPrimsDirtied(entries);
}

PXR_NAMESPACE_CLOSE_SCOPE
