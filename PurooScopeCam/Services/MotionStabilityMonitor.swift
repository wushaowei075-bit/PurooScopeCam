import Combine
import CoreMotion
import Foundation

final class MotionStabilityMonitor: ObservableObject {
    private(set) var sample: StabilitySample = .unavailable
    @Published private(set) var displaySample: StabilitySample = .unavailable

    typealias SampleObserver = (StabilitySample) -> Void

    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private let observerLock = NSLock()
    private var filteredScore = 0.0
    private var sampleObservers: [UUID: SampleObserver] = [:]
    private var sampleBuffer: [StabilitySample] = []
    private var lastDisplaySampleTime: TimeInterval = 0

    init() {
        queue.name = "com.puroo.scope.motion"
        queue.qualityOfService = .userInteractive
        queue.maxConcurrentOperationCount = 1
    }

    @discardableResult
    func addSampleObserver(_ observer: @escaping SampleObserver) -> UUID {
        let id = UUID()
        observerLock.lock()
        sampleObservers[id] = observer
        let currentSample = sample
        observerLock.unlock()

        if currentSample != .unavailable {
            observer(currentSample)
        }
        return id
    }

    func removeSampleObserver(_ id: UUID) {
        observerLock.lock()
        sampleObservers.removeValue(forKey: id)
        observerLock.unlock()
    }

    func start() {
        guard !manager.isDeviceMotionActive else { return }

        guard manager.isDeviceMotionAvailable else {
            DispatchQueue.main.async {
                self.sample = .unavailable
                self.displaySample = .unavailable
            }
            return
        }

        manager.deviceMotionUpdateInterval = 1.0 / 240.0
        let availableFrames = CMMotionManager.availableAttitudeReferenceFrames()
        let referenceFrame: CMAttitudeReferenceFrame = availableFrames.contains(.xArbitraryCorrectedZVertical)
            ? .xArbitraryCorrectedZVertical
            : .xArbitraryZVertical

        manager.startDeviceMotionUpdates(using: referenceFrame, to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }

            let rotation = motion.rotationRate
            let magnitude = sqrt(
                rotation.x * rotation.x +
                rotation.y * rotation.y +
                rotation.z * rotation.z
            )

            let normalized = min(1.0, magnitude / 1.8)
            self.filteredScore = self.filteredScore * 0.82 + normalized * 0.18

            let band: StabilityBand
            if self.filteredScore < 0.18 {
                band = .stable
            } else if self.filteredScore < 0.48 {
                band = .warning
            } else {
                band = .heavy
            }

            let next = StabilitySample(
                timestamp: motion.timestamp,
                angularVelocity: magnitude,
                rotationX: rotation.x,
                rotationY: rotation.y,
                rotationZ: rotation.z,
                pitch: motion.attitude.pitch,
                roll: motion.attitude.roll,
                yaw: motion.attitude.yaw,
                quaternionX: motion.attitude.quaternion.x,
                quaternionY: motion.attitude.quaternion.y,
                quaternionZ: motion.attitude.quaternion.z,
                quaternionW: motion.attitude.quaternion.w,
                score: self.filteredScore,
                band: band
            )

            StabilizationTraceRecorder.shared.recordMotion(next)

            self.observerLock.lock()
            self.sample = next
            self.sampleBuffer.append(next)
            let cutoff = next.timestamp - 1.25
            if let firstFreshIndex = self.sampleBuffer.firstIndex(where: { $0.timestamp >= cutoff }) {
                self.sampleBuffer.removeFirst(firstFreshIndex)
            } else {
                self.sampleBuffer.removeAll(keepingCapacity: true)
            }
            let observers = Array(self.sampleObservers.values)
            self.observerLock.unlock()

            observers.forEach { $0(next) }

            DispatchQueue.main.async {
                if self.shouldPublishDisplaySample(next) {
                    self.displaySample = next
                    self.lastDisplaySampleTime = next.timestamp
                }
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }

    func samples(from start: TimeInterval, to end: TimeInterval) -> [StabilitySample] {
        guard start.isFinite, end.isFinite, end > start else { return [] }

        observerLock.lock()
        let buffer = sampleBuffer
        observerLock.unlock()

        return selectedSamples(in: buffer, from: start, to: end)
    }

    func latestSampleWindow(duration: TimeInterval) -> (timestamp: TimeInterval, samples: [StabilitySample])? {
        guard duration.isFinite, duration > 0 else { return nil }

        observerLock.lock()
        let latest = sample
        let buffer = sampleBuffer
        observerLock.unlock()

        guard latest.band != .unavailable, latest.timestamp.isFinite else { return nil }

        let start = latest.timestamp - duration
        let selected = selectedSamples(in: buffer, from: start, to: latest.timestamp)
        guard !selected.isEmpty else { return nil }
        return (latest.timestamp, selected)
    }

    private func selectedSamples(
        in buffer: [StabilitySample],
        from start: TimeInterval,
        to end: TimeInterval
    ) -> [StabilitySample] {
        guard !buffer.isEmpty else { return [] }
        let padding = 1.0 / 120.0
        let lowerBound = start - padding
        var selected = buffer.filter { $0.timestamp >= lowerBound && $0.timestamp <= end }

        if selected.isEmpty,
           let nearest = buffer.last(where: { $0.timestamp <= end }) {
            selected = [nearest]
        }

        if let first = selected.first,
           first.timestamp > start,
           let previous = buffer.last(where: { $0.timestamp < first.timestamp }) {
            selected.insert(previous, at: 0)
        }

        return selected
    }

    private func shouldPublishDisplaySample(_ next: StabilitySample) -> Bool {
        next.band != displaySample.band || next.timestamp - lastDisplaySampleTime >= 1.0 / 20.0
    }
}
