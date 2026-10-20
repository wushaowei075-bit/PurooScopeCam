// This harness is appended to the production fusion/controller code by run.sh.
var checks = 0
var failures = 0
let characterize = CommandLine.arguments.contains("--characterize")

func check(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL: \(message)")
    }
}

private func observation(_ t: Double, _ x: CGFloat, _ y: CGFloat) -> VisualMotionObservation {
    VisualMotionObservation(timestamp: t, deltaX: x, deltaY: y,
        confidence: 0.9, vectorCount: 12, texture: 3)
}

private func candidate(_ x: CGFloat, _ y: CGFloat) -> GyroMotionCandidate {
    GyroMotionCandidate(automaticOffset: 0, deltaX: x, deltaY: y, deltaRoll: 0)
}

private func simulate(
    fps: Int = 60, steps: Int = 1200, magnification: Double = 10,
    signal: (Double) -> (CGFloat, CGFloat, CGFloat, CGFloat)
) -> FusedMotionDelta {
    let fusion = ComplementaryMotionFusion()
    let tuning = StabilizationTuning(isEnabled: true, opticalMagnification: magnification)
    var last: FusedMotionDelta?
    for frame in 0..<steps {
        let t = Double(frame) / Double(fps)
        let (x, y, gx, gy) = signal(t)
        last = fusion.update(timestamp: t, visual: observation(t, x, y),
            gyroCandidates: [candidate(gx, gy)], tuning: tuning)
    }
    return last!
}

// Correlation must not depend on amplitude, optical ratio, or a quiet axis.
for fps in [24, 30, 60] {
    for magnification in [1.0, 10.0, 30.0] {
        for amplitude in [CGFloat(0.00005), 0.0001, 0.0003, 0.0006, 0.003] {
            for axis in ["x", "y", "xy"] {
                let result = simulate(fps: fps, magnification: magnification) { t in
                    let x: CGFloat = axis == "y" ? 0 : amplitude * CGFloat(sin(2 * .pi * 9 * t))
                    let y: CGFloat = axis == "x" ? 0 : amplitude * CGFloat(cos(2 * .pi * 7 * t))
                    return (x, y, x / magnification, y / magnification)
                }
                let label = "\(fps)fps \(magnification)x amplitude=\(amplitude) axis=\(axis)"
                check(result.gyroTrust > 0.80, "Small coherent motion must retain trust: \(label)")
                check(result.isGyroCalibrationValid, "Coherent motion must remain valid: \(label)")
                check(result.gyroNormalizedError < 0.00001, "Scale-invariant residual: \(label)")
                if axis != "y" { check(result.gyroCorrelationX > 0.999, "X correlation: \(label)") }
                if axis != "x" { check(result.gyroCorrelationY > 0.999, "Y correlation: \(label)") }
            }
        }
    }
}

private let quietNoise = simulate { t in
    let x = CGFloat(0.0006 * sin(2 * .pi * 9 * t))
    return (x, CGFloat(0.000003 * cos(2 * .pi * 7 * t)),
        x / 10, CGFloat(0.0000003 * sin(2 * .pi * 5 * t)))
}
check(quietNoise.gyroTrust > 0.80, "Noise on an unexcited axis must not veto the moving axis")

private let aboveRange = simulate(magnification: 30) { t in
    let x = CGFloat(0.0006 * sin(2 * .pi * 9 * t))
    return (x, 0, x / 32, 0)
}
check(aboveRange.gyroTrust < 0.40, "Boundary rounding tolerance must not admit an out-of-range gain")

// A coherent gyro should help when the visual measurement contains fine-scale
// noise; the old energy floor silently reverted this case to visual-only.
for fps in [30, 60] {
    let fusion = ComplementaryMotionFusion()
    let tuning = StabilizationTuning(isEnabled: true)
    var visualError: CGFloat = 0
    var fusedError: CGFloat = 0
    for frame in 0..<1200 {
        let t = Double(frame) / Double(fps)
        let x = CGFloat(0.0006 * sin(2 * .pi * 9 * t))
        let y = CGFloat(0.0005 * cos(2 * .pi * 7 * t))
        let nx = CGFloat(0.0002 * sin(2 * .pi * 13 * t))
        let ny = CGFloat(0.00015 * cos(2 * .pi * 11 * t))
        let result = fusion.update(timestamp: t, visual: observation(t, x + nx, y + ny),
            gyroCandidates: [candidate(x / 10, y / 10)], tuning: tuning)
        if frame > 600 {
            visualError += nx * nx + ny * ny
            fusedError += pow(result.deltaX - x, 2) + pow(result.deltaY - y, 2)
        }
    }
    let ratio = sqrt(fusedError / visualError)
    print("Noisy visual + coherent gyro \(fps)fps: fused/visual measurement error=\(ratio)")
    check(ratio < 0.90, "A calibrated gyro must reduce synthetic fine-scale measurement noise")
}

for wrong in ["reversed", "phase", "contradictory-axis", "gyro-only-axis", "zero-gyro"] {
    let result = simulate { t in
        let x = CGFloat(0.0006 * sin(2 * .pi * 9 * t))
        let y = CGFloat(0.0006 * cos(2 * .pi * 7 * t))
        switch wrong {
        case "reversed": return (x, y, -x / 10, -y / 10)
        case "phase": return (x, 0, CGFloat(0.00006 * cos(2 * .pi * 9 * t)), 0)
        case "contradictory-axis": return (x, y, x / 10, -y / 10)
        case "gyro-only-axis": return (x, 0, x / 10, y / 10)
        default: return (x, y, 0, 0)
        }
    }
    check(result.gyroTrust < 0.01, "Reject \(wrong), even at subpixel amplitudes")
    check(!result.isGyroCalibrationValid, "Invalid calibration for \(wrong)")
}

// When a sample is missing, visual low + high must reconstruct the measured
// delta exactly. A cached gyro trust must not remove 70% of the high band.
private let missingFusion = ComplementaryMotionFusion()
let tuning = StabilizationTuning(isEnabled: true)
var largestMissingError: CGFloat = 0
for frame in 0..<600 {
    let t = Double(frame) / 60
    let x = CGFloat(0.0006 * sin(2 * .pi * 9 * t))
    let y = CGFloat(0.0004 * cos(2 * .pi * 7 * t))
    let available = frame > 100 && frame % 11 != 0 && !(300...340).contains(frame)
    let result = missingFusion.update(timestamp: t, visual: observation(t, x, y),
        gyroCandidates: available ? [candidate(x / 10, y / 10)] : [], tuning: tuning)
    if !available {
        largestMissingError = max(largestMissingError, abs(result.deltaX - x), abs(result.deltaY - y))
        check(result.gyroTrust == 0, "Missing gyro must have zero effective weight")
        check(!result.isGyroCalibrationValid, "Do not report a missing gyro measurement as valid")
    }
}
check(largestMissingError < 1e-12, "Visual-only fallback must preserve the high band")
private let neither = missingFusion.update(timestamp: 10, visual: nil, gyroCandidates: [], tuning: tuning)
check(neither.deltaX == 0 && neither.deltaY == 0 && neither.deltaRoll == 0,
    "With neither sensor valid, do not invent motion")

// Calibration must continue adapting after 10,000 samples, and survive a
// temporary visual dropout without emitting nonfinite or unbounded deltas.
private let longFusion = ComplementaryMotionFusion()
private var lastLong: FusedMotionDelta?
for frame in 0..<15000 {
    let t = Double(frame) / 60
    let magnification: CGFloat = frame < 12000 ? 10 : 12
    let x = CGFloat(0.001 * sin(2 * .pi * 9 * t))
    let y = CGFloat(0.001 * cos(2 * .pi * 7 * t))
    lastLong = longFusion.update(timestamp: t, visual: observation(t, x, y),
        gyroCandidates: [candidate(x / magnification, y / magnification)], tuning: tuning)
}
check(abs(lastLong!.opticalMagnification - 12) < 0.02, "Calibration must keep adapting")
for frame in 15000..<15060 {
    let t = Double(frame) / 60
    let result = longFusion.update(timestamp: t, visual: nil,
        gyroCandidates: [candidate(CGFloat(0.00006 * sin(2 * .pi * 9 * t)), 0)], tuning: tuning)
    check(result.gyroTrust > 0.80, "Brief visual dropout must not erase learned calibration")
    check(result.deltaX.isFinite && result.deltaY.isFinite && abs(result.deltaX) <= 0.04,
        "Visual dropout output remains finite and bounded")
}
longFusion.reset(keepCalibration: false)
private let reset = longFusion.update(timestamp: 251, visual: nil, gyroCandidates: [], tuning: tuning)
check(abs(reset.opticalMagnification - 10) < 1e-12, "Reset clears learned optical gain")

// Exercise the real trajectory with a tremor, not just the correlation math.
for fps in [30, 60] {
    let fusion = ComplementaryMotionFusion()
    let trajectory = VirtualCameraTrajectoryController()
    var inputEnergy: CGFloat = 0
    var outputEnergy: CGFloat = 0
    var previousX: CGFloat = 0
    var previousCrop: CGFloat = 0
    var panFrames = 0
    for frame in 0..<(fps * 20) {
        let t = Double(frame) / Double(fps)
        let x = CGFloat(0.0005 * sin(2 * .pi * 9 * t))
        let dx = x - previousX
        previousX = x
        let result = fusion.update(timestamp: t, visual: observation(t, dx, 0),
            gyroCandidates: [candidate(dx / 10, 0)], tuning: tuning)
        let crop = trajectory.update(timestamp: t,
            lowFrequencyDeltaX: result.lowFrequencyDeltaX, lowFrequencyDeltaY: result.lowFrequencyDeltaY,
            highFrequencyDeltaX: result.highFrequencyDeltaX, highFrequencyDeltaY: result.highFrequencyDeltaY,
            deltaRoll: result.deltaRoll, confidence: result.confidence, tuning: tuning)
        let outputDelta = dx * tuning.previewCropScale + crop.correctionX - previousCrop
        previousCrop = crop.correctionX
        if frame > fps * 5 {
            inputEnergy += pow(dx * tuning.previewCropScale, 2)
            outputEnergy += outputDelta * outputDelta
            if crop.isIntentionalPan { panFrames += 1 }
        }
        check(crop.correctionX.isFinite && abs(crop.correctionX) <= tuning.maximumCropOffsetFraction,
            "Trajectory output must remain within the crop budget")
    }
    let residual = sqrt(outputEnergy / inputEnergy)
    print("Ideal 9Hz tremor \(fps)fps: residual frame-motion ratio=\(residual), panFrames=\(panFrames)")
    check(residual < 0.30, "Keep effective cancellation with the existing trajectory gains")
    check(panFrames == 0, "Stationary tremor must not be treated as a pan")
}

// Cold start and fine signals below the former per-frame admission threshold.
private let cold = ComplementaryMotionFusion()
for i in 0..<63 {
    let t = Double(i) / 60
    let x = CGFloat(0.0001 * sin(Double(i)))
    let result = cold.update(timestamp: t, visual: observation(t, x, 0),
        gyroCandidates: [candidate(x / 10, 0)], tuning: tuning)
    check(!result.isGyroCalibrationValid && result.gyroTrust == 0, "A prior is not a calibration")
    check(abs(result.deltaX - x) < 1e-12, "Visual fallback works immediately, without a warm-up pause")
}
private let flat = simulate { _ in (0, 0, 0.00001, 0) }
check(!flat.isGyroCalibrationValid && flat.gyroTrust == 0, "No excitation must not authorize gyro correction")
private let fineWrong = simulate { t in
    let x = CGFloat(0.0001 * sin(2 * .pi * 9 * t))
    return (x, 0, -x / 10, 0)
}
check(!fineWrong.isGyroCalibrationValid && fineWrong.gyroTrust == 0, "Reject a reversed fine signal")
private let stale = cold.update(timestamp: 10, visual: nil, gyroCandidates: [candidate(0.0001, 0)], tuning: tuning)
check(stale.calibrationState == "stale" && stale.gyroTrust == 0, "Stale calibration loses authority")
private let wrongPrior = ComplementaryMotionFusion()
for i in 0..<300 {
    let t = Double(i) / 60
    let x = CGFloat(0.0002 * sin(Double(i)))
    let result = wrongPrior.update(timestamp: t, visual: observation(t, x, 0),
        gyroCandidates: [candidate(x, 0)], tuning: tuning)
    if abs(result.opticalMagnification - 1) > 0.15 {
        check(result.gyroTrust == 0, "A correlated but wrongly scaled gyro must not steer the crop")
    }
}

// The old combined soft limiter attenuated even small tremor around a biased
// crop. Check the production allocator and the full controller separately.
for low in stride(from: -1.5, through: 1.5, by: 0.1) {
    for high in stride(from: -1.5, through: 1.5, by: 0.1) {
        let limit = tuning.maximumCropOffsetFraction
        let l = CGFloat(low) * limit
        let h = CGFloat(high) * limit
        let result = CropTranslationAllocation.resolve(low: l, high: h, limit: limit)
        check(abs(result.total) <= limit + 1e-12, "Allocation stays in the physical crop")
        check(abs(result.high - min(max(h, -limit), limit)) < 1e-12,
            "Slow displacement cannot scale the high-band request")
        if abs(l) + abs(h) <= limit {
            check(abs(result.total - (l + h)) < 1e-12, "Interior crop allocation is linear")
        }
    }
}
for invalid in [CGFloat.nan, .infinity, -.infinity] {
    let result = CropTranslationAllocation.resolve(low: invalid, high: 0, limit: 0.23)
    check(result.total == 0, "Invalid allocation input must not reach the renderer")
}

private func biasedTrajectory(fps: Int, axis: String, sign: CGFloat,
                              fraction: CGFloat) -> VirtualCameraTrajectoryController {
    let controller = VirtualCameraTrajectoryController()
    let physicalOffset = fraction * tuning.maximumCropOffsetFraction * sign
    let sourcePath = -physicalOffset / (tuning.lowFrequencyStabilizationAmount * tuning.previewCropScale)
    for frame in 0..<30 {
        let delta = frame < 6 ? sourcePath / 6 : 0
        _ = controller.update(timestamp: Double(frame)/Double(fps),
            lowFrequencyDeltaX: axis == "x" ? delta : 0,
            lowFrequencyDeltaY: axis == "y" ? delta : 0,
            highFrequencyDeltaX: 0, highFrequencyDeltaY: 0,
            deltaRoll: 0, confidence: 1, tuning: tuning)
    }
    return controller
}

var worstBiasedHighError: CGFloat = 0
for fps in [24, 30, 60] {
    for axis in ["x", "y"] {
        for sign in [CGFloat(-1), 1] {
            let controller = biasedTrajectory(fps: fps, axis: axis, sign: sign, fraction: 0.80)
            let baseline = sign * tuning.maximumCropOffsetFraction * 0.80
            var previousOffset: CGFloat = 0
            for frame in 30..<(30+fps*3) {
                let t = Double(frame-30)/Double(fps)
                let high = CGFloat(sin(2 * .pi * 9 * t)) * tuning.maximumCropOffsetFraction * 0.06
                let targetOffset = -high / tuning.previewCropScale
                let delta = targetOffset - previousOffset * CGFloat(exp(-1 / Double(fps) / tuning.highFrequencyMemory))
                previousOffset = targetOffset
                let result = controller.update(timestamp: Double(frame)/Double(fps),
                    lowFrequencyDeltaX: 0, lowFrequencyDeltaY: 0,
                    highFrequencyDeltaX: axis == "x" ? delta : 0,
                    highFrequencyDeltaY: axis == "y" ? delta : 0,
                    deltaRoll: 0, confidence: 1, tuning: tuning)
                let value = axis == "x" ? result.correctionX : result.correctionY
                let other = axis == "x" ? result.correctionY : result.correctionX
                worstBiasedHighError = max(worstBiasedHighError, abs(value - baseline - high))
                check(abs(value - baseline - high) < 1e-10, "Biased crop keeps full small-signal high response")
                check(abs(other) < 1e-12, "Boundary handling cannot pull a quiet axis")
                check(abs(result.preUsage - 0.80) < 1e-10, "Pressure uses output units including crop scale")
                check(result.boundaryPressure > 0, "Physical 80% displacement must report boundary pressure")
                check(!result.isIntentionalPan, "A biased stationary tremor is not a pan")
            }
        }
    }
}
print("Biased 9Hz high-band allocation error: \(worstBiasedHighError)")

// A true pan may consume the budget, but must not build hidden slow-path debt
// or keep re-centering when motion stops. Rotation keeps its existing policy.
for fps in [24, 30, 60] {
    let controller = VirtualCameraTrajectoryController()
    var stopped: CGFloat?
    var previous: CGFloat = 0
    for frame in 0..<(fps*6) {
        let moving = frame < fps*3
        let result = controller.update(timestamp: Double(frame)/Double(fps),
            lowFrequencyDeltaX: moving ? 0.55 / CGFloat(fps) : 0,
            lowFrequencyDeltaY: 0, highFrequencyDeltaX: 0, highFrequencyDeltaY: 0,
            deltaRoll: moving ? 0.0001 : 0, confidence: 1, tuning: tuning)
        check(abs(result.correctionX) <= tuning.maximumCropOffsetFraction + 1e-12,
            "Long pan stays in bounds")
        check(abs(result.correctionRoll) <= tuning.maximumRollRadians(cropUsage: result.cropUsage) + 1e-12,
            "Roll respects the remaining translation budget")
        if !moving {
            if stopped == nil { stopped = previous }
            check(abs(result.correctionX - stopped!) < 1e-10, "Stopped hand must not trigger boundary return drift")
        }
        previous = result.correctionX
    }
    let reversed = controller.update(timestamp: 6, lowFrequencyDeltaX: -0.001,
        lowFrequencyDeltaY: 0, highFrequencyDeltaX: 0, highFrequencyDeltaY: 0,
        deltaRoll: 0, confidence: 1, tuning: tuning)
    check(reversed.correctionX > previous, "A reversal responds without waiting for slow-path windup")
    let disabled = controller.update(timestamp: 6+1/Double(fps),
        lowFrequencyDeltaX: 0.001, lowFrequencyDeltaY: 0.001,
        highFrequencyDeltaX: 0.001, highFrequencyDeltaY: 0.001,
        deltaRoll: 0.001, confidence: 1, tuning: StabilizationTuning(isEnabled: false))
    check(disabled.correctionX == 0 && disabled.correctionY == 0 && disabled.correctionRoll == 0,
        "Stabilization off remains identity")
    check(disabled.preUsage == 0, "Reset clears budget diagnostics")
}

print("Missing-gyro reconstruction error: \(largestMissingError)")
print("Motion fusion/controller checks: \(checks), failures: \(failures)")
if failures > 0 && !characterize { exit(1) }
