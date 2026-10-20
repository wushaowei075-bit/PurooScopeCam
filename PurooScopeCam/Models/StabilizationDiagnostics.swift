import Foundation

// Policy only: the camera continues to own AE, ISO, focus and exposure bias.
struct StabilizationExposurePolicy {
    private(set) var prefersShortExposure = false
    private var brightSamples = 0
    private var darkSamples = 0

    mutating func update(enabled: Bool, automatic: Bool, duration: Double,
                         iso: Double, maximumISO: Double, targetOffset: Double) -> Double? {
        guard enabled, automatic, duration.isFinite, duration > 0,
              iso.isFinite, iso > 0, maximumISO.isFinite, maximumISO > 0,
              targetOffset.isFinite else {
            self = Self()
            return nil
        }
        // Estimate the ISO needed at 1/120s, including any remaining underexposure.
        let requiredISO = iso * duration * 120 * pow(2, min(max(-targetOffset, 0), 3))
        if requiredISO < maximumISO * 0.55 && targetOffset > -0.4 {
            brightSamples += 1
            darkSamples = 0
        } else if requiredISO > maximumISO * 0.85 || targetOffset < -0.8 {
            darkSamples += 1
            brightSamples = 0
        } else {
            brightSamples = 0
            darkSamples = 0
        }
        if brightSamples >= 2 { prefersShortExposure = true }
        if darkSamples >= 2 { prefersShortExposure = false }
        return prefersShortExposure ? 1.0 / 120.0 : nil
    }

    static func boundedDuration(_ requested: Double?, minimum: Double, maximum: Double) -> Double? {
        guard let requested, minimum.isFinite, maximum.isFinite,
              minimum > 0, maximum >= minimum else { return nil }
        return min(max(requested, minimum), maximum)
    }
}

struct PresentationMetrics {
    private(set) var submitted = 0
    private(set) var presented = 0
    private(set) var failed = 0
    private(set) var lateIntervals = 0
    private var firstTime: Double?
    private var lastTime: Double?

    mutating func submit() { submitted += 1 }
    mutating func fail() { failed += 1 }

    mutating func present(at time: Double, targetFPS: Int) {
        guard time.isFinite, time > 0 else { return }
        if let lastTime {
            guard time > lastTime else { return }
            if time - lastTime > 1.5 / Double(max(targetFPS, 1)) { lateIntervals += 1 }
        } else {
            firstTime = time
        }
        lastTime = time
        presented += 1
    }

    var fps: Double {
        guard let firstTime, let lastTime, lastTime > firstTime else { return 0 }
        return Double(presented - 1) / (lastTime - firstTime)
    }
}
