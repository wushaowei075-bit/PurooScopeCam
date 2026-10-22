# Build 38: preserve stabilization across zoom

## Evidence and scope

Build 37 device traces showed two long gyro-inactive intervals after zoom changes:
25.77 seconds after 2x to 3x, and at least 36.5 seconds after 3x to 4.3x.
Accepted calibration samples reset to zero on display-zoom changes. The two-second
learning timeout repeatedly discarded sparse subsequent observations. Camera and
IMU delivery continued; the crop budget was not exhausted in the final interval.

The failed intervals do not have raw replay image pairs. State-transition tests
therefore use synthetic coherent signals, not a claim of exact image replay or
measured real-device improvement. Original videos and traces remain local.

## Changes

- Pass actual focal lengths, buffer geometry, capture rotation and physical
  camera/system-stabilization identity into fusion before guided visual search.
- Transport both visual and IMU correlation history and low-band filter state
  into the new focal units. Preserve validated optical gain and selected IMU lag.
  Focal pixels already contain hardware zoom: do not apply zoom twice to gain.
- Exclude radial zoom-flow frames from fusion measurements, and hold calibration
  fitting for 180 ms after the last focal transition. Existing gyro correction
  remains available during a compatible zoom transition.
- Retain at most 256 accepted observations per lag within 30 seconds. Sparse
  learning gaps no longer erase evidence every two seconds. Retention alone does
  not authorize output: preserve the existing eight-second hold/two-second fade.
- A suspended validated model requires three fresh agreeing observations to
  resume. Six contradictory independent observations revoke the model. A genuine
  camera/format/rotation change, time discontinuity or expired evidence resets it.
- Allow unseeded phase translation only after texture and correlation validation
  in at least three image quadrants. Such translation can support visual fallback
  and confirm a previously calibrated model, but cannot calibrate the gyro itself.
  A phase-seeded NCC retry still must pass the original NCC calibration gates.
- Trace v11 records projection transitions, rejection reasons and independent
  validation. The same 12-pair raw replay limit is spread across the session,
  including measurement gaps, rather than consumed at startup.

## Preserved

UI layout, orientation presentation, zoom controls, crop curve, trajectory gains,
preview delay, renderer, exposure policy and recording path are unchanged. The
baseline remains 1.5x; the existing high-zoom crop curve remains capped at 2.4x.
Android work in the same checkout is outside this change.

## Verification and acceptance

CI runs production Swift fusion/controller code against build 37 and this version,
including stepped/ramped/display-only/focal-only zoom, sparse learning, suspended
recovery, contradiction rejection, incompatible projections and all existing
crop/tremor/quiet-hold tests. Native image-matching tests cover unseeded recovery;
geometry, zoom, diagnostics and real synthetic MOV recorder tests also run.

Windows replay parser tests pass locally; iOS compilation and native tests require
the cloud Mac. These checks cannot establish telescope stabilization parity or
the on-device 4K60 processing budget.

Device acceptance: hold at 1x, switch 2x/3x/5x, slide continuously up/down, return
to 1x; verify no multi-second loss of correction. Repeat on a low-texture wall
then a textured scene and export the trace. Check the new recovery path's analysis
duration, preview continuity, incorrect global-motion matches and gyro validity.
