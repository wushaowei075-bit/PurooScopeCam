# Puroo Scope Cam

Puroo Scope Cam is an iOS camera prototype for shooting through a telescope.
The first milestone focuses on a practical MVP:

- AVFoundation camera preview and capture.
- System video stabilization mode selection.
- Manual-friendly exposure, zoom, focus, and recording controls.
- Core Motion shake meter tuned for high magnification.
- Extension points for gyro-assisted and image-registration stabilization.
- Burst capture planning for later multi-frame alignment and stacking.

## Requirements

- macOS with Xcode 16 or newer.
- iOS 17+ deployment target.
- A real iPhone is required for camera, stabilization, and gyro validation.
  The iOS Simulator cannot validate the core capture behavior.

## Open

Open `PurooScopeCam.xcodeproj` in Xcode, choose the `PurooScopeCam` scheme,
then run on a physical iPhone.

## Current Phase

This folder starts Phase 1 and lays the code structure for Phases 2 and 3.
See `docs/PHASED_EXECUTION.md` for implementation status and next actions.

