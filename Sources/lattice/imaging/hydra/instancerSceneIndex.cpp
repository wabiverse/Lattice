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
#include <Hd/instancerTopologySchema.h>
#include <Hd/primvarsSchema.h>
#include <Hd/retainedDataSource.h>
#include <Hd/schemaTypeDefs.h>
#include <Hd/tokens.h>

#include <algorithm>
#include <vector>

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

  // how many of them are live. everything below is sized to this rather than to
  // `count`, so allocation, fill and draw all scale with the slider instead of
  // staying at whatever '--count' allocated.
  const size_t active = std::min(static_cast<size_t>(_latticeSource->activeCount()), count);

  VtVec3fArray translations(active);
  VtVec3fArray scales(active);
  VtQuatfArray rotations(active);

  for (size_t i = 0; i < active; ++i) {
    const float *e = f + i * kStride;
    translations[i] = GfVec3f(e[0], e[1], e[2]);
    scales[i] = GfVec3f(e[3], e[4], e[5]);
    // swift stores the imaginary part first, then the
    // real - GfQuatf takes the real part first.
    rotations[i] = GfQuatf(e[9], GfVec3f(e[6], e[7], e[8]));
  }

  HdContainerDataSourceEditor editor(prim.dataSource);

  // the primvar arrays are now shorter than the authored instance set, so the
  // topology has to be narrowed to match or hydra indexes past their end.
  // filtering the buckets is O(count), so its cached, it only reruns when the
  // live count moves.
  //
  // storm calls this from several threads at once, so the cache is taken under
  // a lock and the handle copied out of it - handing the shared_ptr itself to a
  // reader while another thread reassigns it races on its control block.
  HdVectorDataSourceHandle instanceIndices;
  if (active < count) {
    std::lock_guard<std::mutex> lock(_indicesMutex);

    if (_indicesCount != active) {
      HdInstancerTopologySchema topology =
          HdInstancerTopologySchema::GetFromParent(prim.dataSource);
      HdIntArrayVectorSchema sourceIndices = topology.GetInstanceIndices();
      const size_t protoCount = sourceIndices.GetNumElements();

      std::vector<HdDataSourceBaseHandle> buckets;
      buckets.reserve(protoCount);

      for (size_t k = 0; k < protoCount; ++k) {
        VtIntArray kept;
        if (HdIntArrayDataSourceHandle src = sourceIndices.GetElement(k)) {
          const VtIntArray all = src->GetTypedValue(0.0f);
          kept.reserve(all.size());
          for (const int index : all) {
            if (index >= 0 && static_cast<size_t>(index) < active) {
              kept.push_back(index);
            }
          }
        }
        buckets.push_back(HdRetainedTypedSampledDataSource<VtIntArray>::New(kept));
      }

      _instanceIndices = buckets.empty()
                             ? nullptr
                             : HdRetainedSmallVectorDataSource::New(buckets.size(),
                                                                    buckets.data());
      _indicesCount = active;
    }

    instanceIndices = _instanceIndices;
  }

  if (instanceIndices) {
    editor.Set(HdInstancerTopologySchema::GetDefaultLocator().Append(
                   HdInstancerTopologySchemaTokens->instanceIndices),
               instanceIndices);
  }

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
  if (!_latticeSource) {
    return;
  }

  const bool primvarsDirty = _latticeSource->drainDirty();
  // instance indices live in the topology rather than the primvars, so a count
  // change has to be published separately - dirtying the primvars alone would
  // leave hydra drawing the previous number of instances.
  const bool topologyDirty = _latticeSource->drainTopologyDirty();

  if (!primvarsDirty && !topologyDirty) {
    return;
  }

  // one entry, however many instances moved. this is the whole
  // reason the instancer path scales where the per-prim path
  // does not.
  HdDataSourceLocatorSet dirtyLocators;
  if (primvarsDirty) {
    dirtyLocators.insert(
        HdPrimvarsSchema::GetDefaultLocator().Append(HdInstancerTokens->instanceTranslations));
    dirtyLocators.insert(
        HdPrimvarsSchema::GetDefaultLocator().Append(HdInstancerTokens->instanceScales));
    dirtyLocators.insert(
        HdPrimvarsSchema::GetDefaultLocator().Append(HdInstancerTokens->instanceRotations));
  }
  if (topologyDirty) {
    dirtyLocators.insert(
        HdInstancerTopologySchema::GetDefaultLocator().Append(HdInstancerTopologySchemaTokens->instanceIndices));
  }

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
