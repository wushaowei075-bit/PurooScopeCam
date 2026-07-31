import AVFoundation
import CoreImage
import Metal
import MetalKit
import QuartzCore
import SwiftUI
import UIKit

final class PreviewContainerView: UIView, CameraFrameSink, StabilizedRecordingFrameSink, StabilizedPhotoFrameSink {
    private let metalView: MTKView
    private let renderer: StabilizedMetalPreviewRenderer
    private let stabilizationEngine = FrameStabilizationEngine()
    private let frameClockMapper = PreviewFrameClockMapper()
    private let overviewCIContext = CIContext(options: [.cacheIntermediates: false])
    private let overviewQueue = DispatchQueue(label: "com.puroo.scope.previewOverview", qos: .utility)
    private let overviewBusyLock = NSLock()
    private let overviewContainer = UIView()
    private let overviewImageView = UIImageView()
    private let cropWindowView = UIView()
    private let cropCenterHorizontalView = UIView()
    private let cropCenterVerticalView = UIView()
    private let debugOverlayLabel = UILabel()
    private let viewportLock = NSLock()
    private let preferenceLock = NSLock()
    private var viewportSize = CGSize.zero
    private var stabilizationPreference: StabilizationPreference = .off
    private var stabilizationTuning = StabilizationTuning(isEnabled: false)
    private var systemStabilizationModeName = "未知"
    private weak var motionMonitor: MotionStabilityMonitor?
    private var latestCorrection = CGPoint.zero
    private var overviewImageAspectRatio: CGFloat = 1
    private var lastOverviewUpdateTime: TimeInterval = 0
    private var lastDebugOverlayUpdateTime: TimeInterval = 0
    private var lastVideoRotationAngle: CGFloat = 90
    private var isOverviewBusy = false

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
        metalView.preferredFramesPerSecond = min(UIScreen.main.maximumFramesPerSecond, 60)
        metalView.delegate = renderer

        addSubview(metalView)
        configureOverview()
        configureDebugOverlay()
        stabilizationEngine.onResult = { [weak self] result in
            self?.applyStabilizationResult(result)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        metalView.frame = bounds
        layoutOverview()
        layoutDebugOverlay()
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

    func updateStabilizationSettings(
        preference: StabilizationPreference,
        isStabilizationEnabled: Bool,
        opticalMagnification: Double,
        displayZoomFactor: CGFloat,
        systemModeName: String
    ) {
        let tuning = StabilizationTuning(
            isEnabled: isStabilizationEnabled,
            displayZoomFactor: displayZoomFactor,
            opticalMagnification: opticalMagnification
        )
        preferenceLock.lock()
        let oldTuning = stabilizationTuning
        stabilizationPreference = preference
        stabilizationTuning = tuning
        systemStabilizationModeName = systemModeName
        preferenceLock.unlock()

        renderer.setPreviewDelayFrames(tuning.previewDelayFrames)
        renderer.setCropWindowScale(tuning.previewCropScale)
        let shouldReset = oldTuning.usesDigitalStabilization != tuning.usesDigitalStabilization ||
            abs(oldTuning.opticalMagnification - tuning.opticalMagnification) > 0.01
        if shouldReset {
            stabilizationEngine.reset()
            renderer.resetStabilizationState()
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if shouldReset || !tuning.usesDigitalStabilization {
                self.latestCorrection = .zero
            }
            self.overviewContainer.isHidden = !tuning.usesDigitalStabilization
            self.layoutOverview()
            self.layoutCropWindow()
            if !tuning.usesDigitalStabilization {
                self.updateDisabledDebugOverlay(systemModeName: systemModeName)
            }
        }
    }

    func stopProcessing() {
        stabilizationEngine.reset()
        renderer.resetStabilizationState()
        renderer.setCropWindowScale(1)
        StabilizationTraceRecorder.shared.stopSession()
        DispatchQueue.main.async { [weak self] in
            self?.overviewContainer.isHidden = true
        }
    }

    func updateMotionMonitor(_ monitor: MotionStabilityMonitor?) {
        let changed = motionMonitor !== monitor
        motionMonitor = monitor
        guard changed else { return }
        stabilizationEngine.reset()
        if monitor != nil {
            StabilizationTraceRecorder.shared.startSession(metadata: [
                "pipeline": "noninertial-virtual-camera-v7",
                "motion_rate_hz": 240,
                "visual_grid": FrameStabilizationEngine.visualGridSize,
                "preview_delay_frames": 1
            ])
        } else {
            StabilizationTraceRecorder.shared.stopSession()
        }
    }

    var isStabilizedRecording: Bool {
        renderer.isRecording
    }

    func startStabilizedRecording(
        to outputURL: URL,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        renderer.startRecording(to: outputURL, completion: completion)
    }

    func stopStabilizedRecording() {
        renderer.stopRecording()
    }

    func captureStabilizedPhoto(
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        renderer.capturePhoto(completion: completion)
    }

    func cameraController(
        _ controller: CameraController,
        didOutput pixelBuffer: CVPixelBuffer,
        metadata: CameraFrameMetadata
    ) {
        if abs(metadata.videoRotationAngle - lastVideoRotationAngle) > 0.5 {
            lastVideoRotationAngle = metadata.videoRotationAngle
            stabilizationEngine.reset()
            renderer.resetStabilizationState()
            DispatchQueue.main.async { [weak self] in
                self?.latestCorrection = .zero
                self?.layoutCropWindow()
            }
        }
        guard let frameTime = frameClockMapper.motionTime(for: metadata.presentationTime) else {
            return
        }
        preferenceLock.lock()
        let preference = stabilizationPreference
        let tuning = stabilizationTuning
        preferenceLock.unlock()

        let sourceTimestamp = CMTimeGetSeconds(metadata.presentationTime)
        renderer.enqueue(
            pixelBuffer: pixelBuffer,
            motionTime: frameTime,
            sourceTimestamp: sourceTimestamp.isFinite ? sourceTimestamp : frameTime
        )
        if preference.usesElectronicPreviewStabilization, tuning.usesDigitalStabilization {
            let exposureHalfDuration = min(max(metadata.exposureDuration * 0.5, 0), 1.0 / 30.0)
            let motionReferenceTime = frameTime - exposureHalfDuration
            let samples = motionMonitor?.samples(
                from: motionReferenceTime - tuning.motionSampleLookback,
                to: motionReferenceTime + tuning.motionSampleLookahead
            ) ?? []
            stabilizationEngine.enqueue(
                pixelBuffer: pixelBuffer,
                timestamp: frameTime,
                motionReferenceTime: motionReferenceTime,
                motionSamples: samples,
                videoRotationAngle: metadata.videoRotationAngle,
                tuning: tuning,
                viewportSize: currentViewportSize,
                focalLengthPixelsX: metadata.focalLengthPixelsX,
                focalLengthPixelsY: metadata.focalLengthPixelsY
            )
        } else {
            renderer.setRenderTransform(.identity, at: frameTime)
            renderer.markFrameReady(at: frameTime)
        }
        updateOverviewThumbnailIfNeeded(pixelBuffer: pixelBuffer, motionTime: frameTime)
    }

    func cameraController(
        _ controller: CameraController,
        didUpdateTargetFrameRate frameRate: Int
    ) {
        let clampedFrameRate = max(24, min(frameRate, 60))
        renderer.setTargetFrameRate(clampedFrameRate)
        DispatchQueue.main.async { [weak self] in
            self?.metalView.preferredFramesPerSecond = min(
                UIScreen.main.maximumFramesPerSecond,
                clampedFrameRate
            )
        }
    }

    private func applyStabilizationResult(_ result: StabilizationFrameResult) {
        renderer.setRenderTransform(result.transform, at: result.timestamp)
        renderer.markFrameReady(at: result.timestamp)
        let now = CACurrentMediaTime()
        let shouldUpdateDebug = now - lastDebugOverlayUpdateTime >= 0.10
        if shouldUpdateDebug {
            lastDebugOverlayUpdateTime = now
        }
        preferenceLock.lock()
        let systemModeName = systemStabilizationModeName
        preferenceLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.latestCorrection = CGPoint(
                x: result.normalizedCorrectionX,
                y: result.normalizedCorrectionY
            )
            self.layoutCropWindow()
            if shouldUpdateDebug {
                self.debugOverlayLabel.text = result.debug.overlayText(
                    systemModeName: systemModeName
                )
            }
        }
    }

    private func configureOverview() {
        overviewContainer.backgroundColor = UIColor.black.withAlphaComponent(0.24)
        overviewContainer.layer.cornerRadius = 6
        overviewContainer.layer.borderColor = UIColor.white.withAlphaComponent(0.42).cgColor
        overviewContainer.layer.borderWidth = 1
        overviewContainer.clipsToBounds = true
        overviewContainer.isHidden = true
        overviewContainer.isUserInteractionEnabled = false
        overviewImageView.contentMode = .scaleAspectFit
        overviewImageView.clipsToBounds = true

        cropWindowView.backgroundColor = .clear
        cropWindowView.layer.borderColor = UIColor.systemYellow.cgColor
        cropWindowView.layer.borderWidth = 1.5
        cropWindowView.layer.shadowColor = UIColor.black.cgColor
        cropWindowView.layer.shadowOpacity = 0.45
        cropWindowView.layer.shadowRadius = 2
        cropWindowView.layer.shadowOffset = .zero
        cropCenterHorizontalView.backgroundColor = UIColor.systemYellow
        cropCenterVerticalView.backgroundColor = UIColor.systemYellow
        cropWindowView.addSubview(cropCenterHorizontalView)
        cropWindowView.addSubview(cropCenterVerticalView)
        overviewContainer.addSubview(overviewImageView)
        overviewContainer.addSubview(cropWindowView)
        addSubview(overviewContainer)
    }

    private func configureDebugOverlay() {
        debugOverlayLabel.numberOfLines = 0
        debugOverlayLabel.font = .monospacedSystemFont(ofSize: 10.2, weight: .medium)
        debugOverlayLabel.textColor = .white
        debugOverlayLabel.backgroundColor = UIColor.black.withAlphaComponent(0.56)
        debugOverlayLabel.layer.cornerRadius = 7
        debugOverlayLabel.layer.borderWidth = 1
        debugOverlayLabel.layer.borderColor = UIColor.white.withAlphaComponent(0.20).cgColor
        debugOverlayLabel.clipsToBounds = true
        debugOverlayLabel.text = "防抖调试\n等待首帧与传感器数据"
        debugOverlayLabel.isUserInteractionEnabled = false
        debugOverlayLabel.isHidden = true
        addSubview(debugOverlayLabel)
    }

    private func layoutOverview() {
        let shortSide = min(bounds.width, bounds.height)
        let width = min(max(shortSide * 0.18, 72), 92)
        let contentAspect = max(overviewImageAspectRatio, 0.1)
        let height = min(width / contentAspect, width * 1.35)
        overviewContainer.frame = CGRect(
            x: bounds.maxX - width - 12,
            y: 14,
            width: width,
            height: height
        )
        overviewImageView.frame = overviewContainer.bounds
        layoutCropWindow()
    }

    private func layoutDebugOverlay() {
        debugOverlayLabel.frame = .zero
    }

    private func layoutCropWindow() {
        preferenceLock.lock()
        let preference = stabilizationPreference
        let tuning = stabilizationTuning
        preferenceLock.unlock()
        guard preference.usesCropWindowStabilization, tuning.usesDigitalStabilization else {
            cropWindowView.frame = .zero
            return
        }

        let imageRect = AVMakeRect(
            aspectRatio: CGSize(width: max(overviewImageAspectRatio, 0.1), height: 1),
            insideRect: overviewContainer.bounds
        )
        guard imageRect.width > 2, imageRect.height > 2 else { return }
        let cropScale = max(tuning.previewCropScale, 1.0001)
        let cropWidth = imageRect.width / cropScale
        let cropHeight = imageRect.height / cropScale
        let halfWidth = cropWidth * 0.5
        let halfHeight = cropHeight * 0.5
        let sourceCorrectionX = latestCorrection.x / cropScale
        let sourceCorrectionY = latestCorrection.y / cropScale
        let centerX = clamp(
            imageRect.midX - sourceCorrectionX * imageRect.width,
            min: imageRect.minX + halfWidth,
            max: imageRect.maxX - halfWidth
        )
        let centerY = clamp(
            imageRect.midY + sourceCorrectionY * imageRect.height,
            min: imageRect.minY + halfHeight,
            max: imageRect.maxY - halfHeight
        )
        cropWindowView.frame = CGRect(
            x: centerX - halfWidth,
            y: centerY - halfHeight,
            width: cropWidth,
            height: cropHeight
        )
        cropCenterHorizontalView.frame = CGRect(
            x: cropWidth * 0.5 - 8,
            y: cropHeight * 0.5 - 0.5,
            width: 16,
            height: 1
        )
        cropCenterVerticalView.frame = CGRect(
            x: cropWidth * 0.5 - 0.5,
            y: cropHeight * 0.5 - 8,
            width: 1,
            height: 16
        )
    }

    private func updateOverviewThumbnailIfNeeded(
        pixelBuffer: CVPixelBuffer,
        motionTime: TimeInterval
    ) {
        guard motionTime.isFinite, motionTime - lastOverviewUpdateTime >= 0.2 else { return }
        overviewBusyLock.lock()
        guard !isOverviewBusy else {
            overviewBusyLock.unlock()
            return
        }
        isOverviewBusy = true
        overviewBusyLock.unlock()
        lastOverviewUpdateTime = motionTime
        let retainedPixelBuffer = pixelBuffer

        overviewQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.overviewBusyLock.lock()
                self.isOverviewBusy = false
                self.overviewBusyLock.unlock()
            }
            let image = CIImage(cvPixelBuffer: retainedPixelBuffer)
            let targetWidth: CGFloat = 160
            let scale = targetWidth / max(image.extent.width, 1)
            let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let targetRect = CGRect(
                x: 0,
                y: 0,
                width: image.extent.width * scale,
                height: image.extent.height * scale
            )
            guard let cgImage = self.overviewCIContext.createCGImage(scaled, from: targetRect) else {
                return
            }
            let thumbnail = UIImage(cgImage: cgImage)
            let aspectRatio = image.extent.width / max(image.extent.height, 1)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.overviewImageAspectRatio = aspectRatio
                self.overviewImageView.image = thumbnail
                self.layoutCropWindow()
            }
        }
    }

    private func updateDisabledDebugOverlay(systemModeName: String) {
        debugOverlayLabel.text = """
        防抖调试  系统:\(systemModeName)
        自定义稳定:关闭
        预览:实时直通
        """
    }

    private func clamp<T: Comparable>(_ value: T, min minimum: T, max maximum: T) -> T {
        Swift.min(Swift.max(value, minimum), maximum)
    }
}

private final class PreviewFrameClockMapper {
    private var estimatedOffset: TimeInterval?

    func motionTime(for timestamp: CMTime) -> TimeInterval? {
        let presentationTime = CMTimeGetSeconds(timestamp)
        guard presentationTime.isFinite else { return nil }
        let hostTime = CACurrentMediaTime()
        if abs(presentationTime - hostTime) < 30 {
            return presentationTime
        }
        let nextOffset = hostTime - presentationTime
        if let estimatedOffset, abs(nextOffset - estimatedOffset) < 0.25 {
            self.estimatedOffset = estimatedOffset * 0.98 + nextOffset * 0.02
        } else {
            estimatedOffset = nextOffset
        }
        return presentationTime + (estimatedOffset ?? nextOffset)
    }
}

final class StabilizedMetalPreviewRenderer: NSObject, MTKViewDelegate {
    private struct QueuedPreviewFrame {
        var pixelBuffer: CVPixelBuffer
        var motionTime: TimeInterval
        var sourceTimestamp: TimeInterval
        var isReady: Bool
    }

    private struct TimedRenderTransform {
        var transform: PreviewRenderTransform
        var timestamp: TimeInterval
    }

    private struct DisplayedPhotoFrame {
        var pixelBuffer: CVPixelBuffer
        var transform: PreviewRenderTransform
        var cropScale: CGFloat
        var logicalViewport: CGSize
    }

    private let commandQueue: MTLCommandQueue
    private let ciContext: CIContext
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let recorder = StabilizedPreviewRecorder()
    private let photoQueue = DispatchQueue(label: "com.puroo.scope.preview.photo", qos: .userInitiated)
    private let stateLock = NSLock()
    private var frameQueue: [QueuedPreviewFrame] = []
    private var renderTransformHistory: [TimedRenderTransform] = [
        TimedRenderTransform(transform: .identity, timestamp: 0)
    ]
    private var previewDelayFrames = 0
    private var cropWindowScale: CGFloat = 1
    private var enqueuedFrameCount: Int64 = 0
    private var readyFrameCount: Int64 = 0
    private var displayedFrameCount: Int64 = 0
    private var queueDropCount: Int64 = 0
    private var skippedReadyFrameCount: Int64 = 0
    private var longDisplayGapCount: Int64 = 0
    private var displayedIntervalTotal: TimeInterval = 0
    private var displayedIntervalCount: Int64 = 0
    private var lastDisplayedSourceTimestamp: TimeInterval?
    private var displayedPhotoFrame: DisplayedPhotoFrame?

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

    func enqueue(
        pixelBuffer: CVPixelBuffer,
        motionTime: TimeInterval,
        sourceTimestamp: TimeInterval
    ) {
        guard motionTime.isFinite, sourceTimestamp.isFinite else { return }
        stateLock.lock()
        enqueuedFrameCount += 1
        frameQueue.append(
            QueuedPreviewFrame(
                pixelBuffer: pixelBuffer,
                motionTime: motionTime,
                sourceTimestamp: sourceTimestamp,
                isReady: false
            )
        )
        // 队列里的每一帧都占着采集输出的像素缓冲池。池子耗尽时相机会直接
        // 停止回调——实测出现过帧供给中断 4.3 秒，而同期分析耗时最大只有
        // 7.6 ms，并非处理跟不上。显示只需要 previewDelayFrames + 1 帧，
        // 其余纯属缓冲，留 3 帧余量即可。
        let maximumFrameCount = max(previewDelayFrames + 3, 5)
        if frameQueue.count > maximumFrameCount {
            let removalCount = frameQueue.count - maximumFrameCount
            queueDropCount += Int64(removalCount)
            frameQueue.removeFirst(removalCount)
        }
        stateLock.unlock()
    }

    func setRenderTransform(_ transform: PreviewRenderTransform, at timestamp: TimeInterval) {
        stateLock.lock()
        renderTransformHistory.append(
            TimedRenderTransform(
                transform: transform,
                timestamp: timestamp.isFinite ? timestamp : CACurrentMediaTime()
            )
        )
        if renderTransformHistory.count > 180 {
            renderTransformHistory.removeFirst(renderTransformHistory.count - 180)
        }
        stateLock.unlock()
    }

    func markFrameReady(at timestamp: TimeInterval) {
        stateLock.lock()
        if let index = frameQueue.lastIndex(where: { abs($0.motionTime - timestamp) < 0.0005 }) {
            if !frameQueue[index].isReady {
                frameQueue[index].isReady = true
                readyFrameCount += 1
            }
        }
        stateLock.unlock()
    }

    func setPreviewDelayFrames(_ frameCount: Int) {
        stateLock.lock()
        previewDelayFrames = max(0, min(frameCount, 3))
        stateLock.unlock()
    }

    func setCropWindowScale(_ scale: CGFloat) {
        stateLock.lock()
        cropWindowScale = max(1, min(scale, 2.20))
        stateLock.unlock()
    }

    func resetStabilizationState() {
        stateLock.lock()
        frameQueue.removeAll(keepingCapacity: true)
        renderTransformHistory = [TimedRenderTransform(transform: .identity, timestamp: 0)]
        enqueuedFrameCount = 0
        readyFrameCount = 0
        displayedFrameCount = 0
        queueDropCount = 0
        skippedReadyFrameCount = 0
        longDisplayGapCount = 0
        displayedIntervalTotal = 0
        displayedIntervalCount = 0
        lastDisplayedSourceTimestamp = nil
        displayedPhotoFrame = nil
        stateLock.unlock()
    }

    var isRecording: Bool {
        recorder.isRecording
    }

    func startRecording(
        to outputURL: URL,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        recorder.startRecording(to: outputURL, completion: completion)
    }

    func stopRecording() {
        recorder.stopRecording()
    }

    func setTargetFrameRate(_ frameRate: Int) {
        recorder.setTargetFrameRate(frameRate)
    }

    func capturePhoto(
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        photoQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let photoFrame = self.displayedPhotoFrame
            self.stateLock.unlock()
            guard let photoFrame else {
                completion(.failure(StabilizedPhotoCaptureError.previewNotReady))
                return
            }
            let image = CIImage(cvPixelBuffer: photoFrame.pixelBuffer)
            let outputSize = CGSize(
                width: CVPixelBufferGetWidth(photoFrame.pixelBuffer),
                height: CVPixelBufferGetHeight(photoFrame.pixelBuffer)
            )
            let stabilizedImage = image.transformed(
                by: self.imageToOutputTransform(
                    imageExtent: image.extent,
                    outputSize: outputSize,
                    logicalViewport: photoFrame.logicalViewport,
                    previewTransform: photoFrame.transform,
                    cropWindowScale: photoFrame.cropScale
                )
            )
            let outputBounds = CGRect(origin: .zero, size: outputSize)
            guard let cgImage = self.ciContext.createCGImage(stabilizedImage, from: outputBounds),
                  let jpegData = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.96)
            else {
                completion(.failure(StabilizedPhotoCaptureError.encodingFailed))
                return
            }
            completion(.success(jpegData))
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let recording = recorder.isRecording
        stateLock.lock()
        let queuedFrame = nextFrameForDisplay(preferOldestReady: recording)
        let transform = queuedFrame.map { renderTransformForFrame(at: $0.motionTime) } ?? .identity
        let cropScale = cropWindowScale
        let telemetry: [String: Any]?
        if queuedFrame != nil, displayedFrameCount > 0, displayedFrameCount.isMultiple(of: 120) {
            let measuredFPS = displayedIntervalTotal > 0
                ? Double(displayedIntervalCount) / displayedIntervalTotal
                : 0
            telemetry = [
                "enqueued": enqueuedFrameCount,
                "ready": readyFrameCount,
                "displayed": displayedFrameCount,
                "queue_drops": queueDropCount,
                "skipped_ready": skippedReadyFrameCount,
                "gaps_over_25ms": longDisplayGapCount,
                "measured_source_fps": measuredFPS,
                "recording": recording
            ]
        } else {
            telemetry = nil
        }
        stateLock.unlock()
        if let telemetry {
            StabilizationTraceRecorder.shared.recordControl("renderer_stats", values: telemetry)
        }
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
        let previewImage = image.transformed(
            by: imageToOutputTransform(
                imageExtent: image.extent,
                outputSize: drawableSize,
                logicalViewport: view.bounds.size,
                previewTransform: transform,
                cropWindowScale: cropScale
            )
        )
        stateLock.lock()
        displayedPhotoFrame = DisplayedPhotoFrame(
            pixelBuffer: queuedFrame.pixelBuffer,
            transform: transform,
            cropScale: cropScale,
            logicalViewport: view.bounds.size
        )
        stateLock.unlock()

        if recording {
            let recordingSize = CGSize(
                width: CVPixelBufferGetWidth(queuedFrame.pixelBuffer),
                height: CVPixelBufferGetHeight(queuedFrame.pixelBuffer)
            )
            let recordingImage = image.transformed(
                by: imageToOutputTransform(
                    imageExtent: image.extent,
                    outputSize: recordingSize,
                    logicalViewport: view.bounds.size,
                    previewTransform: transform,
                    cropWindowScale: cropScale
                )
            )
            recorder.append(
                stabilizedImage: recordingImage,
                sourceTimestamp: queuedFrame.sourceTimestamp,
                outputSize: recordingSize,
                ciContext: ciContext,
                colorSpace: colorSpace
            )
        }

        ciContext.render(
            previewImage,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: renderBounds,
            colorSpace: colorSpace
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func nextFrameForDisplay(preferOldestReady: Bool) -> QueuedPreviewFrame? {
        guard frameQueue.count > previewDelayFrames else { return nil }
        let maximumIndex = frameQueue.count - 1 - previewDelayFrames
        var selectedIndex: Int?
        if preferOldestReady {
            for index in 0...maximumIndex where frameQueue[index].isReady {
                selectedIndex = index
                break
            }
        } else {
            for index in stride(from: maximumIndex, through: 0, by: -1) {
                if frameQueue[index].isReady {
                    selectedIndex = index
                    break
                }
            }
        }
        guard let selectedIndex else { return nil }
        let frame = frameQueue[selectedIndex]
        if selectedIndex > 0 {
            let skipped = frameQueue[..<selectedIndex].reduce(into: 0) { count, queuedFrame in
                if queuedFrame.isReady {
                    count += 1
                }
            }
            skippedReadyFrameCount += Int64(skipped)
        }
        if let previousTimestamp = lastDisplayedSourceTimestamp {
            let interval = frame.sourceTimestamp - previousTimestamp
            if interval > 0 {
                displayedIntervalTotal += interval
                displayedIntervalCount += 1
                if interval > 0.025 {
                    longDisplayGapCount += 1
                }
            }
        }
        lastDisplayedSourceTimestamp = frame.sourceTimestamp
        displayedFrameCount += 1
        frameQueue.removeFirst(selectedIndex + 1)
        return frame
    }

    private func renderTransformForFrame(at timestamp: TimeInterval) -> PreviewRenderTransform {
        guard !renderTransformHistory.isEmpty else { return .identity }
        var previousIndex = 0
        var nextIndex: Int?
        for (index, timedTransform) in renderTransformHistory.enumerated() {
            if timedTransform.timestamp <= timestamp {
                previousIndex = index
            } else {
                nextIndex = index
                break
            }
        }
        let previous = renderTransformHistory[previousIndex]
        let selected: PreviewRenderTransform
        if let nextIndex {
            let next = renderTransformHistory[nextIndex]
            let span = max(next.timestamp - previous.timestamp, 0.0001)
            let amount = CGFloat(min(max((timestamp - previous.timestamp) / span, 0), 1))
            selected = PreviewRenderTransform(
                scale: previous.transform.scale + (next.transform.scale - previous.transform.scale) * amount,
                rotationRadians: previous.transform.rotationRadians +
                    (next.transform.rotationRadians - previous.transform.rotationRadians) * amount,
                translationX: previous.transform.translationX +
                    (next.transform.translationX - previous.transform.translationX) * amount,
                translationY: previous.transform.translationY +
                    (next.transform.translationY - previous.transform.translationY) * amount
            )
        } else {
            selected = previous.transform
        }
        if previousIndex > 4 {
            renderTransformHistory.removeFirst(previousIndex - 3)
        }
        return selected
    }

    private func imageToOutputTransform(
        imageExtent: CGRect,
        outputSize: CGSize,
        logicalViewport: CGSize,
        previewTransform: PreviewRenderTransform,
        cropWindowScale: CGFloat
    ) -> CGAffineTransform {
        let imageWidth = max(imageExtent.width, 1)
        let imageHeight = max(imageExtent.height, 1)
        let baseScale = max(outputSize.width / imageWidth, outputSize.height / imageHeight)
        let stabilizedScale = baseScale * max(previewTransform.scale, cropWindowScale)
        let rotation = previewTransform.rotationRadians
        let cosine = cos(rotation)
        let sine = sin(rotation)
        let normalizedX = previewTransform.translationX / max(logicalViewport.width, 1)
        let normalizedY = previewTransform.translationY / max(logicalViewport.height, 1)
        let outputCenterX = outputSize.width * (0.5 + normalizedX)
        let outputCenterY = outputSize.height * (0.5 - normalizedY)
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

private enum StabilizedPhotoCaptureError: LocalizedError {
    case previewNotReady
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .previewNotReady:
            return "稳定预览尚未准备好，请稍后再拍。"
        case .encodingFailed:
            return "无法生成与预览一致的照片。"
        }
    }
}

private final class StabilizedPreviewRecorder {
    private enum RecordingState: Equatable {
        case idle
        case waitingForFirstFrame
        case recording
        case finishing
    }

    private let lock = NSLock()
    private let recordingQueue = DispatchQueue(label: "com.puroo.scope.preview.recording", qos: .userInitiated)
    private var state: RecordingState = .idle
    private var outputURL: URL?
    private var completion: ((Result<URL, Error>) -> Void)?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var firstSourceTimestamp: TimeInterval?
    private var lastSourceTimestamp: TimeInterval?
    private var lastPresentationTime: CMTime?
    private var writtenFrameCount: Int64 = 0
    private var recordingFrameRate = 60
    private var outputWidth = 0
    private var outputHeight = 0
    private var targetFrameRate = 60
    private var pendingAppendCount = 0
    private var attemptedFrameCount: Int64 = 0
    private var pendingDropCount: Int64 = 0
    private var writerNotReadyDropCount: Int64 = 0
    private var timestampDropCount: Int64 = 0
    private var pixelBufferFailureCount: Int64 = 0
    private var appendFailureCount: Int64 = 0

    var isRecording: Bool {
        lock.lock()
        let active = state == .waitingForFirstFrame || state == .recording
        lock.unlock()
        return active
    }

    func startRecording(
        to outputURL: URL,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        lock.lock()
        guard state == .idle else {
            lock.unlock()
            completion(.failure(StabilizedPreviewRecorderError.alreadyRecording))
            return
        }
        try? FileManager.default.removeItem(at: outputURL)
        self.outputURL = outputURL
        self.completion = completion
        writer = nil
        input = nil
        adaptor = nil
        writtenFrameCount = 0
        firstSourceTimestamp = nil
        lastSourceTimestamp = nil
        lastPresentationTime = nil
        recordingFrameRate = targetFrameRate
        pendingAppendCount = 0
        attemptedFrameCount = 0
        pendingDropCount = 0
        writerNotReadyDropCount = 0
        timestampDropCount = 0
        pixelBufferFailureCount = 0
        appendFailureCount = 0
        state = .waitingForFirstFrame
        lock.unlock()
        StabilizationTraceRecorder.shared.recordControl("recording_start")
    }

    func stopRecording() {
        recordingQueue.async { [weak self] in
            self?.stopRecordingOnQueue()
        }
    }

    func setTargetFrameRate(_ frameRate: Int) {
        lock.lock()
        targetFrameRate = max(24, min(frameRate, 60))
        lock.unlock()
    }

    func append(
        stabilizedImage: CIImage,
        sourceTimestamp: TimeInterval,
        outputSize: CGSize,
        ciContext: CIContext,
        colorSpace: CGColorSpace
    ) {
        lock.lock()
        guard state == .waitingForFirstFrame || state == .recording,
              sourceTimestamp.isFinite
        else {
            lock.unlock()
            return
        }
        attemptedFrameCount += 1
        // 每个待处理任务都持有一个 CIImage，间接占着来源像素缓冲。
        guard pendingAppendCount < 3 else {
            pendingDropCount += 1
            lock.unlock()
            return
        }
        pendingAppendCount += 1
        lock.unlock()
        recordingQueue.async { [weak self] in
            guard let self else { return }
            defer { self.decrementPendingAppendCount() }
            self.appendOnRecordingQueue(
                stabilizedImage: stabilizedImage,
                sourceTimestamp: sourceTimestamp,
                outputSize: outputSize,
                ciContext: ciContext,
                colorSpace: colorSpace
            )
        }
    }

    private func stopRecordingOnQueue() {
        lock.lock()
        switch state {
        case .idle:
            lock.unlock()
        case .waitingForFirstFrame:
            finishLocked(result: .failure(StabilizedPreviewRecorderError.noFramesWritten))
        case .recording:
            finishWriterLocked()
        case .finishing:
            lock.unlock()
        }
    }

    private func appendOnRecordingQueue(
        stabilizedImage: CIImage,
        sourceTimestamp: TimeInterval,
        outputSize: CGSize,
        ciContext: CIContext,
        colorSpace: CGColorSpace
    ) {
        lock.lock()
        guard state == .waitingForFirstFrame || state == .recording else {
            lock.unlock()
            return
        }
        if state == .waitingForFirstFrame {
            do {
                try startWriterLocked(outputSize: outputSize)
            } catch {
                finishLocked(result: .failure(error))
                return
            }
        }
        guard state == .recording,
              let writer,
              let input,
              let adaptor,
              let pixelBufferPool = adaptor.pixelBufferPool
        else {
            lock.unlock()
            return
        }
        guard writer.status == .writing else {
            let error = writer.error ?? StabilizedPreviewRecorderError.writerFailed
            finishLocked(result: .failure(error))
            return
        }
        guard input.isReadyForMoreMediaData else {
            writerNotReadyDropCount += 1
            lock.unlock()
            return
        }
        if let lastSourceTimestamp, sourceTimestamp <= lastSourceTimestamp + 0.00001 {
            timestampDropCount += 1
            lock.unlock()
            return
        }
        let firstTimestamp = firstSourceTimestamp ?? sourceTimestamp
        firstSourceTimestamp = firstTimestamp
        let relativeSeconds = max(0, sourceTimestamp - firstTimestamp)
        let presentationTime = CMTime(
            seconds: relativeSeconds,
            preferredTimescale: 60_000
        )
        if let lastPresentationTime,
           CMTimeCompare(presentationTime, lastPresentationTime) <= 0 {
            timestampDropCount += 1
            lock.unlock()
            return
        }
        let currentOutputWidth = outputWidth
        let currentOutputHeight = outputHeight
        lock.unlock()

        var pixelBuffer: CVPixelBuffer?
        let createResult = CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &pixelBuffer)
        guard createResult == kCVReturnSuccess, let pixelBuffer else {
            lock.lock()
            pixelBufferFailureCount += 1
            finishLocked(result: .failure(StabilizedPreviewRecorderError.pixelBufferUnavailable))
            return
        }
        let scaleX = CGFloat(currentOutputWidth) / max(outputSize.width, 1)
        let scaleY = CGFloat(currentOutputHeight) / max(outputSize.height, 1)
        let recordingImage = stabilizedImage.transformed(
            by: CGAffineTransform(scaleX: scaleX, y: scaleY)
        )
        ciContext.render(
            recordingImage,
            to: pixelBuffer,
            bounds: CGRect(x: 0, y: 0, width: currentOutputWidth, height: currentOutputHeight),
            colorSpace: colorSpace
        )

        lock.lock()
        guard state == .recording, writer.status == .writing else {
            lock.unlock()
            return
        }
        if !adaptor.append(pixelBuffer, withPresentationTime: presentationTime) {
            appendFailureCount += 1
            let error = writer.error ?? StabilizedPreviewRecorderError.appendFailed
            finishLocked(result: .failure(error))
            return
        }
        lastSourceTimestamp = sourceTimestamp
        lastPresentationTime = presentationTime
        writtenFrameCount += 1
        lock.unlock()
    }

    private func decrementPendingAppendCount() {
        lock.lock()
        pendingAppendCount = max(0, pendingAppendCount - 1)
        lock.unlock()
    }

    private func startWriterLocked(outputSize: CGSize) throws {
        guard let outputURL else {
            throw StabilizedPreviewRecorderError.outputURLMissing
        }
        let recordingSize = compatibleRecordingSize(for: outputSize)
        outputWidth = recordingSize.width
        outputHeight = recordingSize.height
        guard outputWidth >= 16, outputHeight >= 16 else {
            throw StabilizedPreviewRecorderError.invalidOutputSize
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let expectedFrameRate = max(24, min(targetFrameRate, 60))
        let bitrate = min(
            max(outputWidth * outputHeight * expectedFrameRate / 8, 6_000_000),
            60_000_000
        )
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputWidth,
            AVVideoHeightKey: outputHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: expectedFrameRate,
                AVVideoExpectedSourceFrameRateKey: expectedFrameRate
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = true
        let sourceAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: outputWidth,
            kCVPixelBufferHeightKey as String: outputHeight,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: sourceAttributes
        )
        guard writer.canAdd(input) else {
            throw StabilizedPreviewRecorderError.inputUnavailable
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? StabilizedPreviewRecorderError.writerFailed
        }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        recordingFrameRate = expectedFrameRate
        writtenFrameCount = 0
        firstSourceTimestamp = nil
        lastSourceTimestamp = nil
        lastPresentationTime = nil
        state = .recording
    }

    private func compatibleRecordingSize(for sourceSize: CGSize) -> (width: Int, height: Int) {
        let sourceWidth = max(sourceSize.width, 1)
        let sourceHeight = max(sourceSize.height, 1)
        let isPortrait = sourceHeight >= sourceWidth
        let maximumWidth: CGFloat = isPortrait ? 2160 : 3840
        let maximumHeight: CGFloat = isPortrait ? 3840 : 2160
        let scale = min(maximumWidth / sourceWidth, maximumHeight / sourceHeight, 1)
        return (
            compatibleVideoDimension(sourceWidth * scale),
            compatibleVideoDimension(sourceHeight * scale)
        )
    }

    private func compatibleVideoDimension(_ value: CGFloat) -> Int {
        let rounded = max(16, Int(value.rounded(.down)))
        return max(16, rounded - (rounded % 16))
    }

    private func finishWriterLocked() {
        guard let writer, let input, let outputURL else {
            finishLocked(result: .failure(StabilizedPreviewRecorderError.writerMissing))
            return
        }
        state = .finishing
        input.markAsFinished()
        let completion = self.completion
        let frameCount = writtenFrameCount
        let attemptedCount = attemptedFrameCount
        let pendingDrops = pendingDropCount
        let writerNotReadyDrops = writerNotReadyDropCount
        let timestampDrops = timestampDropCount
        let pixelBufferFailures = pixelBufferFailureCount
        let appendFailures = appendFailureCount
        let sourceDuration = max((lastSourceTimestamp ?? 0) - (firstSourceTimestamp ?? 0), 0)
        resetWriterReferencesLocked(keepState: .finishing)
        lock.unlock()
        writer.finishWriting {
            let result: Result<URL, Error>
            if writer.status == .completed {
                result = .success(outputURL)
            } else {
                result = .failure(writer.error ?? StabilizedPreviewRecorderError.writerFailed)
            }
            self.lock.lock()
            self.state = .idle
            self.lock.unlock()
            StabilizationTraceRecorder.shared.recordControl(
                "recording_finish",
                values: [
                    "frames": frameCount,
                    "attempted": attemptedCount,
                    "pending_drops": pendingDrops,
                    "writer_not_ready_drops": writerNotReadyDrops,
                    "timestamp_drops": timestampDrops,
                    "pixel_buffer_failures": pixelBufferFailures,
                    "append_failures": appendFailures,
                    "source_duration": sourceDuration,
                    "success": writer.status == .completed
                ]
            )
            completion?(result)
        }
    }

    private func finishLocked(result: Result<URL, Error>) {
        let completion = self.completion
        resetWriterReferencesLocked(keepState: .idle)
        lock.unlock()
        completion?(result)
    }

    private func resetWriterReferencesLocked(keepState nextState: RecordingState) {
        state = nextState
        outputURL = nil
        completion = nil
        writer = nil
        input = nil
        adaptor = nil
        firstSourceTimestamp = nil
        lastSourceTimestamp = nil
        lastPresentationTime = nil
        writtenFrameCount = 0
        outputWidth = 0
        outputHeight = 0
    }
}

private enum StabilizedPreviewRecorderError: LocalizedError {
    case alreadyRecording
    case noFramesWritten
    case outputURLMissing
    case invalidOutputSize
    case inputUnavailable
    case writerMissing
    case writerFailed
    case pixelBufferUnavailable
    case appendFailed

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "稳定预览录像已经在进行中。"
        case .noFramesWritten:
            return "录像还没有写入稳定预览帧。"
        case .outputURLMissing:
            return "录像输出路径不可用。"
        case .invalidOutputSize:
            return "稳定预览录像尺寸不可用。"
        case .inputUnavailable:
            return "无法创建稳定预览录像输入。"
        case .writerMissing:
            return "稳定预览录像写入器不可用。"
        case .writerFailed:
            return "稳定预览录像写入失败。"
        case .pixelBufferUnavailable:
            return "无法创建稳定预览录像帧缓冲。"
        case .appendFailed:
            return "稳定预览录像帧写入失败。"
        }
    }
}

struct CameraPreviewView: UIViewRepresentable {
    @ObservedObject var camera: CameraController
    let motionMonitor: MotionStabilityMonitor
    let stabilizationPreference: StabilizationPreference
    let isStabilizationEnabled: Bool
    let opticalMagnification: Double
    let displayZoomFactor: CGFloat
    let systemStabilizationModeName: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.updateStabilizationSettings(
            preference: stabilizationPreference,
            isStabilizationEnabled: isStabilizationEnabled,
            opticalMagnification: opticalMagnification,
            displayZoomFactor: displayZoomFactor,
            systemModeName: systemStabilizationModeName
        )
        context.coordinator.attach(
            to: view,
            camera: camera,
            motionMonitor: motionMonitor
        )
        return view
    }

    func updateUIView(_ view: PreviewContainerView, context: Context) {
        view.updateStabilizationSettings(
            preference: stabilizationPreference,
            isStabilizationEnabled: isStabilizationEnabled,
            opticalMagnification: opticalMagnification,
            displayZoomFactor: displayZoomFactor,
            systemModeName: systemStabilizationModeName
        )
        context.coordinator.attach(
            to: view,
            camera: camera,
            motionMonitor: motionMonitor
        )
    }

    static func dismantleUIView(_ uiView: PreviewContainerView, coordinator: Coordinator) {
        uiView.stopProcessing()
        uiView.updateMotionMonitor(nil)
        coordinator.detach()
    }

    final class Coordinator {
        private weak var camera: CameraController?
        private weak var view: PreviewContainerView?
        private weak var motionMonitor: MotionStabilityMonitor?

        func attach(
            to view: PreviewContainerView,
            camera: CameraController,
            motionMonitor: MotionStabilityMonitor
        ) {
            if self.camera !== camera || self.view !== view {
                self.camera?.setPreviewFrameSink(nil)
                self.camera = camera
                self.view = view
                camera.setPreviewFrameSink(view)
            }
            if self.motionMonitor !== motionMonitor {
                self.motionMonitor = motionMonitor
                view.updateMotionMonitor(motionMonitor)
            }
        }

        func detach() {
            camera?.setPreviewFrameSink(nil)
            view?.updateMotionMonitor(nil)
            camera = nil
            view = nil
            motionMonitor = nil
        }
    }
}
