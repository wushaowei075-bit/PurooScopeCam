import Combine
import CoreMotion
import Foundation

final class MotionStabilityMonitor: ObservableObject {
    @Published private(set) var sample: StabilitySample = .unavailable

    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private var filteredScore = 0.0

    init() {
        queue.name = "com.puroo.scope.motion"
        queue.qualityOfService = .userInteractive
    }

    func start() {
        guard !manager.isDeviceMotionActive else { return }

        guard manager.isDeviceMotionAvailable else {
            DispatchQueue.main.async {
                self.sample = .unavailable
            }
            return
        }

        manager.deviceMotionUpdateInterval = 1.0 / 120.0
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
                score: self.filteredScore,
                band: band
            )

            DispatchQueue.main.async {
                self.sample = next
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}
