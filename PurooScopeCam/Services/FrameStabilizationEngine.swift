import AVFoundation
import CoreGraphics
import CoreMedia
import simd

struct StabilizationTransform: Equatable {
    var translation: SIMD2<Float>
    var rotationRadians: Float
    var scale: Float

    static let identity = StabilizationTransform(
        translation: .zero,
        rotationRadians: 0,
        scale: 1
    )
}

protocol FrameRegistrationEstimating {
    func estimateTransform(reference: CVPixelBuffer, current: CVPixelBuffer) async throws -> CGAffineTransform
}

final class VisionFrameRegistrationEstimator: FrameRegistrationEstimating {
    func estimateTransform(reference: CVPixelBuffer, current: CVPixelBuffer) async throws -> CGAffineTransform {
        .identity
    }
}

final class FrameStabilizationEngine {
    private(set) var cropMargin: Float
    private var smoothedTransform = StabilizationTransform.identity
    private var lastPresentationTime: CMTime?
    private var latestMotionSample: StabilitySample?

    init(cropMargin: Float = 0.25) {
        self.cropMargin = cropMargin
    }

    func reset() {
        smoothedTransform = .identity
        lastPresentationTime = nil
        latestMotionSample = nil
    }

    func ingestMotion(_ sample: StabilitySample) {
        guard sample.band != .unavailable else { return }
        latestMotionSample = sample
    }

    func estimateTransform(for sampleBuffer: CMSampleBuffer) -> StabilizationTransform {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        defer { lastPresentationTime = timestamp }

        guard let lastPresentationTime else {
            return .identity
        }

        let delta = CMTimeGetSeconds(timestamp - lastPresentationTime)
        guard delta.isFinite, delta > 0 else {
            return smoothedTransform
        }

        let predicted = gyroPrediction(delta: Float(delta))
        smoothedTransform = smooth(current: smoothedTransform, next: predicted, alpha: 0.16)
        return smoothedTransform
    }

    private func gyroPrediction(delta: Float) -> StabilizationTransform {
        guard let latestMotionSample else {
            return .identity
        }

        let motion = Float(latestMotionSample.angularVelocity)
        let score = Float(latestMotionSample.score)
        let rotation = -motion * delta * 0.015
        let scale = 1 + min(cropMargin, 0.35) * score * 0.04

        return StabilizationTransform(
            translation: .zero,
            rotationRadians: rotation,
            scale: scale
        )
    }

    private func smooth(
        current: StabilizationTransform,
        next: StabilizationTransform,
        alpha: Float
    ) -> StabilizationTransform {
        StabilizationTransform(
            translation: current.translation * (1 - alpha) + next.translation * alpha,
            rotationRadians: current.rotationRadians * (1 - alpha) + next.rotationRadians * alpha,
            scale: current.scale * (1 - alpha) + next.scale * alpha
        )
    }
}
