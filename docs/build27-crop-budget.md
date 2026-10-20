# Build 27: Output-Space Crop Budget

## Scope

This release changes the crop trajectory controller and adds budget diagnostics.
It preserves the UI, 1.5x stabilization crop, user zoom, capture controls, visual
estimator, gyro fusion weights, preview delay, and recording path.

Build 26's same-scene comparison and local trace exposed two controller issues:

- Boundary pressure used low-path correction before the 1.5x render conversion,
  whereas final crop use was measured after that conversion.
- The combined translation soft limiter compressed small high-band corrections
  once the slow offset exceeded its 72% knee, even before the physical edge.

The recordings are separate handheld inputs, not a controlled attenuation test.
They establish an output gap, not the amount this change will recover.
Raw recordings and diagnostic traces remain local and are not in this repository.

## Changes

1. Compute boundary pressure in output-viewport units.
2. Allocate the requested high correction first. Limit the slow offset to the
   remaining symmetric crop budget. Interior correction stays linear.
3. Feed the constrained slow offset back into the virtual trajectory to avoid
   hidden accumulated displacement delaying a later reversal.
4. Release only new outward slow motion during non-pan boundary handling. Do not
   re-center a stored translation after the hand stops or pull a quiet axis.
5. Log requested/applied low and high corrections per axis, plus pre-follow crop
   use, in trace format 9. The local replay tool still accepts format 8; absent
   budget fields are reported as missing, not zero correction loss.

Roll retains its existing remaining-budget limit and soft limiter. Translation
still has a hard geometric limit; high-band priority cannot stabilize arbitrary
motion when the available input area is exhausted. It can also change framing
when the slow offset must yield space at the edge.

## Verification

The production-code Swift harness covers allocator sweeps, 9 Hz tremor around an
80% biased crop at 24/30/60 fps, both axes and directions, stopped translation,
long pans, reversal, roll bounds, and stabilization-off identity.

These checks isolate controller behavior. They do not validate camera/IMU timing,
optical blur, feature accuracy, or real-device improvement. CI also runs the
existing geometry, fusion, FFT/diagnostics, and production recorder tests.

## Device Acceptance

- Compare fine stationary shake near the center and after reframing.
- Pan gently and stop: no new automatic translation return after stopping.
- Pan farther toward the boundary and reverse: no black edges or prolonged
  dead zone caused by accumulated slow-path displacement.
- Compare with the same lens, user zoom, lighting and capture format. Export the
  build 27 trace with the screen recording to check actual budget allocation.

FFT fallback, visual confidence policy, gyro timing and preview scheduling are
deliberately deferred so this change can be evaluated independently.
