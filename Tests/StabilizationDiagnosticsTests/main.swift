import Foundation

var checks = 0
var failures = 0
func check(_ value: Bool, _ message: String) {
    checks += 1
    if !value { failures += 1; print("FAIL: \(message)") }
}

var policy = StabilizationExposurePolicy()
func exposure(_ seconds: Double, _ iso: Double, _ offset: Double = 0, enabled: Bool = true, automatic: Bool = true) -> Double? {
    policy.update(enabled: enabled, automatic: automatic, duration: seconds,
        iso: iso, maximumISO: 1600, targetOffset: offset)
}
check(exposure(1/60, 100) == nil, "Do not change exposure on one transient bright sample")
check(exposure(1/60, 100) == 1/120, "Choose 1/120 when ISO headroom permits")
check(exposure(1/120, 1500, -1) == 1/120, "Dark transition has hysteresis")
check(exposure(1/120, 1500, -1) == nil, "Restore native AE in low light")
check(exposure(1/60, 100) == nil, "Do not oscillate back immediately")
check(exposure(1/60, 100) == 1/120, "Recover fast exposure after sustained bright conditions")
check(exposure(1/60, 100, enabled: false) == nil, "Stable off restores AE default")
check(exposure(1/60, 100, automatic: false) == nil, "Respect AE lock and custom exposure")
check(exposure(.nan, 100) == nil, "Reject invalid readings")
check(StabilizationExposurePolicy.boundedDuration(1/120, minimum: 1/100, maximum: 1) == 1/100, "Respect format minimum")
check(StabilizationExposurePolicy.boundedDuration(1/120, minimum: 1/1000, maximum: 1/240) == 1/240, "Respect format maximum")
check(StabilizationExposurePolicy.boundedDuration(1/120, minimum: .nan, maximum: 1) == nil, "Invalid format fails closed")

for fps in [24, 30, 60] {
    var metrics = PresentationMetrics()
    metrics.submit()
    check(metrics.presented == 0, "Enqueue/submission is not presentation")
    metrics.present(at: 0, targetFPS: fps)
    check(metrics.presented == 0, "A dropped drawable has no presentation timestamp")
    for i in 0..<fps { metrics.present(at: 10 + Double(i) / Double(fps), targetFPS: fps) }
    check(abs(metrics.fps - Double(fps)) < 0.001, "Measure wall-clock FPS")
    check(metrics.lateIntervals == 0, "30fps must not be classified as a display stall")
    metrics.present(at: 20, targetFPS: fps)
    check(metrics.lateIntervals == 1, "Count a real display interruption")
    metrics.present(at: 19, targetFPS: fps)
    check(metrics.presented == fps + 1, "Ignore out-of-order completion")
}

let estimator = PhaseCorrelationEstimator()
let n = 288
// Smooth reproducible texture, with non-periodic content for an unambiguous peak.
func texture(_ x: Double, _ y: Double) -> Float {
    var result = 110.0
    for k in 1...18 {
        let f = Double(k)
        result += 4 * sin(x * (0.09 + f * 0.053) + y * (0.17 + f * f * 0.0021) + f)
        result += 3 * cos(x * (0.13 + f * f * 0.0037) - y * (0.11 + f * 0.059))
    }
    return Float(result)
}
let reference = (0..<n*n).map { texture(Double($0 % n), Double($0 / n)) }
for (dx, dy) in [(0.0, 0.0), (1, -2), (-3, 1), (0.1, -0.1), (0.35, -0.6), (-0.7, 0.2), (2.35, -1.8), (10, 0)] {
    let current = (0..<n*n).map { texture(Double($0 % n) - dx, Double($0 / n) - dy) * 1.15 + 8 }
    if let result = estimator.estimate(reference: reference, current: current, gridSize: n) {
        print("Phase synthetic \(dx),\(dy) -> \(result.dx),\(result.dy); PSR=\(result.peakToSidelobe)")
        if abs(dx) <= 8 {
            check(result.accepted, "Accept textured bounded shifts")
            check(abs(result.dx - dx) < 0.35 && abs(result.dy - dy) < 0.35, "Correct axes, sign and subpixel shift")
        } else { check(!result.accepted, "Reject shifts outside the production search budget") }
    } else { check(false, "Textured input must produce a candidate") }
}
let blank = [Float](repeating: 100, count: n*n)
check(estimator.estimate(reference: blank, current: blank, gridSize: n) == nil, "Reject textureless images")
check(estimator.estimate(reference: [], current: [], gridSize: n) == nil, "Reject malformed grids")
print("Diagnostics/exposure/FFT checks: \(checks), failures: \(failures)")
if failures > 0 { exit(1) }
