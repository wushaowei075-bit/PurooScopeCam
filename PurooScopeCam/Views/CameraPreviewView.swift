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
            to: view
        )
    }

    final class Coordinator {
        private var lastTimestamp: TimeInterval?
        private var offsetX: CGFloat = 0
        private var offsetY: CGFloat = 0
        private var roll: CGFloat = 0

        func apply(
            sample: StabilitySample,
            preference: StabilizationPreference,
            to view: PreviewContainerView
        ) {
            guard preference.usesElectronicPreviewStabilization, sample.band != .unavailable else {
                reset(view: view)
                return
            }

            let timestamp = sample.timestamp
            let dt = lastTimestamp.map { min(max(timestamp - $0, 1.0 / 240.0), 1.0 / 30.0) } ?? 1.0 / 120.0
            lastTimestamp = timestamp

            let gain = preference.previewStabilizationGain
            let scale = preference.previewCropScale
            let maxX = max(8, view.bounds.width * (scale - 1) * 0.45)
            let maxY = max(8, view.bounds.height * (scale - 1) * 0.45)
            let returnRate = preference == .strong ? 1.35 : 2.2
            let decay = CGFloat(exp(-dt * returnRate))

            offsetX = (offsetX - CGFloat(sample.rotationY) * CGFloat(dt) * gain) * decay
            offsetY = (offsetY + CGFloat(sample.rotationX) * CGFloat(dt) * gain) * decay
            roll = (roll - CGFloat(sample.rotationZ) * CGFloat(dt) * 0.34) * decay

            offsetX = min(max(offsetX, -maxX), maxX)
            offsetY = min(max(offsetY, -maxY), maxY)
            roll = min(max(roll, -CGFloat.pi / 36), CGFloat.pi / 36)

            let transform = CGAffineTransform(translationX: offsetX, y: offsetY)
                .rotated(by: roll)
                .scaledBy(x: scale, y: scale)
            view.applyPreviewTransform(transform)
        }

        private func reset(view: PreviewContainerView) {
            lastTimestamp = nil
            offsetX = 0
            offsetY = 0
            roll = 0
            view.applyPreviewTransform(.identity)
        }
    }
}
