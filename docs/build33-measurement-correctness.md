# Build 33 measurement correctness

This release continues build 32. Camera layout, normal 1.5x crop, high-zoom crop policy, calibrated gyro fallback, lag candidates, lookahead blend, preview scheduling and exposure policy are retained. Android changes are excluded.

## Changes

- NCC requires both an absolute count and 45% consensus across at least two regions. Calibration requires 65% support, 12 blocks and three regions. Phase fallback cannot calibrate itself.
- NCC and production FFT share their common valid ROI. FFT applies a tapered mask and a grid-pixel disagreement limit against a previously calibrated gyro hint. Missing evidence remains missing.
- Vignette detection requires a nearly enclosing circular edge and three consistent observations. Brightness alone no longer masks dark scene details or emits a centering warning.
- Rolling-shutter warping is disabled in production pending measured format readout and scan axes. The experimental calculation requires complete equal-length windows; horizontal shear is converted from width-normalized displacement to pixel slope.
- Focus uses the actually presented frame, not the sharpest historical frame. Full-resolution stills match their exposure timestamp to lightweight video transform history; stale/missing contexts produce an explicit error instead of applying an unrelated transform. Video snapshots still select an image and its own transform together. The still image is center-cropped to the video source aspect before applying that transform.
- Smart shutter observer registration safely handles synchronous callbacks and timeout races. Motion-sample access is locked.
- The green fixed marker remains a composition marker, not a claimed subject tracker. Its position, appearance and double-tap interaction are unchanged. Misleading 4K/lossless snapshot wording is removed.

## Diagnostics without a layout change

Long-press the existing PUROO brand title. Start a diagnostic recording (maximum 2 minutes), then use the same menu to finish and export. Traces remain local and contain motion data plus at most 12 low-resolution scene pairs. A confirmation explains this before recording. Backgrounding ends a session; the most recent file can be exported after relaunch.

Format 10 records actual estimator provenance, calibration eligibility, ROI validation, lookahead duration, readout-window completeness and requested/applied rolling parameters. Existing capture, presentation, crop-budget and GPU timing remain. The offline reader supports formats 8 through 10. The unmasked FFT shadow is diagnostic only and is compared against NCC before any fallback, never against itself.

## Validation

- Local Python replay tests cover legacy and v10 provenance; pass locally.
- CI geometry tests add physical shear magnitude in both orientations and still/video source-aspect alignment.
- CI diagnostics tests cover minority consensus, calibration gates, fixed-rim false-zero rejection, ordinary split lighting, masked FFT, incomplete readout, timestamp selection and synchronous shutter observer cleanup.
- A new CI harness compiles the production NCC tracker and quaternion estimator, rather than only injecting ideal motion observations. It tests subpixel shifts, featureless scenes, vignette persistence and incomplete IMU windows. Only optional trace writing is stubbed.
- Existing fusion, layout and production recorder harnesses remain enabled. Cloud results must be checked before distributing the IPA.

These are deterministic correctness checks, not proof of on-device parity with another camera. Same-device stationary fine shake, pan-stop, focused still capture and sustained 4K60 recording remain required field checks.

The photo timebase follows [Apple's AVCapturePhoto timestamp contract](https://developer.apple.com/documentation/avfoundation/avcapturephoto/timestamp): capture time synchronized with the session clock. Timestamp matching is bounded to 0.75 video-frame intervals; no pre-shutter quality-selected transform is substituted when matching fails.
