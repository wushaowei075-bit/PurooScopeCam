# Stabilization Pipeline V2

This document describes the only active preview and recording stabilization
pipeline. Earlier mode-specific gyro, integer-pixel visual, and preview-layer
transform paths have been removed.

## 1. System Stabilization And Diagnostics

- `AVCaptureVideoDataOutput` requests low-latency system stabilization before
  custom processing. Lens OIS remains device-managed.
- Camera frames carry presentation time, exposure duration, dimensions, and
  intrinsic focal lengths into one stabilization engine.
- Core Motion samples device attitude at 240 Hz and retains a timestamped ring
  buffer.
- Each run writes motion and controller output as JSONL under
  `Documents/PurooStabilizationTraces`. iOS file sharing is enabled so traces
  can be exported without another debug build.

## 2. Subpixel Visual Motion And One-Frame Buffer

- The visual tracker samples the luma plane into a 192 x 192 center-weighted
  grid.
- Normalized patch correlation, robust inlier rejection, and parabolic peak
  fitting produce subpixel frame-to-frame translation.
- Every source frame has a timestamp-matched transform and ready marker.
- The Metal renderer displays each processed frame once, with a deterministic
  one-frame look-ahead. Frames skipped by analysis are never paired with a
  transform from another timestamp.

## 3. Virtual Camera Trajectory

- Measured motion is integrated into the raw camera path.
- A critically damped virtual path follows deliberate pans quickly and follows
  static framing slowly.
- Direction coherence distinguishes a pan from alternating hand tremor.
- Velocity, acceleration, jerk, and crop-bound constraints prevent jumps and
  keep the crop window inside the 1.5x reserve.
- The overview yellow frame is driven by the same final crop correction used
  for rendering.

## 4. Quaternion IMU And Complementary Fusion

- Exposure-midpoint timestamps are used for attitude interpolation.
- Relative quaternions avoid Euler angle wrap and preserve high-frequency
  rotation.
- Candidate IMU offsets are correlated with visual motion to estimate sensor
  timing automatically.
- A learned 2 x 2 calibration maps device attitude axes to image axes, including
  sign, rotation, and cross-axis coupling.
- Visual low-frequency motion corrects drift while calibrated gyro motion owns
  the high-frequency band.

## 5. Stabilized Recording

- Preview and recording use the same source frame and final render transform.
- `AVAssetWriter` receives the original capture presentation timeline relative
  to the first written frame; no synthetic frame counter is used.
- Duplicate or non-monotonic timestamps are rejected.
- Output is H.264 MP4, capped at 1080 x 1920 while preserving source
  orientation and using the selected capture frame rate as encoder guidance.

## Real-Device Validation

1. Hold a detailed target still for at least five seconds so automatic
   calibration reaches a stable gyro-trust value.
2. Record ten seconds at 0%, 50%, and 100% strength without changing the scene.
3. Repeat with one slow horizontal pan and one stop after the pan.
4. Export the matching JSONL trace with each video and compare visual
   confidence, gyro trust, crop usage, analysis time, and dropped frames.
5. Treat a black edge, non-monotonic recording time, or yellow-frame movement
   that disagrees with the main preview as a pipeline defect rather than a
   tuning result.
