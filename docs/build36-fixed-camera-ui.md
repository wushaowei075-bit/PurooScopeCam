# Build 36: Fixed Camera Controls and Packaging Branding

## Scope

- Camera UI remains in portrait device coordinates when the phone is held sideways.
- Text and directional glyphs rotate in place. Controls do not switch into the old compact landscape layout.
- Camera buffers, stabilization coordinates and saved media retain the actual capture orientation.
- The preview applies an exact quarter-turn only after stabilization, filling the existing 9:16 display rectangle without a second crop. Physically this is a 16:9 landscape view when the phone is sideways.
- The display is not stretched to the phone's wider screen aspect: the existing camera control region and system safe areas remain.
- Recording/capture orientation stays locked during a capture, then follows the device again.

## Coordinate Safety

Each queued frame stores its capture rotation. The engine and recorder use a logical viewport in that capture orientation; only display rendering rotates back into fixed UI coordinates. Focus inversion uses the orientation of the actually presented frame, not the newest device notification. Thumbnail bounds rotate around the same on-screen center, preserving crop-window tap coordinates.

Geometry tests cover all four quarter-turns, three screen widths, three crop factors, stabilization translation/roll, inverse focus mapping, and preview versus saved-media field of view. These deterministic checks do not establish real-device UI or sensor acceptance.

## Optical Magnification

The former telescope picker did not change physical optics and could not measure a telescope's true magnification. Its value was a prior for gyro scale calibration (`StabilizationTuning.opticalMagnification` / `applyReferenceMagnification`), also used in estimated total-magnification text. That total was not a measured optical magnification or verified equivalent focal length.

Remove the picker and estimated-total label from the camera UI, while keeping the existing internal default prior and online calibration untouched. Removing this UI is not equivalent to disabling gyro compensation or claiming automatic optical identification.

## Visual Simplification

- Remove grid/level controls and their preview overlay.
- Smaller, plain white PUROO brand label; no gradient or colored decorative border.
- Main badges use black at 24% opacity, zoom presets 18% / 36%, expanded zoom 36%.
- Shutter ring and album edges no longer change to decorative accent colors. Functional focus/crop indicators and recording red remain.
- Keep quality/FPS selection, stabilization controls, photo/video switch, burst, album, focus/exposure and build-35 zoom behavior.
- Default 1.5x stabilization crop and all fusion/trajectory tuning remain unchanged.

## App Icon

Reference: user-provided packaging artwork `大单筒7x9x18.png`, containing the white circular negative-space P on mustard yellow. Built-in image generation used this reference to produce the icon, then FFmpeg converted it to opaque RGB 1024x1024 for the asset catalog. No wordmark, gradient, border or rounded-icon mask was requested.

Prompt specification: faithfully preserve the complete circular P silhouette, open lower-left stem and white round counter; center at approximately 72% square width on flat packaging yellow; omit all packaging text, outlines and other objects.

Project asset: `PurooScopeCam/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`.

## Device Acceptance

1. Turn the phone left and right before shooting. Control centers must remain fixed and the scene must fill the same preview rectangle without the former landscape inset.
2. Focus on objects near each visible corner in both landscape directions; test exposure drag and focus lock.
3. Capture photos and videos in each orientation. Playback must be upright, 16:9, and match the preview framing; recording must not change orientation mid-file.
4. Check zoom presets and hold/linger behavior, quality selection, burst and album. No telescope-magnification, grid or level controls should remain visible.
5. Confirm the packaging P icon after installation. iOS may retain an older Home Screen icon temporarily.

Windows cannot run the native iOS UI here. Codemagic compilation and deterministic tests are gates, not a substitute for the above phone checks.
