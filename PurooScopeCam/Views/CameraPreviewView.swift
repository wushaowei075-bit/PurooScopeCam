import AVFoundation
import QuartzCore
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
    var didConfigurePreviewConnection = false

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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewView.transform = transform
        CATransaction.commit()
    }
}

struct CameraPreviewView: UIViewRepresentable {
    @ObservedObject var camera: CameraController
    let motionMonitor: MotionStabilityMonitor
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
        configurePreviewConnectionIfNeeded(for: view)
        context.coordinator.attach(
            to: view,
            motionMonitor: motionMonitor,
            preference: stabilizationPreference,
            visualState: visualState
        )
        return view
    }

    func updateUIView(_ view: PreviewContainerView, context: Context) {
        view.previewView.previewLayer.session = camera.session
        view.previewView.previewLayer.videoGravity = .resizeAspectFill
        configurePreviewConnectionIfNeeded(for: view)
        context.coordinator.update(
            preference: stabilizationPreference,
            visualState: visualState
        )
    }

    static func dismantleUIView(_ uiView: PreviewContainerView, coordinator: Coordinator) {
        coordinator.detach()
    }

    private func configurePreviewConnectionIfNeeded(for view: PreviewContainerView) {
        guard !view.didConfigurePreviewConnection else { return }
        guard view.previewView.previewLayer.connection != nil else { return }
        camera.configurePreviewConnection(view.previewView.previewLayer.connection)
        view.didConfigurePreviewConnection = true
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
        private var leadX: CGFloat = 0
        private var leadY: CGFloat = 0
        private var leadRoll: CGFloat = 0
        private weak var motionMonitor: MotionStabilityMonitor?
        private var motionObserverID: UUID?
        private var latestPreference: StabilizationPreference = .strong
        private var latestVisualState: PreviewStabilizationState = .identity

        func attach(
            to view: PreviewContainerView,
            motionMonitor: MotionStabilityMonitor,
            preference: StabilizationPreference,
            visualState: PreviewStabilizationState
        ) {
            latestPreference = preference
            latestVisualState = visualState

            if motionObserverID != nil, self.motionMonitor === motionMonitor {
                return
            }

            detach()
            self.motionMonitor = motionMonitor
            motionObserverID = motionMonitor.addSampleObserver { [weak self, weak view] sample in
                guard let self, let view else { return }
                self.apply(
                    sample: sample,
                    preference: self.latestPreference,
                    visualState: self.latestVisualState,
                    to: view
                )
            }
        }

        func update(
            preference: StabilizationPreference,
            visualState: PreviewStabilizationState
        ) {
            latestPreference = preference
            latestVisualState = visualState
        }

        func detach() {
            if let motionObserverID {
                motionMonitor?.removeSampleObserver(motionObserverID)
            }
            motionObserverID = nil
            motionMonitor = nil
        }

        private func apply(
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
            let velocityLeadGain = preference.gyroVelocityLeadGain
            let velocityFloor = preference.gyroVelocityNoiseFloor

            var targetX = -yawDelta * gain
            var targetY = pitchDelta * gain
            let targetRoll = -rollDelta * 0.78
            let velocityX = -deadzone(sample.rotationY, floor: velocityFloor) * velocityLeadGain
            let velocityY = deadzone(sample.rotationX, floor: velocityFloor) * velocityLeadGain
            let velocityRoll = -deadzone(sample.rotationZ, floor: velocityFloor) * preference.rollVelocityLeadGain

            targetX += visualState.normalizedX * view.bounds.width * visualGain
            targetY += visualState.normalizedY * view.bounds.height * visualGain

            targetX = clamp(targetX, min: -maxX, max: maxX)
            targetY = clamp(targetY, min: -maxY, max: maxY)

            let rollLimit = preference == .strong ? CGFloat.pi / 30 : CGFloat.pi / 42
            let clampedRoll = clamp(targetRoll, min: -rollLimit, max: rollLimit)
            let responseRate = preference.previewResponseRate
            let alpha = CGFloat(1 - exp(-dt * responseRate))
            let leadAlpha = CGFloat(1 - exp(-dt * preference.gyroVelocityResponseRate))

            smoothedX += (targetX - smoothedX) * alpha
            smoothedY += (targetY - smoothedY) * alpha
            smoothedRoll += (clampedRoll - smoothedRoll) * alpha
            leadX += (velocityX - leadX) * leadAlpha
            leadY += (velocityY - leadY) * leadAlpha
            leadRoll += (velocityRoll - leadRoll) * leadAlpha

            smoothedX = clamp(smoothedX, min: -maxX, max: maxX)
            smoothedY = clamp(smoothedY, min: -maxY, max: maxY)
            leadX = clamp(leadX, min: -maxX * 0.28, max: maxX * 0.28)
            leadY = clamp(leadY, min: -maxY * 0.28, max: maxY * 0.28)

            let finalX = clamp(smoothedX + leadX, min: -maxX, max: maxX)
            let finalY = clamp(smoothedY + leadY, min: -maxY, max: maxY)
            let finalRoll = clamp(smoothedRoll + leadRoll, min: -rollLimit, max: rollLimit)
            let angle = Double(finalRoll)
            let cosine = CGFloat(cos(angle))
            let sine = CGFloat(sin(angle))
            let transform = CGAffineTransform(
                a: scale * cosine,
                b: scale * sine,
                c: -scale * sine,
                d: scale * cosine,
                tx: finalX,
                ty: finalY
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
            leadX = 0
            leadY = 0
            leadRoll = 0
            view.applyPreviewTransform(.identity)
        }

        private func deadzone(_ value: Double, floor: Double) -> CGFloat {
            let magnitude = abs(value)
            guard magnitude > floor else { return 0 }
            return CGFloat((magnitude - floor) * (value < 0 ? -1 : 1))
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
