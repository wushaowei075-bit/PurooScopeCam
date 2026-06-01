import AVFoundation
import SwiftUI
import UIKit

final class PreviewHostView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

final class PreviewContainerView: UIView {
    let previewView = PreviewHostView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .black
        addSubview(previewView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewView.bounds = bounds
        previewView.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    func applyPreviewTransform(_ transform: CGAffineTransform) {
        previewView.transform = transform
    }
}

struct CameraPreviewView: UIViewRepresentable {
    @ObservedObject var camera: CameraController
    let motionSample: StabilitySample
    let stabilizationPreference: StabilizationPreference
    let visualState: PreviewStabilizationState

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.backgroundColor = .black
        view.previewView.previewLayer.session = camera.session
        view.previewView.previewLayer.videoGravity = .resizeAspectFill
        camera.configurePreviewConnection(view.previewView.previewLayer.connection)
        return view
    }

    func updateUIView(_ view: PreviewContainerView, context: Context) {
        view.previewView.previewLayer.session = camera.session
        view.previewView.previewLayer.videoGravity = .resizeAspectFill
        camera.configurePreviewConnection(view.previewView.previewLayer.connection)
        context.coordinator.apply(
            sample: motionSample,
            preference: stabilizationPreference,
            visualState: visualState,
            to: view
        )
    }

    final class Coordinator {
        private var lastPreference: StabilizationPreference?
        private var lastTimestamp: TimeInterval?
        private var anchorPitch: Double?
        private var anchorRoll: Double?
        private var anchorYaw: Double?
        private var smoothedX: CGFloat = 0
        private var smoothedY: CGFloat = 0
        private var smoothedRoll: CGFloat = 0

        func apply(
            sample: StabilitySample,
            preference: StabilizationPreference,
            visualState: PreviewStabilizationState,
            to view: PreviewContainerView
        ) {
            guard preference.usesElectronicPreviewStabilization, sample.band != .unavailable else {
                reset(view: view)
                return
            }

            let timestamp = sample.timestamp
            let dt = lastTimestamp.map { min(max(timestamp - $0, 1.0 / 240.0), 1.0 / 30.0) } ?? 1.0 / 120.0
            lastTimestamp = timestamp

            if lastPreference != preference || anchorPitch == nil {
                lastPreference = preference
                anchorPitch = sample.pitch
                anchorRoll = sample.roll
                anchorYaw = sample.yaw
                smoothedX = 0
                smoothedY = 0
                smoothedRoll = 0
            }

            guard var pitchAnchor = anchorPitch,
                  var rollAnchor = anchorRoll,
                  var yawAnchor = anchorYaw
            else {
                return
            }

            let followRate = Double(preference.attitudeFollowRate)
            track(anchor: &pitchAnchor, toward: sample.pitch, rate: followRate, deltaTime: dt)
            track(anchor: &rollAnchor, toward: sample.roll, rate: followRate, deltaTime: dt)
            track(anchor: &yawAnchor, toward: sample.yaw, rate: followRate, deltaTime: dt)

            anchorPitch = pitchAnchor
            anchorRoll = rollAnchor
            anchorYaw = yawAnchor

            let pitchDelta = CGFloat(wrappedAngle(sample.pitch - pitchAnchor))
            let rollDelta = CGFloat(wrappedAngle(sample.roll - rollAnchor))
            let yawDelta = CGFloat(wrappedAngle(sample.yaw - yawAnchor))
            let gain = preference.previewStabilizationGain
            let scale = preference.previewCropScale
            let maxX = max(12, view.bounds.width * (scale - 1) * 0.48)
            let maxY = max(12, view.bounds.height * (scale - 1) * 0.48)
            let visualGain = preference.visualStabilizationGain

            var targetX = -yawDelta * gain
            var targetY = pitchDelta * gain
            let targetRoll = -rollDelta * 0.78

            targetX += visualState.normalizedX * view.bounds.width * visualGain
            targetY += visualState.normalizedY * view.bounds.height * visualGain

            targetX = clamp(targetX, min: -maxX, max: maxX)
            targetY = clamp(targetY, min: -maxY, max: maxY)

            let rollLimit = preference == .strong ? CGFloat.pi / 18 : CGFloat.pi / 26
            let clampedRoll = clamp(targetRoll, min: -rollLimit, max: rollLimit)
            let responseRate = preference == .strong ? 30.0 : 18.0
            let alpha = CGFloat(1 - exp(-dt * responseRate))

            smoothedX += (targetX - smoothedX) * alpha
            smoothedY += (targetY - smoothedY) * alpha
            smoothedRoll += (clampedRoll - smoothedRoll) * alpha

            smoothedX = clamp(smoothedX, min: -maxX, max: maxX)
            smoothedY = clamp(smoothedY, min: -maxY, max: maxY)

            let angle = Double(smoothedRoll)
            let cosine = CGFloat(cos(angle))
            let sine = CGFloat(sin(angle))
            let transform = CGAffineTransform(
                a: scale * cosine,
                b: scale * sine,
                c: -scale * sine,
                d: scale * cosine,
                tx: smoothedX,
                ty: smoothedY
            )
            view.applyPreviewTransform(transform)
        }

        private func reset(view: PreviewContainerView) {
            lastPreference = nil
            lastTimestamp = nil
            anchorPitch = nil
            anchorRoll = nil
            anchorYaw = nil
            smoothedX = 0
            smoothedY = 0
            smoothedRoll = 0
            view.applyPreviewTransform(.identity)
        }

        private func track(anchor: inout Double, toward value: Double, rate: Double, deltaTime: TimeInterval) {
            let amount = min(max(rate * deltaTime, 0), 1)
            anchor = wrappedAngle(anchor + wrappedAngle(value - anchor) * amount)
        }

        private func wrappedAngle(_ angle: Double) -> Double {
            var value = angle
            while value > .pi {
                value -= .pi * 2
            }
            while value < -.pi {
                value += .pi * 2
            }
            return value
        }

        private func clamp<T: Comparable>(_ value: T, min minimum: T, max maximum: T) -> T {
            min(max(value, minimum), maximum)
        }
    }
}
