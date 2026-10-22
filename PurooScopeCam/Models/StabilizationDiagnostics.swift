import Foundation

enum VisualMeasurementPolicy {
    static func acceptsConsensus(inliers: Int, candidates: Int, occupiedRegions: Int) -> Bool {
        candidates >= 6 && inliers >= max(6, Int(ceil(Double(candidates) * 0.45))) && occupiedRegions >= 2
    }

    static func permitsCalibration(inliers: Int, candidates: Int, occupiedRegions: Int) -> Bool {
        candidates > 0 && inliers >= 12 && Double(inliers) / Double(candidates) >= 0.65 && occupiedRegions >= 3
    }

    static func acceptsPhase(dx: Double, dy: Double, gyroX: Double, gyroY: Double) -> Bool {
        guard [dx, dy, gyroX, gyroY].allSatisfy({ $0.isFinite }) else { return false }
        // Grid-pixel noise budget, not a fixed fraction of the full sensor width.
        let tolerance = min(1.5, 0.35 + hypot(gyroX, gyroY) * 0.25)
        return hypot(dx - gyroX, dy - gyroY) <= tolerance
    }
}

struct VignetteRegion {
    var x: Double
    var y: Double
    var radius: Double
}

enum VignetteDetector {
    static func detect(_ luma: [Float], size: Int) -> VignetteRegion? {
        guard size >= 64, luma.count == size * size else { return nil }
        let samples = stride(from: 0, to: luma.count, by: 31).map { luma[$0] }.sorted()
        let high = samples[samples.count * 85 / 100]
        let low = samples[samples.count / 10]
        guard high > 32, low < high * 0.32 else { return nil }
        let threshold = max(Float(18), high * 0.26)
        var sx = 0.0, sy = 0.0, count = 0.0
        for y in stride(from: 2, to: size - 2, by: 4) {
            for x in stride(from: 2, to: size - 2, by: 4) where luma[y * size + x] >= threshold {
                sx += Double(x); sy += Double(y); count += 1
            }
        }
        guard count >= Double(size * size) / 16 * 0.12 else { return nil }
        let cx = sx / count, cy = sy / count
        func value(_ x: Double, _ y: Double) -> Float? {
            let ix = Int(x.rounded()), iy = Int(y.rounded())
            guard ix >= 0, ix < size, iy >= 0, iy < size else { return nil }
            return luma[iy * size + ix]
        }
        // Require an enclosing edge in nearly every direction, not just a bright centroid.
        var radii: [Double] = []
        for sector in 0..<32 {
            let angle = Double(sector) * 2 * .pi / 32
            let vx = cos(angle), vy = sin(angle)
            var edge: Double?
            for r in stride(from: Double(size) * 0.12, through: Double(size) * 0.49, by: 2) {
                guard let inside = value(cx + vx * (r - 4), cy + vy * (r - 4)),
                      let outside = value(cx + vx * (r + 4), cy + vy * (r + 4)),
                      let far = value(cx + vx * (r + 10), cy + vy * (r + 10)) else { continue }
                if inside >= threshold, outside < threshold, far < threshold { edge = r }
            }
            if let edge { radii.append(edge) }
        }
        guard radii.count >= 28 else { return nil }
        radii.sort()
        let radius = radii[radii.count / 2]
        guard radius >= Double(size) * 0.18,
              radii.filter({ abs($0 - radius) <= radius * 0.13 }).count >= 28 else { return nil }
        return VignetteRegion(x: cx, y: cy, radius: radius)
    }
}

enum RollingShutterPolicy {
    // A format-specific measured readout and scan axis are required before enabling.
    static let productionEnabled = false

    static func hasCompleteWindow(previous: Double, current: Double, halfReadout: Double,
                                  firstSample: Double, lastSample: Double) -> Bool {
        [previous, current, halfReadout, firstSample, lastSample].allSatisfy { $0.isFinite } &&
            halfReadout > 0 && current > previous && firstSample <= previous - halfReadout &&
            lastSample >= current + halfReadout
    }
}

enum PhotoTimestampPolicy {
    static func nearestIndex(to timestamp: Double, times: [Double], tolerance: Double) -> Int? {
        guard timestamp.isFinite, tolerance.isFinite, tolerance > 0 else { return nil }
        guard let index = times.indices.filter({ times[$0].isFinite }).min(by: {
            abs(times[$0] - timestamp) < abs(times[$1] - timestamp)
        }), abs(times[index] - timestamp) <= tolerance else { return nil }
        return index
    }
}

final class PhotoMomentGate {
    private let lock = NSLock()
    private let initialVelocity: Double
    private var minimumSeen: Double
    private var completed = false
    private var observerID: UUID?
    private let remove: (UUID) -> Void
    private let completion: () -> Void

    init(initialVelocity: Double, remove: @escaping (UUID) -> Void, completion: @escaping () -> Void) {
        self.initialVelocity = initialVelocity
        minimumSeen = initialVelocity
        self.remove = remove
        self.completion = completion
    }

    func install(_ id: UUID) {
        lock.lock()
        let alreadyCompleted = completed
        if !alreadyCompleted { observerID = id }
        lock.unlock()
        if alreadyCompleted { remove(id) }
    }

    func observe(velocity: Double) {
        lock.lock()
        guard !completed, velocity.isFinite else { lock.unlock(); return }
        let valley = velocity <= 0.16 || (velocity > minimumSeen * 1.06 && minimumSeen < initialVelocity * 0.85)
        minimumSeen = min(minimumSeen, velocity)
        lock.unlock()
        if valley { finish() }
    }

    func finish() {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let id = observerID
        observerID = nil
        lock.unlock()
        if let id { remove(id) }
        completion()
    }
}

// Policy only: the camera continues to own AE, ISO, focus and exposure bias.
struct StabilizationExposurePolicy {
    private(set) var prefersShortExposure = false
    private var brightSamples = 0
    private var darkSamples = 0

    mutating func update(enabled: Bool, automatic: Bool, duration: Double,
                         iso: Double, maximumISO: Double, targetOffset: Double,
                         zoomFactor: Double = 1.0) -> Double? {
        guard enabled, automatic, duration.isFinite, duration > 0,
              iso.isFinite, iso > 0, maximumISO.isFinite, maximumISO > 0,
              targetOffset.isFinite else {
            self = Self()
            return nil
        }
        // Estimate the ISO needed at 1/120s, including any remaining underexposure.
        let underexposureGain = pow(2, min(max(-targetOffset, 0), 3))
        let requiredISO = iso * duration * 120 * underexposureGain
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
        guard prefersShortExposure else { return nil }
        if zoomFactor.isFinite, zoomFactor > 3.0 {
            let highZoomProgress = min(max((zoomFactor - 3.0) / 7.0, 0), 1)
            let highZoomRate = 120.0 + highZoomProgress * 60.0 // Up to 1/180s at 10x zoom
            let highZoomISO = iso * duration * highZoomRate * underexposureGain
            if highZoomISO < maximumISO * 0.55 {
                return 1.0 / highZoomRate
            }
        }
        return 1.0 / 120.0
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
