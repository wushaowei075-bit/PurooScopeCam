# Phased Execution Plan

## Phase 1: MVP Capture

Implemented in this scaffold:

- SwiftUI app shell with a full-screen camera workflow.
- AVFoundation session using the back wide camera.
- Photo capture and silent video recording to the Photos library.
- System stabilization preference selection: Off, Auto, Balanced, Strong.
- Zoom, exposure bias, focus lock, and exposure lock controls.
- Core Motion shake score with stable, warning, and heavy shake bands.
- UI surfaces sized for repeated field use rather than a marketing page.

Primary files:

- `PurooScopeCam/Services/CameraController.swift`
- `PurooScopeCam/Services/MotionStabilityMonitor.swift`
- `PurooScopeCam/Views/CameraScreen.swift`
- `PurooScopeCam/Views/ControlPanelView.swift`

Validation still needed on macOS/Xcode:

- Build the `PurooScopeCam` scheme.
- Run on a real iPhone.
- Confirm which stabilization modes are supported by each target device and
  selected capture format.
- Tune the default frame rate and exposure behavior for telescope adapters.

## Phase 2: Strong Real-Time Stabilization

Code extension points are present in `FrameStabilizationEngine`:

- Feed gyro and frame timestamps into a single stabilization estimate.
- Reserve crop margin from a larger input frame.
- Smooth the camera path with a low-pass or Kalman-style filter.
- Add a Metal/Core Image renderer that crops, translates, rotates, and scales
  each frame into a stabilized preview/output surface.
- Replace the current preview layer with a processed Metal preview when the
  custom stabilizer is enabled.

Current scaffold status:

- `MotionStabilityMonitor` publishes high-magnification shake samples.
- `CameraScreen` forwards those samples into `CameraController`.
- `CameraController` forwards motion samples to `FrameStabilizationEngine`.
- `FrameStabilizationEngine` emits a placeholder gyro-driven transform that
  can be applied by a future Metal/Core Image renderer.

Next implementation tasks:

1. Add a `CVMetalTextureCache` renderer.
2. Store a short motion ring buffer keyed by `CMTime`.
3. Add Vision or custom phase-correlation registration for residual drift.
4. Export stabilized video with `AVAssetWriter`.

## Phase 3: Burst Photo Alignment

Code extension points are present in `BurstPhotoCoordinator`:

- Capture plan values for frame count and frame interval.
- A scoring model for sharpness and motion quality.
- A result model for later alignment/stacking output.

Current scaffold status:

- `CameraController.captureBurst(plan:)` triggers a timed photo sequence.
- `BurstPhotoCoordinator` contains the selection model for later sharpness and
  shake scoring.

Next implementation tasks:

1. Capture RAW or high-quality still frames where supported.
2. Score frames with Laplacian variance or a Metal sharpness kernel.
3. Align the best frames using translation/homography estimation.
4. Stack aligned frames to reduce noise and sharpen moon/landscape detail.

## Product Guardrails

- Strong stabilization must visibly crop the field of view.
- No app-only algorithm can recover detail once exposure blur is baked into a
  frame.
- The first supported hardware path should assume a rigid telescope adapter,
  tripod, and physical shutter trigger or timer.
