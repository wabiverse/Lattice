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

import Foundation

/// The motion fields the demo can drive the field with, switchable live.
///
/// Every one is a *pure function of* `(motion, t)` - no state carried between
/// frames, no reads back into the store, no cross-instance dependencies. That
/// is what lets them be swapped mid-flight with nothing to reset: the next
/// frame simply poses every instance from its home position under a different
/// function. It is also what makes them trivially parallel, which is the whole
/// premise of the store underneath.
public enum LatticeKernel: String, CaseIterable, Sendable
{
  /// Spherical wave travelling out from the centre. The cheap baseline.
  case ripple
  /// Differential rotation - inner shells orbit faster than outer ones, so an
  /// even grid winds itself into spiral arms.
  case galaxy
  /// Divergence-free curl noise. Organic, smoke-like advection, the first
  /// genuinely expensive one.
  case curl
  /// A Lorenz attractor integrated per instance, every frame, from scratch.
  case lorenz
  /// Mandelbulb distance estimation - transcendentals in a loop, per instance,
  /// per frame. The deliberately absurd one.
  case mandelbulb

  /// Button label.
  public var label: String
  {
    switch self
    {
      case .ripple: "Ripple"
      case .galaxy: "Galaxy"
      case .curl: "Curl Noise"
      case .lorenz: "Lorenz"
      case .mandelbulb: "Mandelbulb"
    }
  }

  /// The MSL entry point.
  public var functionName: String
  {
    switch self
    {
      case .ripple: "kRipple"
      case .galaxy: "kGalaxy"
      case .curl: "kCurl"
      case .lorenz: "kLorenz"
      case .mandelbulb: "kMandelbulb"
    }
  }

  /// Rough per-instance cost, for the HUD.
  public var costBlurb: String
  {
    switch self
    {
      case .ripple: "~20 flops"
      case .galaxy: "~40 flops"
      case .curl: "18 fbm, 3 octaves"
      case .lorenz: "128 Euler steps"
      case .mandelbulb: "8 marches x 16 iters"
    }
  }
}

#if canImport(Metal)
  /// Every kernel in one library.
  ///
  /// Compiled once at startup into one `MTLLibrary`, with a
  /// `MTLComputePipelineState` per entry point. Switching
  /// is then just picking a different pipeline - no recompile, no stall,
  /// no dropped frame.
  ///
  /// The two struct layouts are the contract with Swift: plain `float` scalars,
  /// never `float3`, whose 16-byte MSL alignment would not match Swift's
  /// packing of the same fields.
  public let latticeKernelShader = """
    #include <metal_stdlib>
    using namespace metal;

    struct RippleMotion
    {
      float homeX; float homeY; float homeZ;
      float radius; float phase; float spin; float scale;
    };

    struct InstanceXform
    {
      float tx; float ty; float tz;
      float sx; float sy; float sz;
      float rx; float ry; float rz; float rw;
    };

    static inline float3 homeOf(const RippleMotion m)
    {
      return float3(m.homeX, m.homeY, m.homeZ);
    }

    // packs a pose. rotation is axis-angle -> quaternion, imaginary part first
    // then real, matching the GfQuatf(real, imaginary) reconstruction c++ side.
    static inline void writeInstance(device InstanceXform &o,
                                     float3 p, float3 s,
                                     float3 axis, float angle)
    {
      o.tx = p.x; o.ty = p.y; o.tz = p.z;
      o.sx = s.x; o.sy = s.y; o.sz = s.z;
      const float h = angle * 0.5f;
      const float sh = sin(h);
      const float3 a = normalize(axis + float3(0.0f, 1e-6f, 0.0f));
      o.rx = a.x * sh; o.ry = a.y * sh; o.rz = a.z * sh; o.rw = cos(h);
    }

    // ---- noise ------------------------------------------------------------

    static inline float hash13(float3 p)
    {
      p = fract(p * 0.1031f);
      p += dot(p, p.yzx + 33.33f);
      return fract((p.x + p.y) * p.z);
    }

    static inline float vnoise(float3 p)
    {
      const float3 i = floor(p);
      float3 f = fract(p);
      f = f * f * (3.0f - 2.0f * f);

      const float n000 = hash13(i + float3(0,0,0));
      const float n100 = hash13(i + float3(1,0,0));
      const float n010 = hash13(i + float3(0,1,0));
      const float n110 = hash13(i + float3(1,1,0));
      const float n001 = hash13(i + float3(0,0,1));
      const float n101 = hash13(i + float3(1,0,1));
      const float n011 = hash13(i + float3(0,1,1));
      const float n111 = hash13(i + float3(1,1,1));

      const float x00 = mix(n000, n100, f.x);
      const float x10 = mix(n010, n110, f.x);
      const float x01 = mix(n001, n101, f.x);
      const float x11 = mix(n011, n111, f.x);
      return mix(mix(x00, x10, f.y), mix(x01, x11, f.y), f.z);
    }

    static inline float fbm3(float3 p)
    {
      float sum = 0.0f, amp = 0.5f;
      for (int i = 0; i < 3; ++i)
      {
        sum += amp * vnoise(p);
        p *= 2.02f;
        amp *= 0.5f;
      }
      return sum;
    }

    // vector potential, its curl is divergence-free by construction, which is
    // what makes the resulting flow look like a fluid rather than a scatter.
    static inline float3 potential(float3 p)
    {
      return float3(fbm3(p),
                    fbm3(p + float3(31.416f, 17.0f, 47.853f)),
                    fbm3(p + float3(-19.2f, 83.7f, 11.5f)));
    }

    static inline float3 curlNoise(float3 p)
    {
      const float e = 0.22f;
      const float3 dx = float3(e, 0, 0);
      const float3 dy = float3(0, e, 0);
      const float3 dz = float3(0, 0, e);

      const float3 x0 = potential(p - dx), x1 = potential(p + dx);
      const float3 y0 = potential(p - dy), y1 = potential(p + dy);
      const float3 z0 = potential(p - dz), z1 = potential(p + dz);

      return float3((y1.z - y0.z) - (z1.y - z0.y),
                    (z1.x - z0.x) - (x1.z - x0.z),
                    (x1.y - x0.y) - (y1.x - y0.x)) / (2.0f * e);
    }

    // ---- mandelbulb -------------------------------------------------------

    // distance from `c` to the surface of the bulb, positive outside.
    //
    // pulled out as a function because the kernel calls it several times
    // per cube while marching, rather than once - which is also where nearly
    // all of that kernel's cost comes from.
    static inline float bulbDistance(float3 c, float power)
    {
      float3 z = c;
      float dr = 1.0f;
      float r = 0.0f;

      for (int i = 0; i < 16; ++i)
      {
        r = length(z);
        if (r > 2.0f) { break; }

        const float theta = acos(clamp(z.z / max(r, 1e-6f), -1.0f, 1.0f));
        const float phi = atan2(z.y, z.x);

        dr = pow(r, power - 1.0f) * power * dr + 1.0f;

        const float zr = pow(r, power);
        const float th = theta * power;
        const float ph = phi * power;
        z = zr * float3(sin(th) * cos(ph), sin(th) * sin(ph), cos(th)) + c;
      }

      return 0.5f * log(max(r, 1e-6f)) * r / max(dr, 1e-6f);
    }

    // ---- kernels ----------------------------------------------------------

    kernel void kRipple(device InstanceXform *out [[buffer(0)]],
                        const device RippleMotion *motions [[buffer(1)]],
                        constant float &t [[buffer(2)]],
                        constant uint &count [[buffer(3)]],
                        uint id [[thread_position_in_grid]])
    {
      if (id >= count) { return; }
      const RippleMotion mo = motions[id];

      const float wave = sin(mo.radius * 0.55f - t * 2.4f + mo.phase);
      const float swell = 1.0f + wave * 0.06f;
      const float k = mo.scale * (1.0f + wave * 0.25f);

      float3 p = homeOf(mo) * swell;
      p.y += wave * 1.35f;

      writeInstance(out[id], p, float3(k), float3(0,1,0), t * mo.spin + mo.phase);
    }

    kernel void kGalaxy(device InstanceXform *out [[buffer(0)]],
                        const device RippleMotion *motions [[buffer(1)]],
                        constant float &t [[buffer(2)]],
                        constant uint &count [[buffer(3)]],
                        uint id [[thread_position_in_grid]])
    {
      if (id >= count) { return; }
      const RippleMotion mo = motions[id];
      const float3 h = homeOf(mo);

      // inner shells orbit faster - the shear is what winds
      // an even grid into arms, the same way a real disc
      // galaxy gets them.
      const float r = length(float2(h.x, h.z));
      const float omega = 2.6f / (1.0f + r * 0.16f);
      const float a = t * omega + mo.phase * 0.35f;
      const float ca = cos(a), sa = sin(a);

      float3 p = float3(h.x * ca - h.z * sa, h.y * 0.16f, h.x * sa + h.z * ca);
      p.y += sin(r * 0.32f - t * 1.1f) * 1.8f;

      const float k = mo.scale * (0.65f + 0.8f * exp(-r * 0.035f));
      writeInstance(out[id], p, float3(k), float3(0,1,0), a);
    }

    kernel void kCurl(device InstanceXform *out [[buffer(0)]],
                      const device RippleMotion *motions [[buffer(1)]],
                      constant float &t [[buffer(2)]],
                      constant uint &count [[buffer(3)]],
                      uint id [[thread_position_in_grid]])
    {
      if (id >= count) { return; }
      const RippleMotion mo = motions[id];
      const float3 h = homeOf(mo);

      // advecting the *sample point* with time rather than integrating the
      // position keeps this stateless - the field drifts through the cubes
      // instead of the cubes accumulating through the field.
      const float3 sp = h * 0.045f + float3(0.0f, t * 0.10f, 0.0f);
      const float3 v = curlNoise(sp);

      const float3 p = h + v * 9.0f;
      const float speed = length(v);
      const float k = mo.scale * (0.7f + 0.5f * clamp(speed, 0.0f, 2.0f));

      writeInstance(out[id], p, float3(k), v, t * 0.7f + mo.phase);
    }

    kernel void kLorenz(device InstanceXform *out [[buffer(0)]],
                        const device RippleMotion *motions [[buffer(1)]],
                        constant float &t [[buffer(2)]],
                        constant uint &count [[buffer(3)]],
                        uint id [[thread_position_in_grid]])
    {
      if (id >= count) { return; }
      const RippleMotion mo = motions[id];

      // re-integrated from the home position every frame rather than carried
      // forward, so the kernel stays a pure function of (motion, t) and can
      // be switched away from and back to with no state to restore. it is also,
      // deliberately, a hundred and twenty-eight sequential steps per instance.
      float3 p = homeOf(mo) * 0.11f;
      const float dt = 0.0055f + 0.0025f * sin(t * 0.22f);

      for (int i = 0; i < 128; ++i)
      {
        const float dx = 10.0f * (p.y - p.x);
        const float dy = p.x * (28.0f - p.z) - p.y;
        const float dz = p.x * p.y - 2.6666667f * p.z;
        p += float3(dx, dy, dz) * dt;
        // lorenz is chaotic, a seed far off the attractor can take a very large
        // first step. clamping keeps a stray instance from reaching inf and then
        // NaN, which would silently drop it from the field.
        p = clamp(p, -80.0f, 80.0f);
      }

      // the attractor lives around z in 0..50 - recenter it and lay it on its
      // side so the butterfly faces the default camera.
      float3 q = float3(p.x, p.z - 25.0f, p.y) * 1.35f;
      const float a = t * 0.22f;
      const float ca = cos(a), sa = sin(a);
      q = float3(q.x * ca - q.z * sa, q.y, q.x * sa + q.z * ca);

      writeInstance(out[id], q, float3(mo.scale * 0.8f), float3(0,1,0), a + mo.phase);
    }

    kernel void kMandelbulb(device InstanceXform *out [[buffer(0)]],
                            const device RippleMotion *motions [[buffer(1)]],
                            constant float &t [[buffer(2)]],
                            constant uint &count [[buffer(3)]],
                            uint id [[thread_position_in_grid]])
    {
      if (id >= count) { return; }
      const RippleMotion mo = motions[id];
      const float3 h = homeOf(mo);
      const float power = 8.0f + 3.0f * sin(t * 0.25f);

      // every cube walks onto the surface, rather than sitting on a grid slot
      // and being hidden when it misses.
      //
      // sampling the bulb on the grid and keeping the hits wastes most of the
      // field - only a few thousand cubes of the hundred thousand land near the
      // surface - and the ones that survive are still on a regular lattice, so
      // the result reads as moire rather than as a fractal. marching instead
      // puts all hundred thousand *on* the surface, at irregular positions.
      //
      // each cube gets its own ray out of the centre. the jitter matters: cubes
      // sharing a grid diagonal have identical directions and would otherwise
      // converge on exactly the same landing point.
      float3 dir = normalize(h + float3(1e-5f));
      dir = normalize(dir + float3(sin(mo.phase * 3.1f),
                                   cos(mo.phase * 2.7f),
                                   sin(mo.phase * 1.9f)) * 0.05f);

      // sphere-trace inward from outside the bulb. stepping by the
      // distance estimate is safe because it never overshoots the
      // surface.
      float dist = 2.0f;
      for (int s = 0; s < 8; ++s)
      {
        const float d = bulbDistance(dir * dist, power);
        // a negative estimate means we are inside the set,
        // so this also catches an overshoot rather than
        // letting it creep further in.
        if (d < 0.004f) { break; }
        dist -= d;
      }

      // back out of the bulb's domain into the field's world
      // scale, then spin the whole thing so the silhouette
      // reads as solid.
      const float a = t * 0.3f;
      const float ca = cos(a), sa = sin(a);
      const float3 s = dir * dist * 46.0f;
      const float3 p = float3(s.x * ca - s.z * sa, s.y, s.x * sa + s.z * ca);

      writeInstance(out[id], p, float3(mo.scale * 0.8f), float3(0,1,0), a);
    }
    """
#endif
