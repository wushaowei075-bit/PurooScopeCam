# iOS reliability and capture fixes

Release: 0.1.0 (24). Existing Android working-tree changes are excluded.
The stabilization gains, default 1.5x crop, optical magnification behavior and brand styling are preserved.

## Implemented

| Audit item | Change | Verification boundary |
| --- | --- | --- |
| Media lost after Photos failure | Persist completed captures in Documents/PendingCaptures; delete only after Photos reports success; expose retry count/action | Denial and storage-full recovery still need device testing |
| Background/interruption recording | Finish recording before stopping capture; bounded background task; restart session after interruption; release microphone | Phone calls, lock screen and permission changes need a device |
| Recording tied to display | Feed the recorder on completed stabilization results, not MTKView draw; preserve bounded queues | Synthetic recorder test runs without display callbacks |
| Rotation during capture | Lock UI and camera orientation together during capture/finalization; restore device orientation afterwards | Physical rotations need a device |
| Wrong focus point after digital crop | Invert the same render transform used by the preview before mapping to sensor coordinates | Geometry round-trip checks pass; optical focus needs a device |
| Calibration freezes at 10,000 observations | Keep observation sequence monotonic instead of saturating its counter | Code review; long-session sensor testing remains |
| Reset starvation and stale results | Yield processing between frames; generation-tag input; discard obsolete transforms | Code review; live stress testing remains |
| Small-screen control hit areas | Fixed control band with overlapping preview where necessary; remove out-of-parent shutter offset; retain full-width portrait render aspect | Layout checks for seven viewport sizes; no simulator screenshots claimed |
| 1080 becomes 1072 | Use exact even 16:9 dimensions instead of rounding both axes independently to multiples of 16 | Actual 1080x1920, 1920x1080 and 3840x2160 encoding checked |
| Library errors and stale permissions | Refresh on foreground and Photos changes; loading progress, errors and retry; cancel stale callbacks; handle asset removal | Cloud/offline and permission interactions need a device |

## Capture capabilities

- Photos use AVCapturePhotoOutput at the active format's supported photo dimensions, then apply the shared digital crop/rotation/translation. This is not RAW and does not guarantee the sensor's advertised maximum megapixel count. Native still exposure occurs after the displayed video frame, so moving-scene timing and device-specific framing must be checked physically.
- Recording requests microphone permission and adds AAC audio using the same source clock as video. Denied permission permits silent recording with an explicit message.
- Burst is sequential, with one photo-processing operation at a time. All frames are retained; the highest basic sharpness score is marked as a favorite. No frames are automatically discarded.
- Recording session generations prevent queued work from a failed/finished recording contaminating a subsequent recording.
- Working recordings live in Documents/RecordingRecovery, not the purgeable temporary directory. Incomplete files after a crash are not claimed to be playable; completed but unsaved files remain accessible through app file sharing.

## Automated verification

CI compiles the actual CameraGeometry implementation and extracts the unchanged production recorder into a macOS test harness. It does not substitute a mock encoder.

- 233 geometry/focus/output/layout assertions.
- Empty recording fails cleanly and the same recorder can then be reused.
- Portrait 1080p without audio, landscape 1080p with PCM-to-AAC audio, and landscape 4K without audio.
- Decode saved tracks, verify dimensions, duration and increasing decoded presentation timestamps.
- These synthetic clips verify encoding correctness, not sustained 4K60 throughput, battery life, stabilization quality, audio lip sync or camera interruption recovery on an iPhone.

## Device acceptance sequence

1. At 1.5x and 3x, tap a target away from center; compare preview and saved photo framing in portrait and both landscape orientations.
2. Record speech for 20 seconds, stop, play it in the in-app library and repeat immediately. Rotate while recording: composition should stay in the starting orientation, then resume rotation after stopping.
3. During recording, lock the phone or switch apps; return and verify that the completed clip is saved and a new recording can start.
4. Deny Photos add permission, capture a photo/video, then restore permission in Settings and use the retry action. Confirm the original is not lost. Keep app data until all pending captures are saved.
5. Test local and iCloud photos, offline failure/retry, pinch/double-tap zoom, video playback, back and close. Change photo access in Settings and return.
6. Run at least 5 minutes of 1080p preview/recording with intermittent pans; separately test available 4K60 on the target phone for heat and dropped frames. Compare stabilization to the previous accepted version, without assuming this reliability release changes its strength.
