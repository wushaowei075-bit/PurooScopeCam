# Build 35: immediate held zoom and 20x user range

## Requested behavior

- Holding a preset for 220 ms now opens the continuous scale without requiring movement.
- Releasing leaves it visible for 1.2 seconds, then fades it out. Retouching the visible scale
  immediately resumes dragging and resets the deadline. Hidden preset buttons cannot fire.
- The expanded scale has a 288 x 70 pt touch surface. When collapsed, only the visible
  216 x 48 pt preset row accepts touches, leaving surrounding preview taps available for focus.
- Capture disable, range/mode changes, backgrounding and removal cancel the interaction/timer.
- The user zoom range is now 1...20 relative to the same baseline. Stabilized 20x requests
  effective display zoom 30; direct-mode 20x requests 20. The previous 6.7 limit was 10 / 1.5.

## Scope and limits

The old stabilization crop curve is unchanged throughout effective zoom 1.5...10.
Above 10 the crop stays at 2.4; raising the overall zoom ceiling does not dilute the crop
reserve at existing zoom settings. UI layout outside the zoom area and watermark removal
from build 34 are preserved. There is no new stabilization-strength tuning in this build.

The device format's actual hardware zoom ceiling is respected. The maximum effective zoom
is solved with the same crop used by the renderer, preventing a falsely high label or a
hardware/crop mismatch. A format capped below 12.5 hardware zoom cannot reach 20 relative
zoom with the existing 2.4 crop policy; that device/format reports its actual smaller limit.
No speculative extra crop or unsupported device command is used to fake 20x.

20x is digital enlargement, not an optical lens change or a promise of 20x image detail.
Static tests cover range conversion, held activation, retention, retouch, cancellation,
device-limit consistency and unchanged historical crop values. Real touch timing, actual
device maximum, thermal behavior and zoomed image quality require device acceptance.

## Comparison evidence

The 2026-10-22 screen recordings are analyzed separately under
`E:/puroo_cam_ios/analysis_artifacts/compare-20261022-build34/`.
That analysis does not silently become permission for a new fusion/trajectory experiment.
