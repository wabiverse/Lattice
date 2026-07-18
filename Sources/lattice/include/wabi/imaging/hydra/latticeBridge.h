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

#ifndef __WABI_IMAGING_HYDRA_LATTICE_BRIDGE_H__
#define __WABI_IMAGING_HYDRA_LATTICE_BRIDGE_H__

/* Deliberately free of both <pxr/...> and the generated wabi/scene/usd.h.
 *
 * This is the only header in the target that Swift imports, and Swift must not
 * re-import the C++ view of its own LatticeUSD module through it. Everything
 * here is plain C over opaque pointers. */

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Registers ``LatticeHydraSceneIndex`` to be appended to the scene index chain
 * of every renderer.
 *
 * @param latticeSource An unmanaged pointer to the Swift ``LatticeXformSource``
 *        that the scene index reads live transforms through, obtained with
 *        `Unmanaged.passRetained(source).toOpaque()`. The bridge retains it for
 *        the process lifetime; the caller must keep the Swift object alive.
 *
 * @warning Must be called *before* the `UsdImagingGLEngine` is constructed.
 *          Hydra builds its render index - and with it the scene index chain -
 *          during engine construction, and consults the registry exactly once
 *          at that point. Registering afterwards silently does nothing.
 */
void LatticeHydraRegisterSceneIndex(void *latticeSource);

/**
 * Drains the frame's dirtied paths out of the ``LatticeXformSource`` and sends
 * the corresponding `PrimsDirtied` notices to every live scene index.
 *
 * Call once per frame from the mutation phase - after the frame's writes have
 * landed and before `beginReadPhase()`. Draining is itself a mutation of the
 * dirty set, which is why it must not straddle the read phase.
 */
void LatticeHydraTick(void);

/**
 * The number of live ``LatticeHydraSceneIndex`` instances.
 *
 * Zero after the engine exists means the registration was made too late to be
 * picked up.
 */
size_t LatticeHydraLiveSceneIndexCount(void);

/* ------------------------------------------------------------------------
 * Instancer path
 *
 * The per-prim scene index above overrides the xform of every moving prim,
 * costing Hydra one dirtied prim per cube per frame. These register the
 * instancer variant instead, which overrides the instance-rate primvars of a
 * single `UsdGeomPointInstancer` - one dirtied prim regardless of instance
 * count. Only one of the two should ever be registered in a process.
 * ---------------------------------------------------------------------- */

/**
 * Registers ``LatticeInstancerSceneIndex``.
 *
 * @param latticeSource An unmanaged pointer to the Swift ``LatticeInstanceSource``,
 *        obtained with `Unmanaged.passRetained(source).toOpaque()`.
 *
 * @warning Same ordering rule as ``LatticeHydraRegisterSceneIndex``: this must
 *          run *before* the `UsdImagingGLEngine` is constructed.
 */
void LatticeHydraRegisterInstancerSceneIndex(void *latticeSource);

/** Sends the instancer's `PrimsDirtied` if it was marked this frame. */
void LatticeHydraInstancerTick(void);

/** The number of live ``LatticeInstancerSceneIndex`` instances. */
size_t LatticeHydraLiveInstancerSceneIndexCount(void);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // __WABI_IMAGING_HYDRA_LATTICE_BRIDGE_H__
