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
#include <Hd/sceneIndexPluginRegistry.h>
#include <Hd/tokens.h>

#include "wabi/imaging/hydra/latticeBridge.h"
#include "wabi/imaging/hydra/instancerSceneIndex.h"
#include "wabi/imaging/hydra/sceneIndex.h"

#include <algorithm>
#include <limits>
#include <memory>
#include <mutex>
#include <vector>

PXR_NAMESPACE_USING_DIRECTIVE

namespace {

/// The C++ handle onto the Swift `LatticeXformSource`.
///
/// `LatticeXformSource` is a refcounted wrapper: holding one here keeps the
/// Swift object alive for the process lifetime, which is what lets the scene indices hold
/// a bare pointer to it. It is heap-allocated and never freed on purpose - Hydra may
/// tear down scene indices on a background thread during process teardown, and a
/// destroyed source would be read after free.
std::unique_ptr<LatticeUSD::LatticeXformSource> *_source = nullptr;

/// Weak, so a scene index torn down with its render index does not leak and is
/// skipped rather than resurrected on the next tick.
std::vector<LatticeHydraSceneIndexPtr> *_liveSceneIndices = nullptr;

std::mutex &_Mutex()
{
  static std::mutex m;
  return m;
}

/// Drops entries whose scene index has since been destroyed, in place.
void _CompactLocked()
{
  if (!_liveSceneIndices) {
    return;
  }
  auto &v = *_liveSceneIndices;
  v.erase(std::remove_if(v.begin(),
                         v.end(),
                         [](const LatticeHydraSceneIndexPtr &p) { return !p; }),
          v.end());
}

}  // namespace

void LatticeHydraRegisterSceneIndex(void *latticeSource)
{
  if (!latticeSource) {
    return;
  }

  {
    std::lock_guard<std::mutex> lock(_Mutex());

    // registering twice would append a second, redundant
    // scene index to every chain - each one overriding
    // the same xforms as the last.
    if (_source) {
      return;
    }

    _source = new std::unique_ptr<LatticeUSD::LatticeXformSource>(
        new LatticeUSD::LatticeXformSource(
            LatticeUSD::_impl::_impl_LatticeXformSource::makeRetained(latticeSource)));

    _liveSceneIndices = new std::vector<LatticeHydraSceneIndexPtr>();
  }

  HdSceneIndexPluginRegistry::GetInstance().RegisterSceneIndexForRenderer(
      // empty display name: append to every renderer, so the demo works
      // the same whether it lands on Storm, Metal, or a headless delegate.
      /* rendererDisplayName = */ std::string(),
      [](const std::string &renderInstanceId,
         const HdSceneIndexBaseRefPtr &inputScene,
         const HdContainerDataSourceHandle &inputArgs) -> HdSceneIndexBaseRefPtr {
        std::lock_guard<std::mutex> lock(_Mutex());
        if (!_source || !*_source) {
          return inputScene;
        }

        LatticeHydraSceneIndexRefPtr si = LatticeHydraSceneIndex::New(inputScene,
                                                                     _source->get());
        if (_liveSceneIndices) {
          _liveSceneIndices->push_back(si);
        }
        return si;
      },
      /* inputArgs = */ nullptr,
      // last phase, at the end: the override has to sit downstream of the stage
      // scene index, or the composed USD xform would be read after ours and win.
      /* insertionPhase = */ std::numeric_limits<HdSceneIndexPluginRegistry::InsertionPhase>::max(),
      HdSceneIndexPluginRegistry::InsertionOrderAtEnd);
}

void LatticeHydraTick(void)
{
  std::lock_guard<std::mutex> lock(_Mutex());
  if (!_liveSceneIndices) {
    return;
  }

  _CompactLocked();
  for (const LatticeHydraSceneIndexPtr &si : *_liveSceneIndices) {
    if (si) {
      si->Tick();
    }
  }
}

size_t LatticeHydraLiveSceneIndexCount(void)
{
  std::lock_guard<std::mutex> lock(_Mutex());
  if (!_liveSceneIndices) {
    return 0;
  }
  _CompactLocked();
  return _liveSceneIndices->size();
}

// ---------------------------------------------------------------------------
// Instancer path
// ---------------------------------------------------------------------------

namespace {

std::unique_ptr<LatticeUSD::LatticeInstanceSource> *_instanceSource = nullptr;
std::vector<LatticeInstancerSceneIndexPtr> *_liveInstancerSceneIndices = nullptr;

void _CompactInstancerLocked()
{
  if (!_liveInstancerSceneIndices) {
    return;
  }
  auto &v = *_liveInstancerSceneIndices;
  v.erase(std::remove_if(v.begin(),
                         v.end(),
                         [](const LatticeInstancerSceneIndexPtr &p) { return !p; }),
          v.end());
}

}  // namespace

void LatticeHydraRegisterInstancerSceneIndex(void *latticeSource)
{
  if (!latticeSource) {
    return;
  }

  {
    std::lock_guard<std::mutex> lock(_Mutex());
    if (_instanceSource) {
      return;
    }

    _instanceSource = new std::unique_ptr<LatticeUSD::LatticeInstanceSource>(
        new LatticeUSD::LatticeInstanceSource(
            LatticeUSD::_impl::_impl_LatticeInstanceSource::makeRetained(latticeSource)));

    _liveInstancerSceneIndices = new std::vector<LatticeInstancerSceneIndexPtr>();
  }

  HdSceneIndexPluginRegistry::GetInstance().RegisterSceneIndexForRenderer(
      /* rendererDisplayName = */ std::string(),
      [](const std::string &renderInstanceId,
         const HdSceneIndexBaseRefPtr &inputScene,
         const HdContainerDataSourceHandle &inputArgs) -> HdSceneIndexBaseRefPtr {
        std::lock_guard<std::mutex> lock(_Mutex());
        if (!_instanceSource || !*_instanceSource) {
          return inputScene;
        }

        LatticeInstancerSceneIndexRefPtr si = LatticeInstancerSceneIndex::New(
            inputScene, _instanceSource->get());
        if (_liveInstancerSceneIndices) {
          _liveInstancerSceneIndices->push_back(si);
        }
        return si;
      },
      /* inputArgs = */ nullptr,
      /* insertionPhase = */ std::numeric_limits<HdSceneIndexPluginRegistry::InsertionPhase>::max(),
      HdSceneIndexPluginRegistry::InsertionOrderAtEnd);
}

void LatticeHydraInstancerTick(void)
{
  std::lock_guard<std::mutex> lock(_Mutex());
  if (!_liveInstancerSceneIndices) {
    return;
  }

  _CompactInstancerLocked();
  for (const LatticeInstancerSceneIndexPtr &si : *_liveInstancerSceneIndices) {
    if (si) {
      si->Tick();
    }
  }
}

size_t LatticeHydraLiveInstancerSceneIndexCount(void)
{
  std::lock_guard<std::mutex> lock(_Mutex());
  if (!_liveInstancerSceneIndices) {
    return 0;
  }
  _CompactInstancerLocked();
  return _liveInstancerSceneIndices->size();
}
