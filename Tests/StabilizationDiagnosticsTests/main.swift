import Foundation

var checks = 0
var failures = 0
func check(_ value: Bool, _ message: String) {
    checks += 1
    if !value { failures += 1; print("FAIL: \(message)") }
}

check(!VisualMeasurementPolicy.acceptsConsensus(inliers: 12, candidates: 64, occupiedRegions: 4), "Reject 12/64 minority consensus")
check(VisualMeasurementPolicy.acceptsConsensus(inliers: 30, candidates: 64, occupiedRegions: 3), "Keep sufficiently supported tracking")
check(!VisualMeasurementPolicy.permitsCalibration(inliers: 30, candidates: 64, occupiedRegions: 3), "Calibration requires stronger evidence than tracking")
check(!VisualMeasurementPolicy.acceptsConsensus(inliers: 20, candidates: 24, occupiedRegions: 1), "Reject a single clustered subject")
check(VisualMeasurementPolicy.permitsCalibration(inliers: 45, candidates: 64, occupiedRegions: 3), "Accept distributed consensus for calibration")
check(!VisualMeasurementPolicy.acceptsPhase(dx: 0.04375, dy: 0, gyroX: 1, gyroY: 0), "Reject fixed-rim false zero at small motion")
check(VisualMeasurementPolicy.acceptsPhase(dx: 0.12, dy: -0.1, gyroX: 0.15, gyroY: -0.12), "Keep agreeing subpixel motion")
check(!RollingShutterPolicy.productionEnabled, "Unmeasured readout must not warp production frames")
check(!RollingShutterPolicy.hasCompleteWindow(previous: 1, current: 1 + 1/60, halfReadout: 0.006,
    firstSample: 0.9, lastSample: 1 + 1/60 + 0.002), "Reject asymmetric readout windows")
check(RollingShutterPolicy.hasCompleteWindow(previous: 1, current: 1 + 1/60, halfReadout: 0.006,
    firstSample: 0.9, lastSample: 1.1), "Accept complete temporal windows")
check(PhotoTimestampPolicy.nearestIndex(to: 1.017, times: [1, 1.0167, 1.0333], tolerance: 0.0125) == 1, "Match actual photo exposure rather than highest quality history")
check(PhotoTimestampPolicy.nearestIndex(to: 1.2, times: [1, 1.0167], tolerance: 0.0125) == nil, "Never apply stale photo transform")

var removedObservers: [UUID] = []
var completions = 0
let observerID = UUID()
let gate = PhotoMomentGate(initialVelocity: 0.5, remove: { removedObservers.append($0) }, completion: { completions += 1 })
gate.observe(velocity: 0.1) // Synchronous delivery before registration returns.
gate.install(observerID)
gate.finish() // Timeout after the synchronous completion.
check(completions == 1 && removedObservers == [observerID], "Synchronous observer must complete and unregister exactly once")
let delayedID = UUID()
let delayedGate = PhotoMomentGate(initialVelocity: 0.5, remove: { removedObservers.append($0) }, completion: { completions += 1 })
delayedGate.install(delayedID)
delayedGate.observe(velocity: 0.3)
delayedGate.observe(velocity: 0.35)
delayedGate.finish()
check(completions == 2 && removedObservers == [observerID, delayedID], "Valley after registration removes observer once")

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
var highZoomPolicy = StabilizationExposurePolicy()
_ = highZoomPolicy.update(enabled: true, automatic: true, duration: 1/60, iso: 100, maximumISO: 1600, targetOffset: 0, zoomFactor: 10)
let tenXCap = highZoomPolicy.update(enabled: true, automatic: true, duration: 1/60, iso: 100, maximumISO: 1600, targetOffset: 0, zoomFactor: 10)
check(abs((tenXCap ?? 0) - 1.0 / 180.0) < 0.00001, "Tighten exposure cap to 1/180s at 10x zoom when ISO headroom permits")

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
let splitLighting = (0..<n*n).map { Float($0 % n < n/2 ? 10 : 128) }
check(VignetteDetector.detect(splitLighting, size: n) == nil, "Half-dark ordinary scene is not a telescope vignette")
let circle = (0..<n*n).map { hypot(Double($0 % n) - 143.5, Double($0 / n) - 143.5) < 85 ? Float(160) : Float(5) }
let circleRegion = VignetteDetector.detect(circle, size: n)
check(circleRegion != nil && abs(circleRegion!.x - 143.5) < 2 && abs(circleRegion!.radius - 85) < 5, "Validate an enclosing circular edge")
let interiorMask = (0..<n*n).map { hypot(Double($0 % n) - 143.5, Double($0 / n) - 143.5) < 65 }
let ringReference = (0..<n*n).map { circle[$0] > 100 ? 160 + (texture(Double($0 % n), Double($0 / n)) - 110) * 0.2 : 5 }
let ringCurrent = (0..<n*n).map { circle[$0] > 100 ? 160 + (texture(Double($0 % n) - 1, Double($0 / n)) - 110) * 0.2 : 5 }
if let maskedPhase = estimator.estimate(reference: ringReference, current: ringCurrent, gridSize: n, validMask: interiorMask) {
    check(abs(maskedPhase.dx - 1) < 0.35 && abs(maskedPhase.dy) < 0.35, "Masked FFT follows interior texture instead of static rim")
} else { check(false, "Textured circle interior supports masked FFT") }
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
let oldProjection = MotionProjectionGeometry(focalX: 5000, focalY: 5000, width: 2160, height: 3840)
var newProjection = oldProjection
newProjection.focalX = 7500
newProjection.focalY = 10000
let projectionScale = newProjection.scale(from: oldProjection)
check(projectionScale?.x == 1.5 && projectionScale?.y == 2, "Transport actual per-axis focal scaling")
newProjection.sourceID = "other"
check(newProjection.scale(from: oldProjection) == nil, "Never transport between physical cameras")

let allMask = [Bool](repeating: true, count: n*n)
for (dx, dy) in [(1.0, -2.0), (0.35, -0.6), (6.0, 1.0)] {
    let moved = (0..<n*n).map { texture(Double($0 % n) - dx, Double($0 / n) - dy) * 1.15 + 8 }
    check(IndependentTranslationValidation.accepts(reference: reference, current: moved,
        mask: allMask, size: n, dx: dx, dy: dy), "Distributed photometric-invariant evidence accepts real translation")
    check(!IndependentTranslationValidation.accepts(reference: reference, current: moved,
        mask: allMask, size: n, dx: dx + 3, dy: dy), "Wrong translation fails independent spatial validation")
}
check(!IndependentTranslationValidation.accepts(reference: blank, current: blank,
    mask: allMask, size: n, dx: 0, dy: 0), "Blank images cannot confirm a cached gyro")
check(!IndependentTranslationValidation.accepts(reference: reference, current: reference,
    mask: allMask, size: n, dx: .nan, dy: 0), "Invalid translation cannot validate")
check(IndependentTranslationValidation.accepts(reference: ringReference, current: ringCurrent,
    mask: interiorMask, size: n, dx: 1, dy: 0), "Distributed masked interior supports recovery")
var localOnly = reference
for y in 0..<(n/2) {
    for x in 0..<(n/2) {
        localOnly[y*n+x] = texture(Double(x) - 2, Double(y))
    }
}
check(!IndependentTranslationValidation.accepts(reference: reference, current: localOnly,
    mask: allMask, size: n, dx: 2, dy: 0), "A moving object in one quadrant is not global motion")
print("Diagnostics/exposure/FFT checks: \(checks), failures: \(failures)")
if failures > 0 { exit(1) }
