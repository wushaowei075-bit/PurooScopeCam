import AVFoundation
import CoreImage
import Metal
import MetalKit
import SwiftUI
import UIKit

final class PreviewContainerView: UIView, CameraFrameSink {
    private let metalView: MTKView
    private let renderer: StabilizedMetalPreviewRenderer

    override init(frame: CGRect) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is required for stabilized preview rendering")
        }

        metalView = MTKView(frame: .zero, device: device)
        renderer = StabilizedMetalPreviewRenderer(device: device)
        super.init(frame: frame)

        backgroundColor = .black
        clipsToBounds = true

        metalView.backgroundColor = .black
        metalView.clearColor = MTLClearColorMake(0, 0, 0, 1)
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.framebufferOnly = false
        metalView.isPaused = false
        metalView.enableSetNeedsDisplay = false
        metalView.preferredFramesPerSecond = min(UIScreen.main.maximumFramesPerSecond, 120)
        metalView.delegate = renderer

        addSubview(metalView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        metalView.frame = bounds
    }

    func applyPreviewTransform(_ transform: PreviewRenderTransform) {
        renderer.setRenderTransform(transform)
    }

    func cameraController(
        _ controller: CameraController,
        didOutput pixelBuffer: CVPixelBuffer,
        at timestamp: CMTime
    ) {
        renderer.enqueue(pixelBuffer: pixelBuffer, at: timestamp)
    }
}

final class StabilizedMetalPreviewRenderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let ciContext: CIContext
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let stateLock = NSLock()

    private var latestPixelBuffer: CVPixelBuffer?
    private var renderTransform = PreviewRenderTransform.identity

    init(device: MTLDevice) {
        guard let commandQueue = device.makeCommandQueue() else {
            fatalError("Unable to create Metal command queue")
        }

        self.commandQueue = commandQueue
        ciContext = CIContext(
            mtlDevice: device,
            options: [
                .cacheIntermediates: false,
                .workingColorSpace: colorSpace,
                .outputColorSpace: colorSpace
            ]
        )
        super.init()
    }

    func enqueue(pixelBuffer: CVPixelBuffer, at _: CMTime) {
        stateLock.lock()
        latestPixelBuffer = pixelBuffer
        stateLock.unlock()
    }

    func setRenderTransform(_ transform: PreviewRenderTransform) {
        stateLock.lock()
        renderTransform = transform
        stateLock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        stateLock.lock()
        let pixelBuffer = latestPixelBuffer
        let transform = renderTransform
        stateLock.unlock()

        guard let pixelBuffer,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            return
        }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let drawableSize = view.drawableSize
        guard drawableSize.width > 1, drawableSize.height > 1 else { return }

        let renderBounds = CGRect(origin: .zero, size: drawableSize)
        let fitted = image.transformed(
            by: imageToDrawableTransform(
                imageExtent: image.extent,
                drawableSize: drawableSize,
                viewBounds: view.bounds,
                previewTransform: transform
            )
        )

        ciContext.render(
            fitted,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: renderBounds,
            colorSpace: colorSpace
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func imageToDrawableTransform(
        imageExtent: CGRect,
        drawableSize: CGSize,
        viewBounds: CGRect,
        previewTransform: PreviewRenderTransform
    ) -> CGAffineTransform {
        let imageWidth = max(imageExtent.width, 1)
        let imageHeight = max(imageExtent.height, 1)
        let baseScale = max(drawableSize.width / imageWidth, drawableSize.height / imageHeight)
        let stabilizedScale = baseScale * previewTransform.scale
        let rotation = previewTransform.rotationRadians
        let cosine = cos(rotation)
        let sine = sin(rotation)

        let pointToPixelX = drawableSize.width / max(viewBounds.width, 1)
        let pointToPixelY = drawableSize.height / max(viewBounds.height, 1)
        let outputCenterX = drawableSize.width * 0.5 + previewTransform.translationX * pointToPixelX
        let outputCenterY = drawableSize.height * 0.5 - previewTransform.translationY * pointToPixelY
        let inputCenterX = imageExtent.midX
        let inputCenterY = imageExtent.midY

        let a = stabilizedScale * cosine
        let b = stabilizedScale * sine
        let c = -stabilizedScale * sine
        let d = stabilizedScale * cosine
        let tx = outputCenterX - a * inputCenterX - c * inputCenterY
        let ty = outputCenterY - b * inputCenterX - d * inputCenterY

        return CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
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
        context.coordinator.attach(
            to: view,
            camera: camera,
            motionMonitor: motionMonitor,
            preference: stabilizationPreference,
            visualState: visualState
        )
        return view
    }

    func updateUIView(_ view: PreviewContainerView, context: Context) {
        context.coordinator.update(
            preference: stabilizationPreference,
            visualState: visualState
        )
    }

    static func dismantleUIView(_ uiView: PreviewContainerView, coordinator: Coordinator) {
        coordinator.detach()
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
        private weak var camera: CameraController?
        private weak var motionMonitor: MotionStabilityMonitor?
        private var motionObserverID: UUID?
        private var latestPreference: StabilizationPreference = .strong
        private var latestVisualState: PreviewStabilizationState = .identity

        func attach(
            to view: PreviewContainerView,
            camera: CameraController,
            motionMonitor: MotionStabilityMonitor,
            preference: StabilizationPreference,
            visualState: PreviewStabilizationState
        ) {
            latestPreference = preference
            latestVisualState = visualState

            if self.camera !== camera {
                self.camera?.setPreviewFrameSink(nil)
                self.camera = camera
                camera.setPreviewFrameSink(view)
            }

            if motionObserverID != nil, self.motionMonitor === motionMonitor {
                return
            }

            if let motionObserverID {
                self.motionMonitor?.removeSampleObserver(motionObserverID)
            }
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
            camera?.setPreviewFrameSink(nil)
            motionObserverID = nil
            motionMonitor = nil
            camera = nil
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
            let maxX = max(12, view.bounds.width * (scale - 1) * 0.38)
            let maxY = max(12, view.bounds.height * (scale - 1) * 0.38)
            let visualGain = preference.visualStabilizationGain
            let velocityLeadGain = preference.gyroVelocityLeadGain
            let velocityFloor = preference.gyroVelocityNoiseFloor

            var targetX = -yawDelta * gain
            var targetY = pitchDelta * gain
            let targetRoll = -rollDelta * 0.45
            let velocityX = -deadzone(sample.rotationY, floor: velocityFloor) * velocityLeadGain
            let velocityY = deadzone(sample.rotationX, floor: velocityFloor) * velocityLeadGain
            let velocityRoll = -deadzone(sample.rotationZ, floor: velocityFloor) * preference.rollVelocityLeadGain

            targetX += visualState.normalizedX * view.bounds.width * visualGain
            targetY += visualState.normalizedY * view.bounds.height * visualGain

            targetX = clamp(targetX, min: -maxX, max: maxX)
            targetY = clamp(targetY, min: -maxY, max: maxY)

            let rollLimit = preference == .strong ? CGFloat.pi / 40 : CGFloat.pi / 58
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
            leadX = clamp(leadX, min: -maxX * 0.18, max: maxX * 0.18)
            leadY = clamp(leadY, min: -maxY * 0.18, max: maxY * 0.18)

            let finalX = clamp(smoothedX + leadX, min: -maxX, max: maxX)
            let finalY = clamp(smoothedY + leadY, min: -maxY, max: maxY)
            let finalRoll = clamp(smoothedRoll + leadRoll, min: -rollLimit, max: rollLimit)

            view.applyPreviewTransform(
                PreviewRenderTransform(
                    scale: scale,
                    rotationRadians: finalRoll,
                    translationX: finalX,
                    translationY: finalY
                )
            )
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
