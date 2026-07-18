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

#include <Tf/declarePtrs.h>
#include <Tf/refPtr.h>

#include <Gf/quatf.h>
#include <Gf/vec3f.h>
#include <Gf/matrix4d.h>

#include <Vt/array.h>

#include <Sdf/path.h>
#include <Usd/stage.h>

#include <Hd/containerDataSourceEditor.h>
#include <Hd/primvarsSchema.h>
#include <Hd/retainedDataSource.h>
#include <Hd/tokens.h>

#include "wabi/imaging/hydra/instancerSceneIndex.h"

PXR_NAMESPACE_OPEN_SCOPE

namespace {

/// Ten floats per instance, matching `LatticeUSD.InstanceXform`.
///
/// Not a struct read through a pointer cast: the column is walked as a flat
/// float array so nothing depends on this file and the Swift side agreeing on
/// padding. `kStride` is the contract, and it is asserted against the Swift
/// type's stride at the call site in the demo.
constexpr size_t kStride = 10;

/// Builds the primvar container Hydra expects for one instance-rate primvar:
/// a `primvarValue` sampled data source plus its interpolation and role.
HdContainerDataSourceHandle _InstancePrimvar(const HdDataSourceBaseHandle &value,
                                             const TfToken &role)
{
  return HdPrimvarSchema::Builder()
      .SetPrimvarValue(HdSampledDataSource::Cast(value))
      .SetInterpolation(
          HdPrimvarSchema::BuildInterpolationDataSource(HdPrimvarSchemaTokens->instance))
      .SetRole(HdPrimvarSchema::BuildRoleDataSource(role))
      .Build();
}

}  // namespace

LatticeInstancerSceneIndexRefPtr LatticeInstancerSceneIndex::New(
    const HdSceneIndexBaseRefPtr &inputSceneIndex,
    LatticeUSD::LatticeInstanceSource *latticeSource)
{
  return TfCreateRefPtr(new LatticeInstancerSceneIndex(inputSceneIndex, latticeSource));
}

LatticeInstancerSceneIndex::LatticeInstancerSceneIndex(
    const HdSceneIndexBaseRefPtr &inputSceneIndex,
    LatticeUSD::LatticeInstanceSource *latticeSource)
    : HdSingleInputFilteringSceneIndexBase(inputSceneIndex), _latticeSource(latticeSource)
{}

LatticeInstancerSceneIndex::~LatticeInstancerSceneIndex()
{}

HdSceneIndexPrim LatticeInstancerSceneIndex::GetPrim(const SdfPath &primPath) const
{
  HdSceneIndexPrim prim = _GetInputSceneIndex()->GetPrim(primPath);
  if (!prim.dataSource || !_latticeSource) {
    return prim;
  }

  // everything below is per-frame work for the whole field,
  // so it must only run for the one prim that actually is
  // the instancer.
  if (primPath != _latticeSource->getInstancerPath()) {
    return prim;
  }

  const void *base = _latticeSource->instanceBase();
  const size_t count = static_cast<size_t>(_latticeSource->instanceCount());
  if (!base || count == 0) {
    return prim;
  }

  const float *f = static_cast<const float *>(base);

  // de-interleave the single column into the three arrays
  // hydra wants. one pass, once per frame, for the entire
  // field - as against one `GetPrim()` per cube in the
  // per-prim scene index.
  VtVec3fArray translations(count);
  VtVec3fArray scales(count);
  VtQuatfArray rotations(count);

  for (size_t i = 0; i < count; ++i) {
    const float *e = f + i * kStride;
    translations[i] = GfVec3f(e[0], e[1], e[2]);
    scales[i] = GfVec3f(e[3], e[4], e[5]);
    // swift stores the imaginary part first, then the
    // real - GfQuatf takes the real part first.
    rotations[i] = GfQuatf(e[9], GfVec3f(e[6], e[7], e[8]));
  }

  HdContainerDataSourceEditor editor(prim.dataSource);

  editor.Set(HdPrimvarsSchema::GetDefaultLocator().Append(
                 HdInstancerTokens->instanceTranslations),
             _InstancePrimvar(HdRetainedTypedSampledDataSource<VtVec3fArray>::New(translations),
                              HdPrimvarSchemaTokens->point));

  editor.Set(HdPrimvarsSchema::GetDefaultLocator().Append(HdInstancerTokens->instanceScales),
             _InstancePrimvar(HdRetainedTypedSampledDataSource<VtVec3fArray>::New(scales),
                              TfToken()));

  editor.Set(HdPrimvarsSchema::GetDefaultLocator().Append(HdInstancerTokens->instanceRotations),
             _InstancePrimvar(HdRetainedTypedSampledDataSource<VtQuatfArray>::New(rotations),
                              TfToken()));

  prim.dataSource = editor.Finish();
  return prim;
}

SdfPathVector LatticeInstancerSceneIndex::GetChildPrimPaths(const SdfPath &primPath) const
{
  return _GetInputSceneIndex()->GetChildPrimPaths(primPath);
}

void LatticeInstancerSceneIndex::Tick()
{
  if (!_latticeSource || !_latticeSource->drainDirty()) {
    return;
  }

  // one entry, however many instances moved. this is the whole
  // reason the instancer path scales where the per-prim path
  // does not.
  static const HdDataSourceLocatorSet dirtyLocators{
      HdPrimvarsSchema::GetDefaultLocator().Append(HdInstancerTokens->instanceTranslations),
      HdPrimvarsSchema::GetDefaultLocator().Append(HdInstancerTokens->instanceScales),
      HdPrimvarsSchema::GetDefaultLocator().Append(HdInstancerTokens->instanceRotations)};

  HdSceneIndexObserver::DirtiedPrimEntries entries;
  entries.emplace_back(_latticeSource->getInstancerPath(), dirtyLocators);
  _SendPrimsDirtied(entries);
}

void LatticeInstancerSceneIndex::_PrimsAdded(const HdSceneIndexBase &sender,
                                             const HdSceneIndexObserver::AddedPrimEntries &entries)
{
  _SendPrimsAdded(entries);
}

void LatticeInstancerSceneIndex::_PrimsRemoved(
    const HdSceneIndexBase &sender, const HdSceneIndexObserver::RemovedPrimEntries &entries)
{
  _SendPrimsRemoved(entries);
}

void LatticeInstancerSceneIndex::_PrimsDirtied(
    const HdSceneIndexBase &sender, const HdSceneIndexObserver::DirtiedPrimEntries &entries)
{
  _SendPrimsDirtied(entries);
}

PXR_NAMESPACE_CLOSE_SCOPE
