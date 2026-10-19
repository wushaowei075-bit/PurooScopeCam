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
        for amplitude in [CGFloat(0.0003), 0.0006, 0.003] {
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

print("Missing-gyro reconstruction error: \(largestMissingError)")
print("Motion fusion/controller checks: \(checks), failures: \(failures)")
if failures > 0 && !characterize { exit(1) }
