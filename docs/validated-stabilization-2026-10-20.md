# Validated stabilization and same-frame diagnostics (build 26)

## Scope

The UI, slider, default 1.5x crop, output geometry, one-frame preview delay,
trajectory gains and system stabilization preference are unchanged. Android's
existing local changes are not part of this release. No proprietary implementation
was recovered or copied from the encrypted competitor executable.

## Ordered changes

1. **Evidence and presentation.** Trace format 8 separates selected/submitted/GPU
   completion/actual drawable presentation. A missing drawable no longer consumes
   a ready frame. GPU work is limited to two in-flight frames. Presentation gaps
   are measured relative to the selected FPS, not a fixed 25 ms threshold.
   Frame callbacks record mapped PTS, exposure, ISO, actual system stabilization,
   image orientation and IMU brackets. Exposure readings are device-at-callback,
   not guaranteed frame-specific sensor metadata. The existing PTS-minus-half-
   exposure convention is explicitly marked unverified, not silently retuned.
2. **Calibration.** A prior is no longer counted as measured calibration or given
   70% trust. Qualified small observations accumulate without the former 0.00025
   per-frame admission floor. At least 64 samples and an aggregate normalized RMS
   of 0.000025 are required, along with the existing correlation/residual tests.
   Invalid, missing, reversed, stale or wrongly scaled gyro data cannot take over
   the crop. Visual fallback starts immediately; there is no preview warm-up wait.
   More than two seconds without eligible evidence expires trust; a short dropout
   retains validated calibration. Rotation/format/system-mode changes reset it.
3. **Short exposure.** With stabilization enabled and continuous AE active, two
   consecutive one-second readings with sufficient ISO headroom allow a 1/120 s
   maximum. Two dark readings restore the device's default. AE, ISO, bias and
   focus remain automatic/user-controlled. Format limits and AE lock are respected.
   This may raise noise, and cannot remove blur in light too weak for short exposure.
   The actual cap is rechecked so tapping to focus cannot silently reset it while
   the controller's cached policy still says it is applied.
4. **Shadow comparison.** A 256x256 regularized FFT phase-correlation candidate
   processes the same sampled luminance grids as NCC every sixth eligible frame.
   It runs on a utility queue with one job allowed across compute and trace write;
   it never retains capture pixel buffers and never changes the crop. Weak spectral
   bins are regularized to avoid amplifying window leakage. PSR, peak ratio and
   displacement limits classify the candidate, not algorithm superiority.
   The first twelve low-resolution pairs in a trace include exact Float32 luminance
   for local replay (about 11 MB base64 total). They may contain recognizable scene
   content. No imagery or traces are uploaded by the app. Existing trace retention
   keeps recent sessions; the original full-resolution camera buffers are not saved.
5. **Rendering decision.** Retain the existing NV12 input and Metal-backed Core
   Image path until real GPU/presentation evidence justifies replacing it. Do not
   reduce capture/record resolution on the basis of a competitor resource name.

## Regression coverage

- Production fusion/trajectory: sub-threshold coherent signals at 24/30/60 fps,
  1x/10x/30x; cold start, wrong sign, quiet axis, wrong prior, missing IMU, stale
  evidence, long-run adaptation, brief dropout and unchanged crop boundaries.
- Exposure policy: bright/dark hysteresis, AE lock, stabilization off, format limits
  and nonfinite readings.
- Presentation metrics: submitted versus presented, dropped drawables, out-of-order
  callbacks, 24/30/60 fps and genuine long gaps.
- FFT: known integer/subpixel translations with brightness changes, direction/sign,
  textureless input, malformed grids and out-of-budget motion. These synthetic tests
  do not prove an improvement on real telescope footage.
- Existing geometry/layout/focus and video/audio recorder tests remain in CI.

The first CI run (commit `4bc7325`) passed 3,324 fusion/controller checks, all
geometry/layout checks, the new diagnostics tests, iPhoneOS Release compilation
and the existing recorder tests. Final package verification is recorded separately.

## Local replay

`tools/replay_stabilization.py <trace.jsonl> --output <summary.json>` reads the local
trace with NumPy, reports calibration/presentation/exposure/GPU statistics, and
replays the saved pairs using an independent implementation of the same FFT
measurement. It compares replay output to device output in source pixels and
reports NCC/FFT disagreement without mislabeling it as accuracy. Three local
tests cover known translations, blank images and trace parsing/presentation rate.
The app never uploads this data. Raw luminance pairs should be treated as photos
of the recorded scene when sharing a trace.

## Real-device acceptance still required

Same lens, telescope, scene, frame rate and 1.5x crop: record stable off/on stationary
handheld clips, a slow pan followed by a stop, and bright-to-dark transitions. Export
the corresponding trace with the footage. Inspect measured presentation rate/age,
calibration state and gain, exposure/ISO, IMU brackets and same-frame NCC/FFT agreement.
Agreement is not ground-truth accuracy. Do not promote FFT into production based on
agreement alone, or claim parity with the competitor from a successful build.

## API references

- https://developer.apple.com/documentation/avfoundation/avcapturedevice/activemaxexposureduration
- https://developer.apple.com/documentation/metal/mtldrawable/presentedtime
