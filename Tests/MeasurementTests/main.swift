// Only the optional trace writer is stubbed. Pixel matching and quaternion projection are production code.
private final class VisualEstimatorShadow {
    func submit(reference: [Float], current: [Float], gridSize: Int, previousTime: Double,
                time: Double, sourceStep: CGFloat, width: Int, height: Int,
                visual: VisualMotionObservation?, productionEstimator: String) {}
}

var checks = 0
var failures = 0
func check(_ value: Bool, _ message: String) {
    checks += 1
    if !value { failures += 1; print("FAIL: \(message)") }
}
func texture(_ x: Double, _ y: Double) -> Float {
    var sum = 128.0
    for k in 1...18 {
        let f = Double(k)
        sum += 4 * sin(x * (0.09 + f * 0.053) + y * (0.17 + f * f * 0.0021) + f)
        sum += 3 * cos(x * (0.13 + f * f * 0.0037) - y * (0.11 + f * 0.059))
    }
    return Float(sum)
}
let n = 288
for (dx, dy) in [(0.15, -0.12), (0.5, 0.35), (1.0, -2.0), (-3.0, 1.0)] {
    let tracker = SubpixelFrameMotionTracker()
    let a = (0..<n*n).map { texture(Double($0 % n), Double($0 / n)) }
    let b = (0..<n*n).map { texture(Double($0 % n) - dx, Double($0 / n) - dy) }
    _ = tracker.processSampledGrid(a, timestamp: 1)
    if let result = tracker.processSampledGrid(b, timestamp: 1 + 1/60) {
        check(result.estimator == "ncc", "Real matcher, not a precomputed observation")
        check(abs(Double(result.deltaX) * Double(n) - dx) < 0.35 && abs(Double(result.deltaY) * Double(n) - dy) < 0.35, "Production NCC subpixel sign and magnitude")
        check(result.calibrationEligible, "Clean distributed texture remains eligible for calibration")
    } else { check(false, "Clean translation remains available") }
}
do {
    let tracker = SubpixelFrameMotionTracker()
    let flat = [Float](repeating: 100, count: n*n)
    _ = tracker.processSampledGrid(flat, timestamp: 1)
    check(tracker.processSampledGrid(flat, timestamp: 1 + 1/60) == nil, "Flat input remains missing, not a high-confidence zero")
    let split = (0..<n*n).map { Float($0 % n < n/2 ? 10 : 128) }
    for i in 0..<46 { _ = tracker.processSampledGrid(split, timestamp: 2 + Double(i)/60) }
    check(!tracker.vignetteValidated && tracker.latestVignetteOffset == .zero, "Ordinary contrast must not alter telescope alignment")
}
do {
    let tracker = SubpixelFrameMotionTracker()
    for i in 0..<46 {
        let frame = (0..<n*n).map { index -> Float in
            let x = Double(index % n), y = Double(index / n)
            return hypot(x - 143.5, y - 143.5) < 85 ? texture(x - Double(i) * 0.2, y) : 5
        }
        _ = tracker.processSampledGrid(frame, timestamp: 3 + Double(i)/60)
    }
    check(tracker.vignetteValidated, "Repeated circular boundary can enable ROI")
}
do {
    let estimator = QuaternionMotionEstimator()
    let tuning = StabilizationTuning(isEnabled: true)
    let samples = (0...60).map { i -> StabilitySample in
        let t = 0.9 + Double(i) * 0.002
        var s = StabilitySample.unavailable
        s.timestamp = t
        s.quaternionY = sin(0.1 * t / 2)
        s.quaternionW = cos(0.1 * t / 2)
        return s
    }
    _ = estimator.candidates(samples: samples, frameTime: 1, videoRotationAngle: 90, tuning: tuning,
        focalLengthPixelsX: 2160, focalLengthPixelsY: 3840, frameWidth: 2160, frameHeight: 3840)
    let result = estimator.candidates(samples: samples, frameTime: 1 + 1/60, videoRotationAngle: 90, tuning: tuning,
        focalLengthPixelsX: 2160, focalLengthPixelsY: 3840, frameWidth: 2160, frameHeight: 3840)
    let zero = result.first { abs($0.automaticOffset) < 0.0001 }
    check(zero != nil && abs(Double(zero!.deltaX) - 0.1 / 60) < 0.00001, "Project actual quaternion samples at capture times")
    check(zero != nil && !zero!.rollingWindowComplete, "Partial future IMU span is not a complete readout")
    check(result.allSatisfy { $0.rollingShearX == 0 && $0.rollingStretchY == 0 }, "Production cannot inject unvalidated rolling warp")
}
do {
    let estimator = QuaternionMotionEstimator()
    let tuning = StabilizationTuning(isEnabled: true)
    let samples = (0...60).map { i -> StabilitySample in
        var sample = StabilitySample.unavailable
        sample.timestamp = 0.9 + Double(i) * 0.002
        sample.quaternionY = sin(0.1 * sample.timestamp / 2)
        sample.quaternionW = cos(0.1 * sample.timestamp / 2)
        return sample
    }
    func measure(_ t: Double, _ values: [StabilitySample]) -> [GyroMotionCandidate] {
        estimator.candidates(samples: values, frameTime: t, videoRotationAngle: 90, tuning: tuning,
            focalLengthPixelsX: 2160, focalLengthPixelsY: 3840, frameWidth: 2160, frameHeight: 3840)
    }
    _ = measure(1, samples)
    let result = measure(1 + 1/60, samples)
    check(result.contains { $0.automaticOffset == 0 }, "Bracketed zero-offset IMU remains available")
    check(!result.contains { $0.automaticOffset == 0.008 },
          "Unbracketed future sample cannot be fabricated by holding the latest quaternion")
    estimator.reset()
    let gapped = samples.filter { $0.timestamp < 0.985 || $0.timestamp > 1.017 }
    _ = measure(1, gapped)
    check(measure(1 + 1/60, gapped).isEmpty, "Do not interpolate across an IMU delivery interruption")
}
// Low-contrast global texture must have a recovery path without a gyro hint.
// Its independent translation can restore a cached model but cannot create one.
do {
    var recovered = 0
    var totalTime = 0.0
    for contrast in [Float(0.10), 0.12, 0.15, 0.18, 0.22] {
        let tracker = SubpixelFrameMotionTracker()
        let a = (0..<n*n).map { 128 + (texture(Double($0 % n), Double($0 / n)) - 128) * contrast }
        let b = (0..<n*n).map { 128 + (texture(Double($0 % n) - 0.4, Double($0 / n) + 0.3) - 128) * contrast }
        _ = tracker.processSampledGrid(a, timestamp: 1)
        let start = Date.timeIntervalSinceReferenceDate
        let result = tracker.processSampledGrid(b, timestamp: 1 + 1/60)
        totalTime += Date.timeIntervalSinceReferenceDate - start
        if let result, result.estimator == "phase_recovery" {
            recovered += 1
            check(result.independentlyValidated && !result.calibrationEligible,
                  "Independent phase recovery is never self-calibration evidence")
            check(abs(result.deltaX * CGFloat(n) - 0.4) < 0.35 && abs(result.deltaY * CGFloat(n) + 0.3) < 0.35,
                  "Unseeded fallback follows actual subpixel translation")
        }
    }
    print("Independent weak-texture recoveries=\(recovered)/5, host mean analysis ms=\(totalTime * 200)")
    check(recovered > 0, "Production visual fallback must work without a validated gyro prior")
}
print("Production measurement checks: \(checks), failures: \(failures)")
if failures > 0 { exit(1) }
