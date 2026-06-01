import AVFoundation
import CoreGraphics
import CoreMedia
import simd
import Vision

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

final class FrameStabilizationEngine {
    private(set) var cropMargin: Float
    private var smoothedTransform = StabilizationTransform.identity
    private var lastPresentationTime: CMTime?
    private var latestMotionSample: StabilitySample?
    private var previousVisualPixelBuffer: CVPixelBuffer?
    private var lastVisualAnalysisTime: TimeInterval?
    private var accumulatedVisualX: CGFloat = 0
    private var accumulatedVisualY: CGFloat = 0
    private var visualRegistrationEnabled = false
    private let visualRegistrationHandler = VNSequenceRequestHandler()

    init(cropMargin: Float = 0.25) {
        self.cropMargin = cropMargin
    }

    func reset() {
        smoothedTransform = .identity
        lastPresentationTime = nil
        latestMotionSample = nil
        previousVisualPixelBuffer = nil
        lastVisualAnalysisTime = nil
        accumulatedVisualX = 0
        accumulatedVisualY = 0
        visualRegistrationEnabled = false
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

    func estimatePreviewState(
        for sampleBuffer: CMSampleBuffer,
        preference: StabilizationPreference
    ) -> PreviewStabilizationState? {
        guard preference.usesElectronicPreviewStabilization else {
            if visualRegistrationEnabled {
                reset()
                return .identity
            }
            return nil
        }

        visualRegistrationEnabled = true

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let presentationTime = CMTimeGetSeconds(timestamp)
        guard presentationTime.isFinite,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else {
            return nil
        }

        let minInterval = minimumVisualAnalysisInterval(for: preference)
        if let lastVisualAnalysisTime, presentationTime - lastVisualAnalysisTime < minInterval {
            return nil
        }
        lastVisualAnalysisTime = presentationTime

        guard let previousVisualPixelBuffer else {
            previousVisualPixelBuffer = pixelBuffer
            return PreviewStabilizationState(
                normalizedX: 0,
                normalizedY: 0,
                confidence: 0,
                timestamp: presentationTime
            )
        }

        defer {
            self.previousVisualPixelBuffer = pixelBuffer
        }

        do {
            let transform = try estimateVisualTranslation(
                reference: previousVisualPixelBuffer,
                current: pixelBuffer
            )
            let width = max(CGFloat(CVPixelBufferGetWidth(pixelBuffer)), 1)
            let height = max(CGFloat(CVPixelBufferGetHeight(pixelBuffer)), 1)
            let deltaX = clamp(transform.tx / width, min: -0.045, max: 0.045)
            let deltaY = clamp(transform.ty / height, min: -0.045, max: 0.045)
            let decay: CGFloat = preference == .strong ? 0.995 : 0.988
            let response: CGFloat = preference == .strong ? 0.75 : 0.5
            let maxOffset = max((preference.previewCropScale - 1) * 0.36, 0.04)

            accumulatedVisualX = clamp((accumulatedVisualX + deltaX * response) * decay, min: -maxOffset, max: maxOffset)
            accumulatedVisualY = clamp((accumulatedVisualY + deltaY * response) * decay, min: -maxOffset, max: maxOffset)

            return PreviewStabilizationState(
                normalizedX: accumulatedVisualX,
                normalizedY: accumulatedVisualY,
                confidence: 1,
                timestamp: presentationTime
            )
        } catch {
            return nil
        }
    }

    private func gyroPrediction(delta: Float) -> StabilizationTransform {
        guard let latestMotionSample else {
            return .identity
        }

        let yaw = Float(latestMotionSample.rotationY)
        let score = Float(latestMotionSample.score)
        let rotation = -yaw * delta * 0.04
        let scale = 1 + min(cropMargin, 0.35) * score * 0.04

        return StabilizationTransform(
            translation: .zero,
            rotationRadians: rotation,
            scale: scale
        )
    }

    private func estimateVisualTranslation(
        reference: CVPixelBuffer,
        current: CVPixelBuffer
    ) throws -> CGAffineTransform {
        let request = VNTranslationalImageRegistrationRequest(
            targetedCVPixelBuffer: current,
            options: [:]
        )
        try visualRegistrationHandler.perform([request], on: reference)

        guard let observation = request.results?.first as? VNImageTranslationAlignmentObservation else {
            throw FrameStabilizationError.missingVisualRegistrationResult
        }

        return observation.alignmentTransform
    }

    private func minimumVisualAnalysisInterval(for preference: StabilizationPreference) -> TimeInterval {
        preference == .strong ? 1.0 / 18.0 : 1.0 / 12.0
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

    private func clamp<T: Comparable>(_ value: T, min minimum: T, max maximum: T) -> T {
        min(max(value, minimum), maximum)
    }
}

private enum FrameStabilizationError: Error {
    case missingVisualRegistrationResult
}
