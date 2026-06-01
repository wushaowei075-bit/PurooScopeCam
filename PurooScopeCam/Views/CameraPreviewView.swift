import AVFoundation
import CoreImage
import Metal
import MetalKit
import SwiftUI
import UIKit

private struct PreviewVisualCorrection: Equatable {
    var normalizedX: CGFloat
    var normalizedY: CGFloat
    var confidence: CGFloat
    var timestamp: TimeInterval

    static let identity = PreviewVisualCorrection(
        normalizedX: 0,
        normalizedY: 0,
        confidence: 0,
        timestamp: 0
    )
}

final class PreviewContainerView: UIView, CameraFrameSink {
    private let metalView: MTKView
    private let renderer: StabilizedMetalPreviewRenderer
    private let visualAnalyzer = PreviewFrameMotionAnalyzer()
    private let viewportLock = NSLock()
    private var viewportSize = CGSize.zero

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

        visualAnalyzer.onCorrection = { [weak self] correction in
            self?.renderer.setVisualCorrection(correction)
        }

        addSubview(metalView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        metalView.frame = bounds
        viewportLock.lock()
        viewportSize = bounds.size
        viewportLock.unlock()
    }

    var currentViewportSize: CGSize {
        viewportLock.lock()
        let size = viewportSize
        viewportLock.unlock()
        return size
    }

    func applyPreviewTransform(_ transform: PreviewRenderTransform) {
        renderer.setRenderTransform(transform)
    }

    func updateStabilizationPreference(_ preference: StabilizationPreference) {
        visualAnalyzer.setPreference(preference)
        renderer.setPreviewDelayFrames(preference.visualPreviewDelayFrames)
    }

    func stopVisualAnalysis() {
        visualAnalyzer.setPreference(.off)
        renderer.setVisualCorrection(.identity)
    }

    func cameraController(
        _ controller: CameraController,
        didOutput pixelBuffer: CVPixelBuffer,
        at timestamp: CMTime
    ) {
        renderer.enqueue(pixelBuffer: pixelBuffer, at: timestamp)
        visualAnalyzer.enqueue(pixelBuffer: pixelBuffer, at: timestamp)
    }
}

final class StabilizedMetalPreviewRenderer: NSObject, MTKViewDelegate {
    private struct QueuedPreviewFrame {
        var pixelBuffer: CVPixelBuffer
        var timestamp: TimeInterval
    }

    private let commandQueue: MTLCommandQueue
    private let ciContext: CIContext
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let stateLock = NSLock()

    private var frameQueue: [QueuedPreviewFrame] = []
    private var correctionHistory: [PreviewVisualCorrection] = [.identity]
    private var renderTransform = PreviewRenderTransform.identity
    private var previewDelayFrames = 0

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

    func enqueue(pixelBuffer: CVPixelBuffer, at timestamp: CMTime) {
        let presentationTime = CMTimeGetSeconds(timestamp)
        guard presentationTime.isFinite else { return }

        stateLock.lock()
        frameQueue.append(
            QueuedPreviewFrame(
                pixelBuffer: pixelBuffer,
                timestamp: presentationTime
            )
        )
        let maximumFrameCount = max(previewDelayFrames + 8, 12)
        if frameQueue.count > maximumFrameCount {
            frameQueue.removeFirst(frameQueue.count - maximumFrameCount)
        }
        stateLock.unlock()
    }

    func setRenderTransform(_ transform: PreviewRenderTransform) {
        stateLock.lock()
        renderTransform = transform
        stateLock.unlock()
    }

    fileprivate func setVisualCorrection(_ correction: PreviewVisualCorrection) {
        stateLock.lock()
        if correction == .identity {
            correctionHistory = [.identity]
        } else {
            correctionHistory.append(correction)
            if correctionHistory.count > 36 {
                correctionHistory.removeFirst(correctionHistory.count - 36)
            }
        }
        stateLock.unlock()
    }

    func setPreviewDelayFrames(_ frameCount: Int) {
        stateLock.lock()
        previewDelayFrames = max(0, min(frameCount, 6))
        let maximumFrameCount = max(previewDelayFrames + 8, 12)
        if frameQueue.count > maximumFrameCount {
            frameQueue.removeFirst(frameQueue.count - maximumFrameCount)
        }
        stateLock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        stateLock.lock()
        let queuedFrame = nextFrameForDisplay()
        let transform = renderTransform
        let correction = queuedFrame.map { correctionForFrame(at: $0.timestamp) } ?? .identity
        stateLock.unlock()

        guard let queuedFrame,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            return
        }

        let image = CIImage(cvPixelBuffer: queuedFrame.pixelBuffer)
        let drawableSize = view.drawableSize
        guard drawableSize.width > 1, drawableSize.height > 1 else { return }

        let renderBounds = CGRect(origin: .zero, size: drawableSize)
        let fitted = image.transformed(
            by: imageToDrawableTransform(
                imageExtent: image.extent,
                drawableSize: drawableSize,
                viewBounds: view.bounds,
                previewTransform: transform,
                visualCorrection: correction
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

    private func nextFrameForDisplay() -> QueuedPreviewFrame? {
        guard !frameQueue.isEmpty else { return nil }

        let targetIndex = max(0, frameQueue.count - 1 - previewDelayFrames)
        let frame = frameQueue[targetIndex]
        if targetIndex > 0 {
            frameQueue.removeFirst(targetIndex)
        }
        return frame
    }

    private func correctionForFrame(at timestamp: TimeInterval) -> PreviewVisualCorrection {
        guard !correctionHistory.isEmpty else { return .identity }

        var previousIndex = 0
        var nextIndex: Int?

        for (index, correction) in correctionHistory.enumerated() {
            if correction.timestamp <= timestamp {
                previousIndex = index
            } else {
                nextIndex = index
                break
            }
        }

        let previous = correctionHistory[previousIndex]
        let selected: PreviewVisualCorrection
        if let nextIndex {
            let next = correctionHistory[nextIndex]
            let span = max(next.timestamp - previous.timestamp, 0.0001)
            let amount = CGFloat(min(max((timestamp - previous.timestamp) / span, 0), 1))
            selected = PreviewVisualCorrection(
                normalizedX: previous.normalizedX + (next.normalizedX - previous.normalizedX) * amount,
                normalizedY: previous.normalizedY + (next.normalizedY - previous.normalizedY) * amount,
                confidence: previous.confidence + (next.confidence - previous.confidence) * amount,
                timestamp: timestamp
            )
        } else {
            selected = previous
        }

        if previousIndex > 1 {
            correctionHistory.removeFirst(previousIndex - 1)
        }

        return selected
    }

    private func imageToDrawableTransform(
        imageExtent: CGRect,
        drawableSize: CGSize,
        viewBounds: CGRect,
        previewTransform: PreviewRenderTransform,
        visualCorrection: PreviewVisualCorrection
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
        let correctedX = previewTransform.translationX + visualCorrection.normalizedX * viewBounds.width
        let correctedY = previewTransform.translationY + visualCorrection.normalizedY * viewBounds.height
        let outputCenterX = drawableSize.width * 0.5 + correctedX * pointToPixelX
        let outputCenterY = drawableSize.height * 0.5 - correctedY * pointToPixelY
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

private final class PreviewFrameMotionAnalyzer {
    var onCorrection: ((PreviewVisualCorrection) -> Void)?

    private struct VisualShift {
        var dx: CGFloat
        var dy: CGFloat
        var confidence: CGFloat
    }

    private let queue = DispatchQueue(label: "com.puroo.scope.preview.visualLock", qos: .userInteractive)
    private let busyLock = NSLock()
    private let gridSize = 80
    private let searchRadius = 6
    private var isBusy = false
    private var preference: StabilizationPreference = .off
    private var lastFrame: [UInt8]?
    private var lastFrameTimestamp: TimeInterval?
    private var lastAnalysisTimestamp: TimeInterval?
    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    private var correction = PreviewVisualCorrection.identity

    func setPreference(_ nextPreference: StabilizationPreference) {
        queue.async { [weak self] in
            guard let self, self.preference != nextPreference else { return }
            self.preference = nextPreference
            self.resetAnalysisState()
            self.emit(.identity)
        }
    }

    func enqueue(pixelBuffer: CVPixelBuffer, at timestamp: CMTime) {
        let presentationTime = CMTimeGetSeconds(timestamp)
        guard presentationTime.isFinite else { return }

        busyLock.lock()
        guard !isBusy else {
            busyLock.unlock()
            return
        }
        isBusy = true
        busyLock.unlock()

        let retainedPixelBuffer = pixelBuffer
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.markIdle() }
            self.process(pixelBuffer: retainedPixelBuffer, timestamp: presentationTime)
        }
    }

    private func process(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) {
        guard preference.usesElectronicPreviewStabilization else {
            resetAnalysisState()
            emit(.identity)
            return
        }

        if let lastAnalysisTimestamp,
           timestamp - lastAnalysisTimestamp < preference.visualAnalysisMinimumInterval {
            return
        }
        lastAnalysisTimestamp = timestamp

        guard let currentFrame = makeLumaGrid(from: pixelBuffer) else { return }

        guard let previousFrame = lastFrame,
              let previousTimestamp = lastFrameTimestamp
        else {
            lastFrame = currentFrame
            lastFrameTimestamp = timestamp
            return
        }

        lastFrame = currentFrame
        lastFrameTimestamp = timestamp

        let elapsed = timestamp - previousTimestamp
        if elapsed > 0.18 {
            accumulatedX = 0
            accumulatedY = 0
            correction = .identity
            emit(correction)
            return
        }

        let dt = min(max(elapsed, 1.0 / 120.0), 1.0 / 24.0)
        guard let shift = estimateShift(reference: previousFrame, current: currentFrame) else {
            decayCorrection(deltaTime: dt, timestamp: timestamp)
            return
        }

        apply(shift: shift, deltaTime: dt, timestamp: timestamp)
    }

    private func apply(shift: VisualShift, deltaTime: TimeInterval, timestamp: TimeInterval) {
        let leak = CGFloat(exp(-deltaTime * preference.visualHighPassLeakRate))
        accumulatedX = (accumulatedX + shift.dx * shift.confidence) * leak
        accumulatedY = (accumulatedY + shift.dy * shift.confidence) * leak

        let maximumGridOffset = CGFloat(gridSize) * preference.visualHighPassMaximumOffset
        accumulatedX = clamp(accumulatedX, min: -maximumGridOffset, max: maximumGridOffset)
        accumulatedY = clamp(accumulatedY, min: -maximumGridOffset, max: maximumGridOffset)

        let gain = preference.visualHighPassCorrectionGain
        let maximumOffset = preference.visualHighPassMaximumOffset
        let targetX = clamp(-accumulatedX / CGFloat(gridSize) * gain, min: -maximumOffset, max: maximumOffset)
        let targetY = clamp(-accumulatedY / CGFloat(gridSize) * gain, min: -maximumOffset, max: maximumOffset)
        let response = CGFloat(1 - exp(-deltaTime * preference.visualHighPassResponseRate))

        correction = PreviewVisualCorrection(
            normalizedX: correction.normalizedX + (targetX - correction.normalizedX) * response,
            normalizedY: correction.normalizedY + (targetY - correction.normalizedY) * response,
            confidence: shift.confidence,
            timestamp: timestamp
        )
        emit(correction)
    }

    private func decayCorrection(deltaTime: TimeInterval, timestamp: TimeInterval) {
        let leak = CGFloat(exp(-deltaTime * preference.visualHighPassLeakRate))
        accumulatedX *= leak
        accumulatedY *= leak

        let targetX = -accumulatedX / CGFloat(gridSize) * preference.visualHighPassCorrectionGain
        let targetY = -accumulatedY / CGFloat(gridSize) * preference.visualHighPassCorrectionGain
        let response = CGFloat(1 - exp(-deltaTime * preference.visualHighPassResponseRate))

        correction = PreviewVisualCorrection(
            normalizedX: correction.normalizedX + (targetX - correction.normalizedX) * response,
            normalizedY: correction.normalizedY + (targetY - correction.normalizedY) * response,
            confidence: max(0, correction.confidence * leak),
            timestamp: timestamp
        )
        emit(correction)
    }

    private func estimateShift(reference: [UInt8], current: [UInt8]) -> VisualShift? {
        let margin = searchRadius + 8
        let start = margin
        let end = gridSize - margin
        let side = searchRadius * 2 + 1
        let sampleCount = max((end - start) * (end - start), 1)
        let texture = textureScore(reference, start: start, end: end)
        guard texture > 2.2 else { return nil }

        var scores = Array(repeating: Int.max, count: side * side)
        var bestScore = Int.max
        var secondScore = Int.max
        var bestDx = 0
        var bestDy = 0

        for dy in -searchRadius...searchRadius {
            for dx in -searchRadius...searchRadius {
                var sad = 0
                for y in start..<end {
                    let referenceOffset = y * gridSize + start
                    let currentOffset = (y + dy) * gridSize + start + dx
                    for x in 0..<(end - start) {
                        let delta = Int(reference[referenceOffset + x]) - Int(current[currentOffset + x])
                        sad += delta < 0 ? -delta : delta
                    }
                }

                let index = (dy + searchRadius) * side + dx + searchRadius
                scores[index] = sad
                if sad < bestScore {
                    secondScore = bestScore
                    bestScore = sad
                    bestDx = dx
                    bestDy = dy
                } else if sad < secondScore {
                    secondScore = sad
                }
            }
        }

        func storedScore(dx: Int, dy: Int) -> Int {
            scores[(dy + searchRadius) * side + dx + searchRadius]
        }

        var refinedX = CGFloat(bestDx)
        var refinedY = CGFloat(bestDy)
        if bestDx > -searchRadius, bestDx < searchRadius {
            refinedX += subpixelOffset(
                lower: storedScore(dx: bestDx - 1, dy: bestDy),
                center: bestScore,
                upper: storedScore(dx: bestDx + 1, dy: bestDy)
            )
        }
        if bestDy > -searchRadius, bestDy < searchRadius {
            refinedY += subpixelOffset(
                lower: storedScore(dx: bestDx, dy: bestDy - 1),
                center: bestScore,
                upper: storedScore(dx: bestDx, dy: bestDy + 1)
            )
        }

        let meanSad = CGFloat(bestScore) / CGFloat(sampleCount)
        let uniqueness = CGFloat(max(secondScore - bestScore, 0)) / CGFloat(max(bestScore, 1))
        let textureConfidence = clamp((texture - 2.2) / 8.0, min: 0, max: 1)
        let matchConfidence = clamp((26 - meanSad) / 18, min: 0, max: 1)
        let uniquenessBoost = clamp(uniqueness * 5, min: 0, max: 0.35)
        let confidence = clamp(textureConfidence * 0.45 + matchConfidence * 0.45 + uniquenessBoost, min: 0, max: 1)

        guard confidence > 0.22 else { return nil }
        return VisualShift(dx: refinedX, dy: refinedY, confidence: confidence)
    }

    private func makeLumaGrid(from pixelBuffer: CVPixelBuffer) -> [UInt8]? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess
        else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        let cropSide = CGFloat(min(width, height)) * 0.72
        let cropX = (CGFloat(width) - cropSide) * 0.5
        let cropY = (CGFloat(height) - cropSide) * 0.5
        let step = cropSide / CGFloat(gridSize)
        var frame = Array(repeating: UInt8(0), count: gridSize * gridSize)

        for y in 0..<gridSize {
            let sourceY = clamp(
                Int(cropY + (CGFloat(y) + 0.5) * step),
                min: 0,
                max: max(height - 1, 0)
            )
            for x in 0..<gridSize {
                let sourceX = clamp(
                    Int(cropX + (CGFloat(x) + 0.5) * step),
                    min: 0,
                    max: max(width - 1, 0)
                )
                let offset = sourceY * bytesPerRow + sourceX * 4
                let blue = Int(bytes[offset])
                let green = Int(bytes[offset + 1])
                let red = Int(bytes[offset + 2])
                frame[y * gridSize + x] = UInt8((77 * red + 150 * green + 29 * blue) >> 8)
            }
        }

        return frame
    }

    private func textureScore(_ frame: [UInt8], start: Int, end: Int) -> CGFloat {
        var total = 0
        var count = 0
        for y in start..<(end - 1) {
            let row = y * gridSize
            let nextRow = (y + 1) * gridSize
            for x in start..<(end - 1) {
                total += abs(Int(frame[row + x]) - Int(frame[row + x + 1]))
                total += abs(Int(frame[row + x]) - Int(frame[nextRow + x]))
                count += 2
            }
        }
        return CGFloat(total) / CGFloat(max(count, 1))
    }

    private func subpixelOffset(lower: Int, center: Int, upper: Int) -> CGFloat {
        let denominator = CGFloat(lower - 2 * center + upper)
        guard abs(denominator) > 0.0001 else { return 0 }
        return clamp(CGFloat(lower - upper) / (2 * denominator), min: -0.5, max: 0.5)
    }

    private func resetAnalysisState() {
        lastFrame = nil
        lastFrameTimestamp = nil
        lastAnalysisTimestamp = nil
        accumulatedX = 0
        accumulatedY = 0
        correction = .identity
    }

    private func emit(_ correction: PreviewVisualCorrection) {
        onCorrection?(correction)
    }

    private func markIdle() {
        busyLock.lock()
        isBusy = false
        busyLock.unlock()
    }

    private func clamp<T: Comparable>(_ value: T, min minimum: T, max maximum: T) -> T {
        min(max(value, minimum), maximum)
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
        view.updateStabilizationPreference(stabilizationPreference)
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
        view.updateStabilizationPreference(stabilizationPreference)
        context.coordinator.update(
            preference: stabilizationPreference,
            visualState: visualState
        )
    }

    static func dismantleUIView(_ uiView: PreviewContainerView, coordinator: Coordinator) {
        uiView.stopVisualAnalysis()
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
        private var microPitch: Double = 0
        private var microRoll: Double = 0
        private var microYaw: Double = 0
        private var microPitchBaseline: Double = 0
        private var microRollBaseline: Double = 0
        private var microYawBaseline: Double = 0
        private let stateLock = NSLock()
        private weak var camera: CameraController?
        private weak var motionMonitor: MotionStabilityMonitor?
        private var motionObserverID: UUID?
        private var latestPreference: StabilizationPreference = .balanced
        private var latestVisualState: PreviewStabilizationState = .identity

        func attach(
            to view: PreviewContainerView,
            camera: CameraController,
            motionMonitor: MotionStabilityMonitor,
            preference: StabilizationPreference,
            visualState: PreviewStabilizationState
        ) {
            setLatest(preference: preference, visualState: visualState)

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
                let latest = self.latest()
                self.apply(
                    sample: sample,
                    preference: latest.preference,
                    visualState: latest.visualState,
                    to: view
                )
            }
        }

        func update(
            preference: StabilizationPreference,
            visualState: PreviewStabilizationState
        ) {
            setLatest(preference: preference, visualState: visualState)
        }

        private func setLatest(
            preference: StabilizationPreference,
            visualState: PreviewStabilizationState
        ) {
            stateLock.lock()
            latestPreference = preference
            latestVisualState = visualState
            stateLock.unlock()
        }

        private func latest() -> (preference: StabilizationPreference, visualState: PreviewStabilizationState) {
            stateLock.lock()
            let preference = latestPreference
            let visualState = latestVisualState
            stateLock.unlock()
            return (preference, visualState)
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
            let elapsed = lastTimestamp.map { timestamp - $0 } ?? 1.0 / 240.0
            let dt = min(max(elapsed, 1.0 / 300.0), 1.0 / 60.0)
            lastTimestamp = timestamp
            if elapsed > 0.08 {
                resetMicroJitterIntegrator()
            }

            if lastPreference != preference || anchorPitch == nil {
                lastPreference = preference
                anchorPitch = sample.pitch
                anchorRoll = sample.roll
                anchorYaw = sample.yaw
                smoothedX = 0
                smoothedY = 0
                smoothedRoll = 0
                resetMicroJitterIntegrator()
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
            let viewportSize = view.currentViewportSize
            let maxX = max(12, viewportSize.width * (scale - 1) * 0.38)
            let maxY = max(12, viewportSize.height * (scale - 1) * 0.38)
            let visualGain = preference.visualStabilizationGain
            let velocityLeadGain = preference.gyroVelocityLeadGain
            let velocityFloor = preference.gyroVelocityNoiseFloor
            updateMicroJitterIntegrator(sample: sample, preference: preference, deltaTime: dt)
            let microAngleLimit = preference.gyroMicroJitterAngleLimit
            let microPitchDelta = clamp(CGFloat(microPitch - microPitchBaseline), min: -microAngleLimit, max: microAngleLimit)
            let microYawDelta = clamp(CGFloat(microYaw - microYawBaseline), min: -microAngleLimit, max: microAngleLimit)
            let microRollDelta = clamp(CGFloat(microRoll - microRollBaseline), min: -microAngleLimit, max: microAngleLimit)

            var targetX = -yawDelta * gain
            var targetY = pitchDelta * gain
            let targetRoll = -rollDelta * 0.45
            let velocityX = -deadzone(sample.rotationY, floor: velocityFloor) * velocityLeadGain
            let velocityY = deadzone(sample.rotationX, floor: velocityFloor) * velocityLeadGain
            let velocityRoll = -deadzone(sample.rotationZ, floor: velocityFloor) * preference.rollVelocityLeadGain

            targetX -= microYawDelta * preference.gyroMicroJitterGain
            targetY += microPitchDelta * preference.gyroMicroJitterGain
            let microRollTarget = -microRollDelta * preference.gyroMicroRollGain

            targetX += visualState.normalizedX * viewportSize.width * visualGain
            targetY += visualState.normalizedY * viewportSize.height * visualGain

            targetX = clamp(targetX, min: -maxX, max: maxX)
            targetY = clamp(targetY, min: -maxY, max: maxY)

            let rollLimit = preference == .strong ? CGFloat.pi / 40 : CGFloat.pi / 58
            let clampedRoll = clamp(targetRoll + microRollTarget, min: -rollLimit, max: rollLimit)
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
            resetMicroJitterIntegrator()
            view.applyPreviewTransform(.identity)
        }

        private func updateMicroJitterIntegrator(
            sample: StabilitySample,
            preference: StabilizationPreference,
            deltaTime: TimeInterval
        ) {
            let floor = preference.gyroMicroJitterNoiseFloor
            microPitch += deadzoneDouble(sample.rotationX, floor: floor) * deltaTime
            microRoll += deadzoneDouble(sample.rotationZ, floor: floor) * deltaTime
            microYaw += deadzoneDouble(sample.rotationY, floor: floor) * deltaTime

            let followAlpha = 1 - exp(-deltaTime * preference.gyroMicroJitterFollowRate)
            microPitchBaseline += (microPitch - microPitchBaseline) * followAlpha
            microRollBaseline += (microRoll - microRollBaseline) * followAlpha
            microYawBaseline += (microYaw - microYawBaseline) * followAlpha

            let leak = exp(-deltaTime * preference.gyroMicroJitterLeakRate)
            microPitch *= leak
            microRoll *= leak
            microYaw *= leak
            microPitchBaseline *= leak
            microRollBaseline *= leak
            microYawBaseline *= leak
        }

        private func resetMicroJitterIntegrator() {
            microPitch = 0
            microRoll = 0
            microYaw = 0
            microPitchBaseline = 0
            microRollBaseline = 0
            microYawBaseline = 0
        }

        private func deadzone(_ value: Double, floor: Double) -> CGFloat {
            let magnitude = abs(value)
            guard magnitude > floor else { return 0 }
            return CGFloat((magnitude - floor) * (value < 0 ? -1 : 1))
        }

        private func deadzoneDouble(_ value: Double, floor: Double) -> Double {
            let magnitude = abs(value)
            guard magnitude > floor else { return 0 }
            return (magnitude - floor) * (value < 0 ? -1 : 1)
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
