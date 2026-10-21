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
    private let focusPeakingImageView = UIImageView()
    private let debugOverlayLabel = UILabel()
    private let viewportLock = NSLock()
    private let preferenceLock = NSLock()
    private var viewportSize = CGSize.zero
    private var stabilizationPreference: StabilizationPreference = .off
    private var stabilizationTuning = StabilizationTuning(isEnabled: false)
    private var systemStabilizationModeName = "未知"
    private weak var motionMonitor: MotionStabilityMonitor?
    private var latestCorrection = CGPoint.zero
    private var latestCropUsage: CGFloat = 0
    private var overviewImageAspectRatio: CGFloat = 1
    private var lastOverviewUpdateTime: TimeInterval = 0
    private var lastDebugOverlayUpdateTime: TimeInterval = 0
    private var lastVideoRotationAngle: CGFloat = 90
    private var lastActiveSystemMode: Int?
    private var lastSourceSize = CGSize.zero
    private var isOverviewBusy = false
    private var isOverviewExpanded = false
    private var isFocusPeakingEnabled = false
    var onTelemetryUpdate: ((CGFloat, Bool, CGPoint) -> Void)?

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
        focusPeakingImageView.contentMode = .scaleAspectFill
        focusPeakingImageView.clipsToBounds = true
        focusPeakingImageView.isUserInteractionEnabled = false
        focusPeakingImageView.isHidden = true
        focusPeakingImageView.alpha = 0.88
        addSubview(focusPeakingImageView)
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
        focusPeakingImageView.frame = bounds
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
        systemModeName: String,
        isFocusPeakingEnabled: Bool = false
    ) {
        let tuning = StabilizationTuning(
            isEnabled: isStabilizationEnabled,
            displayZoomFactor: displayZoomFactor,
            opticalMagnification: opticalMagnification,
            modeStrength: preference.modeStrength
        )
        preferenceLock.lock()
        let oldTuning = stabilizationTuning
        stabilizationPreference = preference
        stabilizationTuning = tuning
        systemStabilizationModeName = systemModeName
        self.isFocusPeakingEnabled = isFocusPeakingEnabled
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
                self.latestCropUsage = 0
            }
            self.focusPeakingImageView.isHidden = !isFocusPeakingEnabled
            self.overviewContainer.isHidden = !tuning.usesDigitalStabilization
            self.layoutOverview()
            self.layoutCropWindow()
            if !tuning.usesDigitalStabilization {
                self.updateDisabledDebugOverlay(systemModeName: systemModeName)
            }
        }
    }

    func nudgeStabilizationCenter(normalizedDeltaX: CGFloat, normalizedDeltaY: CGFloat) {
        stabilizationEngine.nudgeDesiredCenter(
            normalizedDeltaX: normalizedDeltaX,
            normalizedDeltaY: normalizedDeltaY
        )
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
                "pipeline": "noninertial-virtual-camera-v9-output-crop-budget",
                "shadow_estimator": "regularized_phase_correlation_256",
                "maximum_replay_pairs": 12,
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
        includeAudio: Bool,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        renderer.startRecording(to: outputURL, includeAudio: includeAudio, completion: completion)
    }

    func receiveAudio(_ sampleBuffer: CMSampleBuffer) { renderer.appendAudio(sampleBuffer) }

    func resetPreview() {
        stabilizationEngine.reset()
        renderer.resetStabilizationState()
    }

    func sourceFocusPoint(from point: CGPoint) -> CGPoint? { renderer.sourceFocusPoint(from: point) }

    func photoContext() -> StabilizedPhotoContext? { renderer.photoContext() }

    func waitForOptimalPhotoMoment(maxWait: TimeInterval, completion: @escaping () -> Void) {
        guard let monitor = motionMonitor,
              monitor.sample.band != .unavailable,
              monitor.sample.angularVelocity > 0.16,
              maxWait > 0.005 else {
            completion()
            return
        }
        let gateLock = NSLock()
        var completed = false
        var observerID: UUID?
        let initialVelocity = monitor.sample.angularVelocity
        var minimumSeen = initialVelocity

        let finish: () -> Void = { [weak monitor] in
            gateLock.lock()
            guard !completed else {
                gateLock.unlock()
                return
            }
            completed = true
            let id = observerID
            observerID = nil
            gateLock.unlock()
            if let id {
                monitor?.removeSampleObserver(id)
            }
            completion()
        }

        observerID = monitor.addSampleObserver { sample in
            let velocity = sample.angularVelocity
            let hitValley = velocity <= 0.16 ||
                (velocity > minimumSeen * 1.06 && minimumSeen < initialVelocity * 0.85)
            minimumSeen = min(minimumSeen, velocity)
            if hitValley {
                finish()
            }
        }
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + maxWait) {
            finish()
        }
    }

    func processPhoto(_ data: Data, context: StabilizedPhotoContext, completion: @escaping (Result<Data, Error>) -> Void) {
        renderer.processPhoto(data, context: context, completion: completion)
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
        let sourceSize = CGSize(width: metadata.frameWidth, height: metadata.frameHeight)
        if abs(metadata.videoRotationAngle - lastVideoRotationAngle) > 0.5 ||
            lastActiveSystemMode != metadata.activeSystemStabilization || lastSourceSize != sourceSize {
            lastVideoRotationAngle = metadata.videoRotationAngle
            lastActiveSystemMode = metadata.activeSystemStabilization
            lastSourceSize = sourceSize
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
            sourceTimestamp: sourceTimestamp.isFinite ? sourceTimestamp : frameTime,
            viewport: currentViewportSize
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
        StabilizationTraceRecorder.shared.recordControl("capture_timing", values: [
            "frame_t": frameTime, "source_pts": sourceTimestamp.isFinite ? sourceTimestamp : -1,
            "callback_t": metadata.callbackTime,
            "capture_age_ms": (metadata.callbackTime - frameTime) * 1000,
            "exposure_s": metadata.exposureDuration, "iso": metadata.iso,
            "exposure_metadata_source": "device_at_callback_not_per_frame_attachment",
            "exposure_target_offset": metadata.exposureTargetOffset,
            "max_exposure_s": metadata.maximumExposureDuration.isFinite ? metadata.maximumExposureDuration : -1,
            "active_system_mode": metadata.activeSystemStabilization,
            "rotation": metadata.videoRotationAngle
        ])
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
            self.latestCropUsage = result.debug.cropUsage
            self.layoutCropWindow()
            if shouldUpdateDebug {
                self.debugOverlayLabel.text = result.debug.overlayText(
                    systemModeName: systemModeName
                )
                self.onTelemetryUpdate?(
                    result.debug.cropUsage,
                    result.debug.isGyroCalibrationValid,
                    result.vignetteCenterOffset
                )
            }
        }
    }

    private func configureOverview() {
        overviewContainer.backgroundColor = UIColor.black.withAlphaComponent(0.28)
        overviewContainer.layer.cornerRadius = 6
        overviewContainer.layer.borderColor = UIColor.white.withAlphaComponent(0.45).cgColor
        overviewContainer.layer.borderWidth = 1
        overviewContainer.clipsToBounds = true
        overviewContainer.isHidden = true
        overviewContainer.isUserInteractionEnabled = true
        overviewImageView.contentMode = .scaleAspectFit
        overviewImageView.clipsToBounds = true

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleOverviewDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        overviewContainer.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleOverviewSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        overviewContainer.addGestureRecognizer(singleTap)

        cropWindowView.backgroundColor = .clear
        cropWindowView.layer.borderColor = UIColor.systemYellow.cgColor
        cropWindowView.layer.borderWidth = 1.5
        cropWindowView.layer.shadowColor = UIColor.black.cgColor
        cropWindowView.layer.shadowOpacity = 0.45
        cropWindowView.layer.shadowRadius = 2
        cropWindowView.layer.shadowOffset = .zero
        cropWindowView.isUserInteractionEnabled = false
        cropCenterHorizontalView.backgroundColor = UIColor.systemYellow
        cropCenterVerticalView.backgroundColor = UIColor.systemYellow
        cropWindowView.addSubview(cropCenterHorizontalView)
        cropWindowView.addSubview(cropCenterVerticalView)
        overviewContainer.addSubview(overviewImageView)
        overviewContainer.addSubview(cropWindowView)
        addSubview(overviewContainer)
    }

    @objc private func handleOverviewDoubleTap() {
        isOverviewExpanded.toggle()
        UIView.animate(withDuration: 0.22, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0.2) {
            self.layoutOverview()
        }
    }

    @objc private func handleOverviewSingleTap(_ recognizer: UITapGestureRecognizer) {
        let tap = recognizer.location(in: overviewContainer)
        let imageRect = AVMakeRect(
            aspectRatio: CGSize(width: max(overviewImageAspectRatio, 0.1), height: 1),
            insideRect: overviewContainer.bounds
        )
        guard imageRect.width > 4, imageRect.height > 4 else { return }
        let currentCenter = CGPoint(x: cropWindowView.frame.midX, y: cropWindowView.frame.midY)
        let dx = (currentCenter.x - tap.x) / imageRect.width
        let dy = (tap.y - currentCenter.y) / imageRect.height
        stabilizationEngine.nudgeDesiredCenter(normalizedDeltaX: dx * 0.65, normalizedDeltaY: dy * 0.65)
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
        let scale: CGFloat = isOverviewExpanded ? 1.48 : 1.0
        let width = min(max(shortSide * 0.18, 72), 92) * scale
        let contentAspect = max(overviewImageAspectRatio, 0.1)
        let height = min(width / contentAspect, width * 1.35)
        let topInset: CGFloat = bounds.height > bounds.width ? 104 : 98
        overviewContainer.frame = CGRect(
            x: bounds.maxX - width - 12,
            y: topInset,
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

        let borderColor: UIColor
        if latestCropUsage >= 0.82 {
            borderColor = .systemRed
        } else if latestCropUsage >= 0.58 {
            borderColor = .systemOrange
        } else {
            borderColor = .systemYellow
        }
        cropWindowView.layer.borderColor = borderColor.cgColor
        cropCenterHorizontalView.backgroundColor = borderColor
        cropCenterVerticalView.backgroundColor = borderColor

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
        guard motionTime.isFinite, motionTime - lastOverviewUpdateTime >= 0.18 else { return }
        overviewBusyLock.lock()
        guard !isOverviewBusy else {
            overviewBusyLock.unlock()
            return
        }
        isOverviewBusy = true
        overviewBusyLock.unlock()
        lastOverviewUpdateTime = motionTime
        let retainedPixelBuffer = pixelBuffer
        preferenceLock.lock()
        let buildPeaking = isFocusPeakingEnabled
        preferenceLock.unlock()

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
            let peakingOverlay = buildPeaking ? Self.makeFocusPeakingOverlay(from: retainedPixelBuffer) : nil
            let aspectRatio = image.extent.width / max(image.extent.height, 1)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.overviewImageAspectRatio = aspectRatio
                self.overviewImageView.image = thumbnail
                if buildPeaking {
                    self.focusPeakingImageView.image = peakingOverlay
                    self.focusPeakingImageView.isHidden = peakingOverlay == nil
                } else {
                    self.focusPeakingImageView.isHidden = true
                }
                self.layoutCropWindow()
            }
        }
    }

    private static func makeFocusPeakingOverlay(from pixelBuffer: CVPixelBuffer) -> UIImage? {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let isBiPlanar = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
            format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let srcW = isBiPlanar ? CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) : CVPixelBufferGetWidth(pixelBuffer)
        let srcH = isBiPlanar ? CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) : CVPixelBufferGetHeight(pixelBuffer)
        let bpr = isBiPlanar ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) : CVPixelBufferGetBytesPerRow(pixelBuffer)
        let rawPtr = isBiPlanar ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) : CVPixelBufferGetBaseAddress(pixelBuffer)
        guard let base = rawPtr?.assumingMemoryBound(to: UInt8.self), srcW > 32, srcH > 32 else { return nil }

        let outW = 180
        let outH = max(100, Int((Double(outW) * Double(srcH) / Double(srcW)).rounded()))
        var rgba = [UInt8](repeating: 0, count: outW * outH * 4)
        let stepX = max(1, srcW / outW)
        let stepY = max(1, srcH / outH)
        let pixelStride = isBiPlanar ? 1 : 4
        let lumaOffset = isBiPlanar ? 0 : 1

        for y in 2..<(outH - 2) {
            let sy = min(srcH - 2, y * stepY)
            let row = base + sy * bpr
            let rowDown = base + min(srcH - 1, sy + stepY) * bpr
            for x in 2..<(outW - 2) {
                let sx = min(srcW - 2, x * stepX)
                let c = Int(row[sx * pixelStride + lumaOffset])
                let r = Int(row[min(srcW - 1, sx + stepX) * pixelStride + lumaOffset])
                let d = Int(rowDown[sx * pixelStride + lumaOffset])
                let grad = abs(r - c) + abs(d - c)
                if grad >= 34 {
                    let idx = (y * outW + x) * 4
                    let alpha = UInt8(min(245, (grad - 26) * 5))
                    rgba[idx] = 16
                    rgba[idx + 1] = 255
                    rgba[idx + 2] = 110
                    rgba[idx + 3] = alpha
                }
            }
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cgImg = CGImage(
                  width: outW,
                  height: outH,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: outW * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else {
            return nil
        }
        return UIImage(cgImage: cgImg)
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
        var viewport: CGSize
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
        var timestamp: TimeInterval = 0
        var qualityScore: Double = 1
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
    private var recentPhotoFrames: [DisplayedPhotoFrame] = []
    private let inFlightFrames = DispatchSemaphore(value: 2)
    private var presentationMetrics = PresentationMetrics()
    private var presentationGeneration = 0
    private var presentationTargetFPS = 60

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
        sourceTimestamp: TimeInterval,
        viewport: CGSize
    ) {
        guard motionTime.isFinite, sourceTimestamp.isFinite else { return }
        stateLock.lock()
        enqueuedFrameCount += 1
        frameQueue.append(
            QueuedPreviewFrame(
                pixelBuffer: pixelBuffer,
                motionTime: motionTime,
                sourceTimestamp: sourceTimestamp,
                isReady: false,
                viewport: viewport
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
        guard frameQueue.contains(where: { abs($0.motionTime - timestamp) < 0.0005 }) else {
            stateLock.unlock()
            return
        }
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
        var readyFrame: QueuedPreviewFrame?
        var transform = PreviewRenderTransform.identity
        let scale = cropWindowScale
        if let index = frameQueue.lastIndex(where: { abs($0.motionTime - timestamp) < 0.0005 }) {
            if !frameQueue[index].isReady {
                frameQueue[index].isReady = true
                readyFrameCount += 1
                readyFrame = frameQueue[index]
                transform = renderTransformForFrame(at: timestamp)
                if readyFrame!.viewport.width > 1, readyFrame!.viewport.height > 1 {
                    let candidate = DisplayedPhotoFrame(
                        pixelBuffer: readyFrame!.pixelBuffer,
                        transform: transform,
                        cropScale: scale,
                        logicalViewport: readyFrame!.viewport,
                        timestamp: timestamp,
                        qualityScore: 0.78
                    )
                    if displayedPhotoFrame == nil || recorder.isRecording {
                        displayedPhotoFrame = candidate
                    }
                }
            }
        }
        stateLock.unlock()
        // Recording consumes completed stabilization results, never display callbacks.
        if let readyFrame, recorder.isRecording {
            let size = CGSize(width: CVPixelBufferGetWidth(readyFrame.pixelBuffer), height: CVPixelBufferGetHeight(readyFrame.pixelBuffer))
            let image = CIImage(cvPixelBuffer: readyFrame.pixelBuffer)
            let output = CameraGeometry.outputSize(for: size)
            let stabilized = image.transformed(by: imageToOutputTransform(
                imageExtent: image.extent, outputSize: output, logicalViewport: readyFrame.viewport,
                previewTransform: transform, cropWindowScale: scale
            ))
            recorder.append(stabilizedImage: stabilized, sourceTimestamp: readyFrame.sourceTimestamp,
                            outputSize: output, ciContext: ciContext, colorSpace: colorSpace)
        }
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
        recentPhotoFrames.removeAll(keepingCapacity: true)
        presentationGeneration += 1
        presentationMetrics = PresentationMetrics()
        stateLock.unlock()
    }

    var isRecording: Bool {
        recorder.isRecording
    }

    func startRecording(
        to outputURL: URL,
        includeAudio: Bool,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        recorder.startRecording(to: outputURL, includeAudio: includeAudio, completion: completion)
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) { recorder.appendAudio(sampleBuffer) }

    func photoContext() -> StabilizedPhotoContext? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let frame = bestPhotoFrameLocked() else { return nil }
        return StabilizedPhotoContext(
            sourceSize: CGSize(width: CVPixelBufferGetWidth(frame.pixelBuffer), height: CVPixelBufferGetHeight(frame.pixelBuffer)),
            viewport: frame.logicalViewport, transform: frame.transform, cropScale: frame.cropScale
        )
    }

    func sourceFocusPoint(from normalized: CGPoint) -> CGPoint? {
        guard let context = photoContext() else { return nil }
        return CameraGeometry.sourcePoint(
            from: CGPoint(x: normalized.x * context.viewport.width, y: normalized.y * context.viewport.height),
            source: context.sourceSize, viewport: context.viewport,
            correction: context.transform, cropScale: context.cropScale
        )
    }

    func processPhoto(_ data: Data, context: StabilizedPhotoContext, completion: @escaping (Result<Data, Error>) -> Void) {
        photoQueue.async {
            autoreleasepool {
                guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
                    completion(.failure(StabilizedPhotoCaptureError.encodingFailed))
                    return
                }
                let outputSize = CameraGeometry.outputSize(for: image.extent.size)
                let transformed = image.transformed(by: self.imageToOutputTransform(
                    imageExtent: image.extent, outputSize: outputSize, logicalViewport: context.viewport,
                    previewTransform: context.transform, cropWindowScale: context.cropScale
                ))
                guard let jpeg = self.ciContext.jpegRepresentation(of: transformed.cropped(to: CGRect(origin: .zero, size: outputSize)),
                                                                 colorSpace: self.colorSpace, options: [:]) else {
                    completion(.failure(StabilizedPhotoCaptureError.encodingFailed))
                    return
                }
                completion(.success(jpeg))
            }
        }
    }

    func stopRecording() {
        recorder.stopRecording()
    }

    func setTargetFrameRate(_ frameRate: Int) {
        stateLock.lock()
        presentationTargetFPS = frameRate
        stateLock.unlock()
        recorder.setTargetFrameRate(frameRate)
    }

    func capturePhoto(
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        photoQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let photoFrame = self.bestPhotoFrameLocked()
            self.stateLock.unlock()
            guard let photoFrame else {
                completion(.failure(StabilizedPhotoCaptureError.previewNotReady))
                return
            }
            let image = CIImage(cvPixelBuffer: photoFrame.pixelBuffer)
            let outputSize = CameraGeometry.outputSize(
                for: CGSize(
                    width: CVPixelBufferGetWidth(photoFrame.pixelBuffer),
                    height: CVPixelBufferGetHeight(photoFrame.pixelBuffer)
                )
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
            if let jpegData = self.ciContext.jpegRepresentation(
                of: stabilizedImage.cropped(to: outputBounds),
                colorSpace: self.colorSpace,
                options: [:]
            ) {
                completion(.success(jpegData))
                return
            }
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
        stateLock.lock()
        let hasPendingFrames = frameQueue.contains(where: \.isReady)
        stateLock.unlock()
        guard hasPendingFrames, inFlightFrames.wait(timeout: .now()) == .success else { return }
        var committed = false
        defer { if !committed { inFlightFrames.signal() } }
        // Do not remove a ready frame until there is a drawable to render it into.
        let drawableSize = view.drawableSize
        guard drawableSize.width > 1, drawableSize.height > 1,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        let recording = recorder.isRecording
        stateLock.lock()
        let queuedFrame = nextFrameForDisplay(preferOldestReady: false)
        let transform = queuedFrame.map { renderTransformForFrame(at: $0.motionTime) } ?? .identity
        let cropScale = cropWindowScale
        let generation = presentationGeneration
        if queuedFrame != nil { presentationMetrics.submit() }
        let telemetry: [String: Any]?
        if queuedFrame != nil, displayedFrameCount > 0, displayedFrameCount.isMultiple(of: 120) {
            let measuredFPS = displayedIntervalTotal > 0
                ? Double(displayedIntervalCount) / displayedIntervalTotal
                : 0
            telemetry = [
                "enqueued": enqueuedFrameCount,
                "ready": readyFrameCount,
                "selected": displayedFrameCount,
                "submitted": presentationMetrics.submitted,
                "displayed": presentationMetrics.presented,
                "gpu_failed": presentationMetrics.failed,
                "presented_fps": presentationMetrics.fps,
                "late_presentations": presentationMetrics.lateIntervals,
                "queue_drops": queueDropCount,
                "skipped_ready": skippedReadyFrameCount,
                "source_gaps_over_25ms": longDisplayGapCount,
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
        guard let queuedFrame else { return }

        let image = CIImage(cvPixelBuffer: queuedFrame.pixelBuffer)
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
        let frameSharpness = quickCenterSharpness(pixelBuffer: queuedFrame.pixelBuffer)
        stateLock.lock()
        let previousTranslation = displayedPhotoFrame?.transform
        let motionStep = previousTranslation.map {
            hypot(transform.translationX - $0.translationX, transform.translationY - $0.translationY)
        } ?? 0
        let stabilityWeight = 1.0 / (1.0 + Double(motionStep) * 0.15)
        let candidatePhoto = DisplayedPhotoFrame(
            pixelBuffer: queuedFrame.pixelBuffer,
            transform: transform,
            cropScale: cropScale,
            logicalViewport: view.bounds.size,
            timestamp: queuedFrame.motionTime,
            qualityScore: frameSharpness * 0.65 + stabilityWeight * 0.35
        )
        displayedPhotoFrame = candidatePhoto
        recentPhotoFrames.append(candidatePhoto)
        let freshnessCutoff = queuedFrame.motionTime - 0.10
        recentPhotoFrames.removeAll { $0.timestamp < freshnessCutoff }
        if recentPhotoFrames.count > 4 {
            recentPhotoFrames.removeFirst(recentPhotoFrames.count - 4)
        }
        stateLock.unlock()

        ciContext.render(
            previewImage,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: renderBounds,
            colorSpace: colorSpace
        )
        let submittedTime = CACurrentMediaTime()
        let frameTime = queuedFrame.motionTime
        let sourceTime = queuedFrame.sourceTimestamp
        drawable.addPresentedHandler { [weak self] drawable in
            guard let self else { return }
            self.stateLock.lock()
            let current = generation == self.presentationGeneration
            if current {
                self.presentationMetrics.present(at: drawable.presentedTime, targetFPS: self.presentationTargetFPS)
            }
            self.stateLock.unlock()
            guard current else { return }
            StabilizationTraceRecorder.shared.recordControl("frame_presented", values: [
                "frame_t": frameTime, "source_pts": sourceTime, "submitted_t": submittedTime,
                "presented_t": drawable.presentedTime,
                "presented": drawable.presentedTime > 0,
                "frame_age_ms": drawable.presentedTime > 0 ? (drawable.presentedTime - frameTime) * 1000 : -1
            ])
        }
        commandBuffer.addCompletedHandler { [weak self, inFlightFrames] buffer in
            inFlightFrames.signal()
            guard let self else { return }
            self.stateLock.lock()
            let current = generation == self.presentationGeneration
            if current, buffer.status == .error { self.presentationMetrics.fail() }
            self.stateLock.unlock()
            guard current else { return }
            StabilizationTraceRecorder.shared.recordControl("frame_gpu", values: [
                "frame_t": frameTime, "gpu_ms": max(0, buffer.gpuEndTime - buffer.gpuStartTime) * 1000,
                "completed_t": CACurrentMediaTime(), "success": buffer.status == .completed
            ])
        }
        commandBuffer.present(drawable)
        committed = true
        commandBuffer.commit()
    }

    private func nextFrameForDisplay(preferOldestReady: Bool) -> QueuedPreviewFrame? {
        // 已标记 isReady 的帧已完成防抖变换配对，无需等待下一帧相机回调入队；
        // 当就绪帧数 <= 2 时按 FIFO 顺序消费，消除 60 Hz 采集与 60 Hz VSync 拍频
        // 引起的周期性空转与跳帧；仅在积压超过 2 帧时跳至最新就绪帧以控制延迟。
        let readyIndices = frameQueue.indices.filter { frameQueue[$0].isReady }
        guard !readyIndices.isEmpty else { return nil }
        let selectedIndex = (preferOldestReady || readyIndices.count <= 2)
            ? readyIndices.first!
            : readyIndices.last!
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
                    (next.transform.translationY - previous.transform.translationY) * amount,
                rollingShearX: previous.transform.rollingShearX +
                    (next.transform.rollingShearX - previous.transform.rollingShearX) * amount,
                rollingStretchY: previous.transform.rollingStretchY +
                    (next.transform.rollingStretchY - previous.transform.rollingStretchY) * amount
            )
        } else {
            selected = previous.transform
        }
        if previousIndex > 4 {
            renderTransformHistory.removeFirst(previousIndex - 3)
        }
        return selected
    }

    private func bestPhotoFrameLocked() -> DisplayedPhotoFrame? {
        guard let latest = displayedPhotoFrame else { return nil }
        let cutoff = latest.timestamp - 0.10
        let candidates = recentPhotoFrames.filter { $0.timestamp >= cutoff }
        return candidates.max(by: { $0.qualityScore < $1.qualityScore }) ?? latest
    }

    private func quickCenterSharpness(pixelBuffer: CVPixelBuffer) -> Double {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return 0.5
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)?.assumingMemoryBound(to: UInt8.self) else {
            return 0.5
        }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let strideBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        guard width >= 64, height >= 64 else { return 0.5 }
        let startX = width * 3 / 8
        let endX = width * 5 / 8
        let startY = height * 3 / 8
        let endY = height * 5 / 8
        let stepX = max((endX - startX) / 16, 2)
        let stepY = max((endY - startY) / 16, 2)
        var gradientSum = 0.0
        var sampleCount = 0.0
        for y in stride(from: startY, to: endY - 1, by: stepY) {
            let row = y * strideBytes
            let nextRow = (y + 1) * strideBytes
            for x in stride(from: startX, to: endX - 1, by: stepX) {
                let center = Double(base[row + x])
                let dx = abs(center - Double(base[row + x + 1]))
                let dy = abs(center - Double(base[nextRow + x]))
                gradientSum += dx + dy
                sampleCount += 1
            }
        }
        guard sampleCount > 0 else { return 0.5 }
        return min(max(gradientSum / (sampleCount * 32.0), 0.1), 1.0)
    }

    private func imageToOutputTransform(
        imageExtent: CGRect,
        outputSize: CGSize,
        logicalViewport: CGSize,
        previewTransform: PreviewRenderTransform,
        cropWindowScale: CGFloat
    ) -> CGAffineTransform {
        CameraGeometry.transform(source: imageExtent, output: outputSize, viewport: logicalViewport,
                                 correction: previewTransform, cropScale: cropWindowScale)
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
    private var audioInput: AVAssetWriterInput?
    private var includeAudio = false
    private var pendingAudioCount = 0
    private var lastAudioTimestamp: CMTime?
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
    private var recordingGeneration: UInt64 = 0
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
        includeAudio: Bool,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        lock.lock()
        guard state == .idle else {
            lock.unlock()
            completion(.failure(StabilizedPreviewRecorderError.alreadyRecording))
            return
        }
        try? FileManager.default.removeItem(at: outputURL)
        recordingGeneration &+= 1
        self.outputURL = outputURL
        self.completion = completion
        self.includeAudio = includeAudio
        audioInput = nil
        pendingAudioCount = 0
        lastAudioTimestamp = nil
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
        lock.lock()
        let generation = recordingGeneration
        lock.unlock()
        recordingQueue.async { [weak self] in
            self?.stopRecordingOnQueue(generation: generation)
        }
    }

    func setTargetFrameRate(_ frameRate: Int) {
        lock.lock()
        targetFrameRate = max(24, min(frameRate, 60))
        lock.unlock()
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        guard includeAudio, state == .waitingForFirstFrame || state == .recording,
              pendingAudioCount < 8 else { lock.unlock(); return }
        pendingAudioCount += 1
        let generation = recordingGeneration
        lock.unlock()
        recordingQueue.async {
            self.lock.lock()
            guard self.recordingGeneration == generation else { self.lock.unlock(); return }
            defer {
                self.pendingAudioCount = max(0, self.pendingAudioCount - 1)
                self.lock.unlock()
            }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard self.state == .recording, let first = self.firstSourceTimestamp,
                  let audioInput = self.audioInput, audioInput.isReadyForMoreMediaData,
                  CMSampleBufferDataIsReady(sampleBuffer), timestamp.isValid,
                  CMTimeGetSeconds(timestamp) >= first,
                  self.lastAudioTimestamp.map({ CMTimeCompare(timestamp, $0) > 0 }) ?? true else { return }
            if audioInput.append(sampleBuffer) { self.lastAudioTimestamp = timestamp }
        }
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
        let generation = recordingGeneration
        lock.unlock()
        recordingQueue.async { [weak self] in
            guard let self else { return }
            defer { self.decrementPendingAppendCount(generation: generation) }
            self.appendOnRecordingQueue(
                stabilizedImage: stabilizedImage,
                sourceTimestamp: sourceTimestamp,
                outputSize: outputSize,
                ciContext: ciContext,
                colorSpace: colorSpace,
                generation: generation
            )
        }
    }

    private func stopRecordingOnQueue(generation: UInt64) {
        lock.lock()
        guard recordingGeneration == generation else { lock.unlock(); return }
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
        colorSpace: CGColorSpace,
        generation: UInt64
    ) {
        lock.lock()
        guard recordingGeneration == generation, state == .waitingForFirstFrame || state == .recording else {
            lock.unlock()
            return
        }
        if state == .waitingForFirstFrame {
            do {
                try startWriterLocked(outputSize: outputSize, sourceTimestamp: sourceTimestamp)
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
        let presentationTime = CMTime(
            seconds: sourceTimestamp,
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

    private func decrementPendingAppendCount(generation: UInt64) {
        lock.lock()
        if recordingGeneration == generation { pendingAppendCount = max(0, pendingAppendCount - 1) }
        lock.unlock()
    }

    private func startWriterLocked(outputSize: CGSize, sourceTimestamp: TimeInterval) throws {
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
        if includeAudio {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000
            ])
            audio.expectsMediaDataInRealTime = true
            guard writer.canAdd(audio) else { throw StabilizedPreviewRecorderError.inputUnavailable }
            writer.add(audio)
            audioInput = audio
        }
        guard writer.startWriting() else {
            throw writer.error ?? StabilizedPreviewRecorderError.writerFailed
        }
        writer.startSession(atSourceTime: CMTime(seconds: sourceTimestamp, preferredTimescale: 60_000))
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        recordingFrameRate = expectedFrameRate
        writtenFrameCount = 0
        firstSourceTimestamp = sourceTimestamp
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
        let size = CameraGeometry.outputSize(for: CGSize(width: sourceWidth * scale, height: sourceHeight * scale))
        return (Int(size.width), Int(size.height))
    }

    private func finishWriterLocked() {
        guard let writer, let input, let outputURL else {
            finishLocked(result: .failure(StabilizedPreviewRecorderError.writerMissing))
            return
        }
        state = .finishing
        input.markAsFinished()
        audioInput?.markAsFinished()
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
        audioInput = nil
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
    var isFocusPeakingEnabled: Bool = false
    var onTelemetryUpdate: ((CGFloat, Bool, CGPoint) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.onTelemetryUpdate = onTelemetryUpdate
        view.updateStabilizationSettings(
            preference: stabilizationPreference,
            isStabilizationEnabled: isStabilizationEnabled,
            opticalMagnification: opticalMagnification,
            displayZoomFactor: displayZoomFactor,
            systemModeName: systemStabilizationModeName,
            isFocusPeakingEnabled: isFocusPeakingEnabled
        )
        context.coordinator.attach(
            to: view,
            camera: camera,
            motionMonitor: motionMonitor
        )
        return view
    }

    func updateUIView(_ view: PreviewContainerView, context: Context) {
        view.onTelemetryUpdate = onTelemetryUpdate
        view.updateStabilizationSettings(
            preference: stabilizationPreference,
            isStabilizationEnabled: isStabilizationEnabled,
            opticalMagnification: opticalMagnification,
            displayZoomFactor: displayZoomFactor,
            systemModeName: systemStabilizationModeName,
            isFocusPeakingEnabled: isFocusPeakingEnabled
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
