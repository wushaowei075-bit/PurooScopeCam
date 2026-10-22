# Build 37: stabilization continuity and orientation

## Scope and evidence

Baseline: build 36 / 5f18627. No UI layout, default 1.5x crop, crop budget,
trajectory strength, exposure policy, or visual search thresholds are changed.
The comparison folder contains build-34-era screen recordings, not a build-36
trace. Findings below are code-path findings and deterministic regressions, not
a claim that all field variability has been reproduced on an iPhone.

## Stabilization findings

1. Valid calibration was erased after two seconds without eligible NCC data.
   With no visual observation, fusion then output zero correction. Phase fallback
   also requires calibrated gyro, so the loss can disable both fallback paths.
2. Long, jointly quiet observations decayed regression energy below observability
   and erased previously validated gain. A quiet hand is not proof that the
   previously measured optical mapping is wrong.
3. If the calibrated IMU lag was unavailable, nearest-lag selection silently used
   another time offset with the former calibration. The quaternion interpolator
   also held an endpoint for up to 10 ms outside the sample window.
4. Physical orientation changes reconfigured video-data buffers, swapped source
   dimensions and reset the tracker, gyro calibration, crop trajectory, renderer
   queue and displayed-photo state. The first new correction was centered.

## Changes

- Validated calibration holds across up to eight seconds of visual loss during
  a continuous capture, fades during the next two seconds, then expires. This
  is a bounded continuity policy, not evidence that any eight-second interval
  is safe on every phone. Cold/unvalidated calibration still expires at two
  seconds. Missing IMU always has zero effective gyro weight.
- Jointly quiet, independently eligible NCC + IMU frames preserve existing gain
  without re-fitting it. This cannot establish a new calibration. Real sensor
  disagreements still enter the existing correlation rejection path.
- Zoom changes above 1% of the calibration anchor and capture gaps above 120 ms
  invalidate calibration before guided visual search, not after it.
- Only the exact selected lag can use its calibration. Quaternion endpoints
  must be bracketed, with no interpolation across IMU gaps above 25 ms.
- Video-data and still-photo capture connections remain at portrait (90 degrees).
  Device rotation changes UI glyphs and the requested export direction only.
  Saved stills rotate after their timestamp-matched stabilization/crop. Recorder
  direction is frozen at start and applied during the existing CI render, with
  actual landscape encoded dimensions. Preview buffers and focus coordinates
  never switch axes on device rotation.
- Repeated same-orientation notifications are ignored. Native movie fallback
  sets its metadata direction only when recording starts.

## Verification

CI runs new fusion regressions against the build-36 engine in characterization
mode, then against production build-37 code with failures enforced. It also runs
real production quaternion/NCC measurements, geometry, zoom, diagnostics, native
iOS compilation, and recorder encode/decode tests. Asymmetric red/green/blue
frames check actual orientation pixels in both landscape directions, upside-down
output, portrait and 4K, with audio and without display callbacks.

Remaining acceptance: repeated physical rotations on the target iPhone, hold / 
low-texture transitions / zoom changes / saved photo and video direction. Native
hardware exposure, OIS, actual IMU delivery and camera frame latency cannot be
certified by these synthetic tests. Exposure timestamps remain an explicitly
unverified half-exposure estimate; this release does not claim competitor parity.

Apple API reference: https://developer.apple.com/documentation/avfoundation/avcaptureconnection/videorotationangle
