# Build 34: compact zoom controls

## Scope

- Replace the always-visible mixed slider/preset bar with 1 / 2 / 3 / 5 round targets.
- A 220 ms hold followed by at least 6 pt rightward movement reveals the continuous scale.
  After expansion, movement in either direction adjusts zoom; release or cancellation closes it.
- Keep 54 x 48 pt touch targets stable while the visual scale expands above them.
  Native long-press recognition cancels the button press, so release cannot also select a preset.
- Remove the watermark toggle and live plaque. The existing optional photo compositor stays
  dormant behind a private false flag; photos do not silently acquire a watermark.
- No changes to preview framing, shutter/gallery layout, stabilization measurements or fusion.

## Zoom semantics and reliability

The four values are relative to the current baseline view. With stabilization on, 1x retains
the existing 1.5x EIS crop; 2x / 3x / 5x request effective display zooms 3 / 4.5 / 7.5.
With stabilization off the baseline is 1. The engine still receives its original effective
display zoom, with its existing crop policy and maximum of 10. The telescope badge continues
to report effective total magnification. No unimplemented lens switching is implied.

The old bar combined native button taps with a simultaneous parent drag, resized itself
during tracking, and enqueued a hardware configuration for every touch update. These were
code-level reliability risks, not a device-reproduced diagnosis of every reported failure.

New requests replace pending obsolete samples. There is one camera queue consumer, yielding
between applications. The control shows the requested value immediately, while preview
rendering still uses applied hardware zoom. Older completions cannot rewind the control.
Device clamping/failures reconcile to the actual zoom. Presets, continuous drag and pinch
all use the same submission method. Mode reapplication reads requested zoom on its owning queue.

## Verification

CI runs production-model checks for mapping, preserved crop limits, rightward activation,
no expansion jump, reversed drag, cancellation, repeated use, rapid-request coalescing,
stale-publication rejection and concurrent queue draining. Existing stabilization, geometry,
measurement and recorder harnesses remain enabled. CI also compiles the UIKit/SwiftUI view.

These tests do not reproduce physical touches on an iPhone. Device acceptance remains:

1. Tap 1 / 2 / 3 / 5 repeatedly; compare selected value and actual field of view.
2. Hold any circle briefly, slide right, then left, and release. The scale must close and
   release must not jump back to the circle under the original finger position.
3. Repeat after taking a photo, ending a burst, changing quality, rotating and recording.
4. Pinch in the preview; subsequent held dragging must start at the current zoom.
5. Confirm baseline framing/stabilization is unchanged and watermark UI/output is absent.
