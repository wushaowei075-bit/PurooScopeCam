import AVFoundation
import CoreGraphics
import Foundation
import QuartzCore

struct StabilizationFrameResult {
    var timestamp: TimeInterval
    var transform: PreviewRenderTransform
    var normalizedCorrectionX: CGFloat
    var normalizedCorrectionY: CGFloat
    var debug: StabilizationDebugSnapshot
    var vignetteCenterOffset: CGPoint = .zero
}

struct StabilizationDebugSnapshot {
    var cropScale: CGFloat
    var visualDeltaX: CGFloat
    var visualDeltaY: CGFloat
    var visualConfidence: CGFloat
    var visualVectorCount: Int
    var visualTexture: CGFloat
    var fusedDeltaX: CGFloat
    var fusedDeltaY: CGFloat
    var lowFrequencyDeltaX: CGFloat
    var lowFrequencyDeltaY: CGFloat
    var highFrequencyDeltaX: CGFloat
    var highFrequencyDeltaY: CGFloat
    var correctionX: CGFloat
    var correctionY: CGFloat
    var correctionRollDegrees: CGFloat
    var gyroTrust: CGFloat
    var gyroAvailable: Bool
    var predictedGyroDeltaX: CGFloat
    var predictedGyroDeltaY: CGFloat
    var automaticTimeOffsetMilliseconds: Double
    var opticalMagnification: CGFloat
    var referenceMagnification: CGFloat
    var gyroCorrelationX: CGFloat
    var gyroCorrelationY: CGFloat
    var gyroNormalizedError: CGFloat
    var isGyroCalibrationValid: Bool
    var isIntentionalPan: Bool
    var cropUsage: CGFloat
    var boundaryPressure: CGFloat
    var analysisMilliseconds: Double
    var droppedAnalysisFrames: Int
    var motionSampleCount: Int
    var focalLengthPixelsX: CGFloat
    var focalLengthPixelsY: CGFloat
    var frameWidth: Int
    var frameHeight: Int
    var calibrationState: String
    var calibrationAgeSeconds: Double
    var calibrationSamples: Int
    var cropRequestedLowX: CGFloat
    var cropRequestedLowY: CGFloat
    var cropRequestedHighX: CGFloat
    var cropRequestedHighY: CGFloat
    var cropAppliedLowX: CGFloat
    var cropAppliedLowY: CGFloat
    var cropAppliedHighX: CGFloat
    var cropAppliedHighY: CGFloat
    var cropPreUsage: CGFloat

    func overlayText(systemModeName: String) -> String {
        """
        防抖调试  系统:\(systemModeName)  单链路
        裁切:\(format(Double(cropScale), digits: 2))x  状态:\(isIntentionalPan ? "平移" : "稳像")
        视觉 X:\(format(Double(visualDeltaX), digits: 5)) Y:\(format(Double(visualDeltaY), digits: 5)) C:\(format(Double(visualConfidence), digits: 2)) V:\(visualVectorCount)
        融合 X:\(format(Double(fusedDeltaX), digits: 5)) Y:\(format(Double(fusedDeltaY), digits: 5))  陀螺信任:\(format(Double(gyroTrust), digits: 2))
        高频 X:\(format(Double(highFrequencyDeltaX), digits: 5)) Y:\(format(Double(highFrequencyDeltaY), digits: 5))  低频 X:\(format(Double(lowFrequencyDeltaX), digits: 5)) Y:\(format(Double(lowFrequencyDeltaY), digits: 5))
        裁切 X:\(format(Double(correctionX), digits: 4)) Y:\(format(Double(correctionY), digits: 4)) 转:\(format(Double(correctionRollDegrees), digits: 2))° 使用:\(format(Double(cropUsage * 100), digits: 0))%
        倍率:\(format(Double(opticalMagnification), digits: 2))/\(format(Double(referenceMagnification), digits: 0))x  焦距:\(format(Double(focalLengthPixelsX), digits: 0))px  画幅:\(frameWidth)x\(frameHeight)
        相关:\(format(Double(gyroCorrelationX), digits: 2)),\(format(Double(gyroCorrelationY), digits: 2))  误差:\(format(Double(gyroNormalizedError), digits: 2))  标定:\(isGyroCalibrationValid ? "有效" : "等待")
        分析:\(format(analysisMilliseconds, digits: 1))ms  丢弃:\(droppedAnalysisFrames)  IMU:\(motionSampleCount)  纹理:\(format(Double(visualTexture), digits: 1))
        """
    }

    private func format(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }
}

final class StabilizationTraceRecorder {
    static let shared = StabilizationTraceRecorder()

    private let queue = DispatchQueue(label: "com.puroo.scope.stabilizationTrace", qos: .utility)
    private let stateLock = NSLock()
    private var fileHandle: FileHandle?
    private var writeBuffer = Data()
    private var isActive = false
    private var replayPairCount = 0
    var isDiagnosticsEnabled: Bool = {
        if let env = ProcessInfo.processInfo.environment["PUROO_TRACE_ENABLED"] {
            return env == "1" || env.lowercased() == "true"
        }
        if UserDefaults.standard.object(forKey: "puroo.trace.enabled") != nil {
            return UserDefaults.standard.bool(forKey: "puroo.trace.enabled")
        }
        return false
    }()

    var hasActiveSession: Bool {
        stateLock.lock()
        let active = isActive
        stateLock.unlock()
        return active
    }

    private init() {}

    func startSession(metadata: [String: Any]) {
        guard isDiagnosticsEnabled else { return }
        queue.async { [weak self] in
            guard let self, !self.isActive else { return }
            guard let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first else {
                return
            }

            let directory = documents.appendingPathComponent(
                "PurooStabilizationTraces",
                isDirectory: true
            )
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                self.removeExpiredTraces(in: directory)

                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
                let fileURL = directory
                    .appendingPathComponent("trace-\(formatter.string(from: Date()))")
                    .appendingPathExtension("jsonl")
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                self.fileHandle = try FileHandle(forWritingTo: fileURL)
                self.stateLock.lock()
                self.isActive = true
                self.stateLock.unlock()
                self.replayPairCount = 0

                var header = metadata
                header["type"] = "session"
                header["created_at"] = ISO8601DateFormatter().string(from: Date())
                header["format_version"] = 9
                header["app_build"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
                header["app_version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
                self.appendJSONObject(header)
                self.flushIfNeeded(force: true)
            } catch {
                self.fileHandle = nil
                self.stateLock.lock()
                self.isActive = false
                self.stateLock.unlock()
            }
        }
    }

    func stopSession() {
        queue.async { [weak self] in
            guard let self, self.isActive else { return }
            self.appendJSONObject([
                "type": "session_end",
                "host_time": CACurrentMediaTime()
            ])
            self.flushIfNeeded(force: true)
            try? self.fileHandle?.synchronize()
            try? self.fileHandle?.close()
            self.fileHandle = nil
            self.stateLock.lock()
            self.isActive = false
            self.stateLock.unlock()
        }
    }

    func recordMotion(_ sample: StabilitySample) {
        record(
            type: "motion",
            timestamp: sample.timestamp,
            values: [
                "rx": sample.rotationX,
                "ry": sample.rotationY,
                "rz": sample.rotationZ,
                "qx": sample.quaternionX,
                "qy": sample.quaternionY,
                "qz": sample.quaternionZ,
                "qw": sample.quaternionW,
                "angular_velocity": sample.angularVelocity
            ]
        )
    }

    func recordControl(_ name: String, values: [String: Any] = [:]) {
        var payload = values
        payload["name"] = name
        record(type: "control", timestamp: CACurrentMediaTime(), values: payload)
    }

    func recordComparison(_ values: [String: Any], reference: [Float], current: [Float],
                          completion: @escaping () -> Void) {
        queue.async { [weak self] in
            defer { completion() }
            guard let self, self.isActive else { return }
            var payload = values
            payload["type"] = "estimator_comparison"
            // Only twelve low-resolution pairs per trace, never full camera frames.
            if self.replayPairCount < 12 {
                payload["luma_encoding"] = "float32-le-base64"
                payload["reference_luma"] = reference.withUnsafeBytes { Data($0).base64EncodedString() }
                payload["current_luma"] = current.withUnsafeBytes { Data($0).base64EncodedString() }
                self.replayPairCount += 1
            }
            self.appendJSONObject(payload)
            self.flushIfNeeded(force: false)
        }
    }

    func recordFrame(_ result: StabilizationFrameResult) {
        let debug = result.debug
        record(
            type: "frame",
            timestamp: result.timestamp,
            values: [
                "crop_scale": debug.cropScale,
                "visual_dx": debug.visualDeltaX,
                "visual_dy": debug.visualDeltaY,
                "visual_confidence": debug.visualConfidence,
                "visual_vectors": debug.visualVectorCount,
                "fused_dx": debug.fusedDeltaX,
                "fused_dy": debug.fusedDeltaY,
                "low_dx": debug.lowFrequencyDeltaX,
                "low_dy": debug.lowFrequencyDeltaY,
                "high_dx": debug.highFrequencyDeltaX,
                "high_dy": debug.highFrequencyDeltaY,
                "crop_x": debug.correctionX,
                "crop_y": debug.correctionY,
                "crop_usage": debug.cropUsage,
                "crop_roll_deg": debug.correctionRollDegrees,
                "boundary_pressure": debug.boundaryPressure,
                "crop_requested_low_x": debug.cropRequestedLowX,
                "crop_requested_low_y": debug.cropRequestedLowY,
                "crop_requested_high_x": debug.cropRequestedHighX,
                "crop_requested_high_y": debug.cropRequestedHighY,
                "crop_applied_low_x": debug.cropAppliedLowX,
                "crop_applied_low_y": debug.cropAppliedLowY,
                "crop_applied_high_x": debug.cropAppliedHighX,
                "crop_applied_high_y": debug.cropAppliedHighY,
                "crop_pre_usage": debug.cropPreUsage,
                "pan": debug.isIntentionalPan,
                "gyro_trust": debug.gyroTrust,
                "gyro_available": debug.gyroAvailable,
                "gyro_predicted_dx": debug.predictedGyroDeltaX,
                "gyro_predicted_dy": debug.predictedGyroDeltaY,
                "magnification": debug.opticalMagnification,
                "magnification_ref": debug.referenceMagnification,
                "focal_px_x": debug.focalLengthPixelsX,
                "focal_px_y": debug.focalLengthPixelsY,
                "frame_w": debug.frameWidth,
                "frame_h": debug.frameHeight,
                "gyro_correlation_x": debug.gyroCorrelationX,
                "gyro_correlation_y": debug.gyroCorrelationY,
                "gyro_nrmse": debug.gyroNormalizedError,
                "gyro_calibration_valid": debug.isGyroCalibrationValid,
                "calibration_state": debug.calibrationState,
                "calibration_age_s": debug.calibrationAgeSeconds,
                "calibration_samples": debug.calibrationSamples,
                "auto_offset_ms": debug.automaticTimeOffsetMilliseconds,
                "analysis_ms": debug.analysisMilliseconds,
                "analysis_drops": debug.droppedAnalysisFrames,
                "motion_samples": debug.motionSampleCount
            ]
        )
    }

    private func record(type: String, timestamp: TimeInterval, values: [String: Any]) {
        guard hasActiveSession, timestamp.isFinite else { return }
        queue.async { [weak self] in
            guard let self, self.isActive else { return }
            var payload = values
            payload["type"] = type
            payload["t"] = timestamp
            self.appendJSONObject(payload)
            self.flushIfNeeded(force: false)
        }
    }

    private func appendJSONObject(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else {
            return
        }
        writeBuffer.append(data)
        writeBuffer.append(0x0A)
    }

    private func flushIfNeeded(force: Bool) {
        guard force || writeBuffer.count >= 48 * 1024,
              let fileHandle,
              !writeBuffer.isEmpty
        else {
            return
        }
        let data = writeBuffer
        writeBuffer.removeAll(keepingCapacity: true)
        try? fileHandle.write(contentsOf: data)
    }

    private func removeExpiredTraces(in directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let ordered = files.sorted { lhs, rhs in
            let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return leftDate > rightDate
        }
        for file in ordered.dropFirst(5) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

final class FrameStabilizationEngine {
    static let visualGridSize = 288

    private struct FrameInput {
        var pixelBuffer: CVPixelBuffer
        var timestamp: TimeInterval
        var motionReferenceTime: TimeInterval
        var motionSamples: [StabilitySample]
        var videoRotationAngle: CGFloat
        var tuning: StabilizationTuning
        var viewportSize: CGSize
        var focalLengthPixelsX: CGFloat
        var focalLengthPixelsY: CGFloat
        var generation: UInt64
    }

    var onResult: ((StabilizationFrameResult) -> Void)?

    private let queue = DispatchQueue(label: "com.puroo.scope.frameStabilization", qos: .userInteractive)
    private let pendingLock = NSLock()
    private var isProcessing = false
    private var pendingInput: FrameInput?
    private var droppedAnalysisFrames = 0
    private var generation: UInt64 = 0
    private var visualTracker = SubpixelFrameMotionTracker()
    private var motionEstimator = QuaternionMotionEstimator()
    private var fusion = ComplementaryMotionFusion()
    private var trajectory = VirtualCameraTrajectoryController()

    func enqueue(
        pixelBuffer: CVPixelBuffer,
        timestamp: TimeInterval,
        motionReferenceTime: TimeInterval,
        motionSamples: [StabilitySample],
        videoRotationAngle: CGFloat,
        tuning: StabilizationTuning,
        viewportSize: CGSize,
        focalLengthPixelsX: CGFloat,
        focalLengthPixelsY: CGFloat
    ) {
        guard timestamp.isFinite,
              tuning.usesDigitalStabilization,
              viewportSize.width > 1,
              viewportSize.height > 1
        else {
            return
        }

        pendingLock.lock()
        let input = FrameInput(
            pixelBuffer: pixelBuffer,
            timestamp: timestamp,
            motionReferenceTime: motionReferenceTime,
            motionSamples: motionSamples,
            videoRotationAngle: videoRotationAngle,
            tuning: tuning,
            viewportSize: viewportSize,
            focalLengthPixelsX: max(focalLengthPixelsX, 1),
            focalLengthPixelsY: max(focalLengthPixelsY, 1),
            generation: generation
        )

        if isProcessing {
            if pendingInput != nil {
                droppedAnalysisFrames += 1
            }
            pendingInput = input
            pendingLock.unlock()
            return
        }
        isProcessing = true
        pendingLock.unlock()

        queue.async { [weak self] in
            self?.processLoop(startingWith: input)
        }
    }

    func reset() {
        pendingLock.lock()
        generation &+= 1
        pendingInput = nil
        queue.async { [weak self] in
            self?.resetProcessingState()
        }
        pendingLock.unlock()
    }

    func nudgeDesiredCenter(normalizedDeltaX: CGFloat, normalizedDeltaY: CGFloat) {
        queue.async { [weak self] in
            self?.trajectory.nudgeDesired(dx: normalizedDeltaX, dy: normalizedDeltaY)
        }
    }

    private func processLoop(startingWith firstInput: FrameInput) {
        pendingLock.lock()
        let current = firstInput.generation == generation
        pendingLock.unlock()
        if current {
            autoreleasepool { process(firstInput) }
        }
        pendingLock.lock()
        let next = pendingInput
        pendingInput = nil
        if next == nil { isProcessing = false }
        pendingLock.unlock()
        if let next {
            // Yield between frames so reset tasks cannot be starved by new input.
            queue.async { [weak self] in self?.processLoop(startingWith: next) }
        }
    }

    private func process(_ input: FrameInput) {
        let analysisStart = CACurrentMediaTime()
        let gyroCandidates = motionEstimator.candidates(
            samples: input.motionSamples,
            frameTime: input.motionReferenceTime,
            videoRotationAngle: input.videoRotationAngle,
            tuning: input.tuning,
            focalLengthPixelsX: input.focalLengthPixelsX,
            focalLengthPixelsY: input.focalLengthPixelsY,
            frameWidth: CGFloat(CVPixelBufferGetWidth(input.pixelBuffer)),
            frameHeight: CGFloat(CVPixelBufferGetHeight(input.pixelBuffer))
        )
        let gyroHint = fusion.predictedMotionHint(from: gyroCandidates)
        let visual = visualTracker.process(
            pixelBuffer: input.pixelBuffer,
            timestamp: input.timestamp,
            gyroHint: gyroHint,
            displayZoomFactor: input.tuning.displayZoomFactor
        )
        let precedingSample = input.motionSamples.last { $0.timestamp <= input.motionReferenceTime }
        let followingSample = input.motionSamples.first { $0.timestamp >= input.motionReferenceTime }
        StabilizationTraceRecorder.shared.recordControl("imu_frame_alignment", values: [
            "frame_t": input.timestamp,
            "reference_t": input.motionReferenceTime,
            "reference_convention": "mapped_pts_minus_half_exposure_unverified",
            "imu_before_ms": precedingSample.map { (input.motionReferenceTime - $0.timestamp) * 1000 } ?? -1,
            "imu_after_ms": followingSample.map { ($0.timestamp - input.motionReferenceTime) * 1000 } ?? -1,
            "bracketed": precedingSample != nil && followingSample != nil
        ])
        let fused = fusion.update(
            timestamp: input.timestamp,
            visual: visual,
            gyroCandidates: gyroCandidates,
            tuning: input.tuning
        )
        let crop = trajectory.update(
            timestamp: input.timestamp,
            lowFrequencyDeltaX: fused.lowFrequencyDeltaX,
            lowFrequencyDeltaY: fused.lowFrequencyDeltaY,
            highFrequencyDeltaX: fused.highFrequencyDeltaX,
            highFrequencyDeltaY: fused.highFrequencyDeltaY,
            deltaRoll: fused.deltaRoll,
            confidence: fused.confidence,
            tuning: input.tuning,
            rollingShearX: fused.rollingShearX,
            rollingStretchY: fused.rollingStretchY
        )
        let analysisMilliseconds = (CACurrentMediaTime() - analysisStart) * 1000

        pendingLock.lock()
        let droppedFrames = droppedAnalysisFrames
        pendingLock.unlock()

        let transform = PreviewRenderTransform(
            scale: input.tuning.previewCropScale,
            rotationRadians: crop.correctionRoll,
            translationX: crop.correctionX * input.viewportSize.width,
            translationY: crop.correctionY * input.viewportSize.height,
            rollingShearX: crop.correctionShearX,
            rollingStretchY: crop.correctionStretchY
        )
        let debug = StabilizationDebugSnapshot(
            cropScale: input.tuning.previewCropScale,
            visualDeltaX: visual?.deltaX ?? 0,
            visualDeltaY: visual?.deltaY ?? 0,
            visualConfidence: visual?.confidence ?? 0,
            visualVectorCount: visual?.vectorCount ?? 0,
            visualTexture: visual?.texture ?? 0,
            fusedDeltaX: fused.deltaX,
            fusedDeltaY: fused.deltaY,
            lowFrequencyDeltaX: fused.lowFrequencyDeltaX,
            lowFrequencyDeltaY: fused.lowFrequencyDeltaY,
            highFrequencyDeltaX: fused.highFrequencyDeltaX,
            highFrequencyDeltaY: fused.highFrequencyDeltaY,
            correctionX: crop.correctionX,
            correctionY: crop.correctionY,
            correctionRollDegrees: crop.correctionRoll * 180 / .pi,
            gyroTrust: fused.gyroTrust,
            gyroAvailable: fused.gyroAvailable,
            predictedGyroDeltaX: fused.predictedGyroDeltaX,
            predictedGyroDeltaY: fused.predictedGyroDeltaY,
            automaticTimeOffsetMilliseconds: fused.automaticOffset * 1000,
            opticalMagnification: fused.opticalMagnification,
            referenceMagnification: fused.referenceMagnification,
            gyroCorrelationX: fused.gyroCorrelationX,
            gyroCorrelationY: fused.gyroCorrelationY,
            gyroNormalizedError: fused.gyroNormalizedError,
            isGyroCalibrationValid: fused.isGyroCalibrationValid,
            isIntentionalPan: crop.isIntentionalPan,
            cropUsage: crop.cropUsage,
            boundaryPressure: crop.boundaryPressure,
            analysisMilliseconds: analysisMilliseconds,
            droppedAnalysisFrames: droppedFrames,
            motionSampleCount: input.motionSamples.count,
            focalLengthPixelsX: input.focalLengthPixelsX,
            focalLengthPixelsY: input.focalLengthPixelsY,
            frameWidth: CVPixelBufferGetWidth(input.pixelBuffer),
            frameHeight: CVPixelBufferGetHeight(input.pixelBuffer),
            calibrationState: fused.calibrationState,
            calibrationAgeSeconds: fused.calibrationAgeSeconds,
            calibrationSamples: fused.calibrationSamples,
            cropRequestedLowX: crop.requestedLowX,
            cropRequestedLowY: crop.requestedLowY,
            cropRequestedHighX: crop.requestedHighX,
            cropRequestedHighY: crop.requestedHighY,
            cropAppliedLowX: crop.appliedLowX,
            cropAppliedLowY: crop.appliedLowY,
            cropAppliedHighX: crop.appliedHighX,
            cropAppliedHighY: crop.appliedHighY,
            cropPreUsage: crop.preUsage
        )
        let result = StabilizationFrameResult(
            timestamp: input.timestamp,
            transform: transform,
            normalizedCorrectionX: crop.correctionX,
            normalizedCorrectionY: crop.correctionY,
            debug: debug,
            vignetteCenterOffset: visualTracker.latestVignetteOffset
        )
        pendingLock.lock()
        let current = input.generation == generation
        pendingLock.unlock()
        if current {
            StabilizationTraceRecorder.shared.recordFrame(result)
            onResult?(result)
        }
    }

    private func resetProcessingState() {
        visualTracker.reset()
        motionEstimator.reset()
        fusion.reset(keepCalibration: false)
        trajectory.reset()
    }
}

private struct VisualMotionObservation {
    var timestamp: TimeInterval
    var deltaX: CGFloat
    var deltaY: CGFloat
    var confidence: CGFloat
    var vectorCount: Int
    var texture: CGFloat
}

private final class SubpixelFrameMotionTracker {
    private struct AnalysisFrame {
        var luma: [Float]
        var roiMask: [Bool]
        var sourceWidth: Int
        var sourceHeight: Int
        var sourceStep: CGFloat
    }

    private struct PatchVector {
        var dx: CGFloat
        var dy: CGFloat
        var confidence: CGFloat
    }

    // 采样格距决定亚像素估计的下限，而竖屏下横向尺寸只有纵向的 56%，
    // 同样的源像素误差归一化后在横向占比大 1.78 倍。实测输出残余
    // 横向 1.85 源像素、纵向 2.01 源像素，绝对精度接近，可归一化后
    // 横向达 1.712‰ 而纵向 1.045‰，观感上横向抖动因此明显得多。
    //
    // 继续收窄采样区域并加密网格，格距降到 2.06 源像素（精度 +43%）。
    // 分析耗时从 3.82 ms 升到约 7.3 ms，60 fps 的 16.7 ms 预算仍有余量。
    private let gridSize = FrameStabilizationEngine.visualGridSize
    private let searchRadius = 8
    private let guidedSearchRadius = 4
    private let maxGuidedShift = 20
    private let patchRadius = 3
    private let anchorStride = 28
    private lazy var roiMask: [Bool] = makeROIMask()
    private var activeROIMask: [Bool]?
    private var maskUpdateCounter = 0
    private(set) var latestVignetteOffset: CGPoint = .zero
    private var previousFrame: AnalysisFrame?
    private var previousTimestamp: TimeInterval?
    private let phaseEstimator = PhaseCorrelationEstimator()
    private let shadow = VisualEstimatorShadow()

    func reset() {
        previousFrame = nil
        previousTimestamp = nil
        activeROIMask = nil
        maskUpdateCounter = 0
        latestVignetteOffset = .zero
    }

    func process(
        pixelBuffer: CVPixelBuffer,
        timestamp: TimeInterval,
        gyroHint: (dx: CGFloat, dy: CGFloat)? = nil,
        displayZoomFactor: CGFloat = 1
    ) -> VisualMotionObservation? {
        guard let current = makeLumaGrid(from: pixelBuffer) else { return nil }
        guard let previousFrame, let previousTimestamp else {
            self.previousFrame = current
            self.previousTimestamp = timestamp
            return nil
        }

        self.previousFrame = current
        self.previousTimestamp = timestamp
        let elapsed = timestamp - previousTimestamp
        guard elapsed.isFinite, elapsed > 0, elapsed < 0.12,
              previousFrame.sourceWidth == current.sourceWidth,
              previousFrame.sourceHeight == current.sourceHeight else { return nil }
        let highZoom = displayZoomFactor > 3.0
        let effectiveMaxGuidedShift = highZoom ? 28 : maxGuidedShift
        let hintGrid: (dx: Int, dy: Int)? = gyroHint.flatMap { hint in
            let gx = Int((hint.dx * CGFloat(current.sourceWidth) / max(current.sourceStep, 0.001)).rounded())
            let gy = Int((hint.dy * CGFloat(current.sourceHeight) / max(current.sourceStep, 0.001)).rounded())
            guard abs(gx) <= effectiveMaxGuidedShift, abs(gy) <= effectiveMaxGuidedShift else { return nil }
            return (gx, gy)
        }
        let estimate = estimateShift(
            reference: previousFrame,
            current: current,
            hintGrid: hintGrid,
            displayZoomFactor: displayZoomFactor
        )
        var observation = estimate.map {
            VisualMotionObservation(timestamp: timestamp,
                deltaX: $0.dx * current.sourceStep / CGFloat(max(current.sourceWidth, 1)),
                deltaY: $0.dy * current.sourceStep / CGFloat(max(current.sourceHeight, 1)),
                confidence: $0.confidence, vectorCount: $0.vectorCount, texture: $0.texture)
        }
        if observation == nil {
            observation = gatedPhaseFallback(
                reference: previousFrame,
                current: current,
                timestamp: timestamp,
                gyroHint: gyroHint
            )
        }
        shadow.submit(reference: previousFrame.luma, current: current.luma, gridSize: gridSize,
            previousTime: previousTimestamp, time: timestamp, sourceStep: current.sourceStep,
            width: current.sourceWidth, height: current.sourceHeight, visual: observation)
        return observation
    }

    private func gatedPhaseFallback(
        reference: AnalysisFrame,
        current: AnalysisFrame,
        timestamp: TimeInterval,
        gyroHint: (dx: CGFloat, dy: CGFloat)?
    ) -> VisualMotionObservation? {
        guard let phase = phaseEstimator.estimate(
            reference: reference.luma,
            current: current.luma,
            gridSize: gridSize
        ), phase.accepted else {
            return nil
        }
        let phaseDX = CGFloat(phase.dx) * current.sourceStep / CGFloat(max(current.sourceWidth, 1))
        let phaseDY = CGFloat(phase.dy) * current.sourceStep / CGFloat(max(current.sourceHeight, 1))
        let phaseMag = hypot(phaseDX, phaseDY)
        if let gyroHint {
            let gyroMag = hypot(gyroHint.dx, gyroHint.dy)
            if gyroMag > 0.0025 && phaseMag < 0.0005 {
                return nil
            }
            guard hypot(phaseDX - gyroHint.dx, phaseDY - gyroHint.dy) <= 0.0038 else {
                return nil
            }
        } else {
            guard phase.peakToSidelobe >= 14, phase.peakRatio >= 1.35 else {
                return nil
            }
        }
        let psrScore = clamp(CGFloat((phase.peakToSidelobe - 8) / 24), min: 0, max: 1)
        let confidence = clamp(0.32 + psrScore * 0.42, min: 0.30, max: 0.74)
        return VisualMotionObservation(
            timestamp: timestamp,
            deltaX: phaseDX,
            deltaY: phaseDY,
            confidence: confidence,
            vectorCount: 0,
            texture: max(textureScore(reference), 0.85)
        )
    }

    private func estimateShift(
        reference: AnalysisFrame,
        current: AnalysisFrame,
        hintGrid: (dx: Int, dy: Int)? = nil,
        displayZoomFactor: CGFloat = 1
    ) -> (dx: CGFloat, dy: CGFloat, confidence: CGFloat, vectorCount: Int, texture: CGFloat)? {
        // 纹理分数取自相邻采样格的灰度差，与格距成正比。格距从 4.95 收到
        // 2.95 源像素后同一画面的分数降到约六成，门槛必须同步缩放，否则
        // 可用率会跟着塌掉。高倍数码放大（>3x 直至 10x）时 ISP 插值会进一步
        // 平滑相邻像素梯度，按倍率适度放宽纹理门槛以维持 10x 下视觉跟踪连续性。
        let texture = textureScore(reference)
        let highZoomProgress = clamp((displayZoomFactor - 3.0) / 7.0, min: 0, max: 1)
        let minimumTexture: CGFloat = 0.84 - highZoomProgress * 0.20
        guard texture >= minimumTexture else { return nil }
        let activeGuidedRadius = displayZoomFactor > 5.0 ? guidedSearchRadius + 1 : guidedSearchRadius
        let activeSearchRadius = displayZoomFactor > 5.0 ? searchRadius + 2 : searchRadius
        var vectors = patchVectors(
            reference: reference,
            current: current,
            centerShift: hintGrid ?? (0, 0),
            radius: hintGrid != nil ? activeGuidedRadius : activeSearchRadius
        )
        if vectors.count < 6, let hintGrid,
           abs(hintGrid.dx) <= activeSearchRadius, abs(hintGrid.dy) <= activeSearchRadius {
            vectors = patchVectors(
                reference: reference,
                current: current,
                centerShift: (0, 0),
                radius: activeSearchRadius
            )
        }
        guard vectors.count >= 6 else { return nil }

        let medianX = median(vectors.map(\.dx))
        let medianY = median(vectors.map(\.dy))
        // 阈值以采样格为单位。格距收窄后按比例放宽，保持相同的物理容差。
        let inliers = vectors.filter { vector in
            hypot(vector.dx - medianX, vector.dy - medianY) <= 2.15
        }
        // 当画面同时包含角点与一维笔画边缘时，孔径效应会使部分边缘块偏移；
        // 只要至少有 6~12 个块（或 45% 候选块）高度一致，即可由后续残差检查保障精度。
        let minimumInliers = max(6, min(12, Int(ceil(Double(vectors.count) * 0.45))))
        guard inliers.count >= minimumInliers else {
            return nil
        }

        let weight = max(inliers.reduce(CGFloat(0)) { $0 + $1.confidence }, 0.0001)
        let dx = inliers.reduce(CGFloat(0)) { $0 + $1.dx * $1.confidence } / weight
        let dy = inliers.reduce(CGFloat(0)) { $0 + $1.dy * $1.confidence } / weight
        let residual = inliers.reduce(CGFloat(0)) {
            $0 + hypot($1.dx - dx, $1.dy - dy)
        } / CGFloat(inliers.count)
        guard residual <= 1.49 else { return nil }

        let coverage = CGFloat(inliers.count) / CGFloat(vectors.count)
        let matchConfidence = weight / CGFloat(inliers.count)
        let consistency = clamp((1.49 - residual) / 1.49, min: 0, max: 1)
        let textureConfidence = clamp((texture - 0.84) / 3.8, min: 0, max: 1)
        let confidence = clamp(
            coverage * 0.25 + matchConfidence * 0.35 + consistency * 0.25 + textureConfidence * 0.15,
            min: 0,
            max: 1
        )
        guard confidence >= 0.24 else { return nil }
        return (dx, dy, confidence, inliers.count, texture)
    }

    private func patchVectors(
        reference: AnalysisFrame,
        current: AnalysisFrame,
        centerShift: (dx: Int, dy: Int),
        radius: Int
    ) -> [PatchVector] {
        let margin = searchRadius + patchRadius + 2
        var vectors: [PatchVector] = []
        vectors.reserveCapacity(64)
        for y in stride(from: margin, to: gridSize - margin, by: anchorStride) {
            for x in stride(from: margin, to: gridSize - margin, by: anchorStride) {
                let index = y * gridSize + x
                guard reference.roiMask[index],
                      current.roiMask[index],
                      patchTexture(reference, centerX: x, centerY: y) > 0.91,
                      let vector = bestPatchVector(
                          reference: reference,
                          current: current,
                          centerX: x,
                          centerY: y,
                          shiftCenterX: centerShift.dx,
                          shiftCenterY: centerShift.dy,
                          radius: radius
                      )
                else {
                    continue
                }
                vectors.append(vector)
            }
        }
        return vectors
    }

    private func bestPatchVector(
        reference: AnalysisFrame,
        current: AnalysisFrame,
        centerX: Int,
        centerY: Int,
        shiftCenterX: Int,
        shiftCenterY: Int,
        radius: Int
    ) -> PatchVector? {
        let diameter = radius * 2 + 1
        var scores = Array(repeating: Float.greatestFiniteMagnitude, count: diameter * diameter)
        var bestScore = Float.greatestFiniteMagnitude
        var secondScore = Float.greatestFiniteMagnitude
        var bestLocalDX = 0
        var bestLocalDY = 0

        for localDY in -radius...radius {
            let dy = shiftCenterY + localDY
            for localDX in -radius...radius {
                let dx = shiftCenterX + localDX
                guard let score = normalizedPatchScore(
                    reference: reference,
                    current: current,
                    centerX: centerX,
                    centerY: centerY,
                    dx: dx,
                    dy: dy
                ) else {
                    continue
                }
                scores[(localDY + radius) * diameter + localDX + radius] = score
                if score < bestScore {
                    bestScore = score
                    bestLocalDX = localDX
                    bestLocalDY = localDY
                }
            }
        }

        guard bestScore.isFinite, bestScore < 0.52 else { return nil }
        for localDY in -radius...radius {
            for localDX in -radius...radius {
                if abs(localDX - bestLocalDX) <= 1 && abs(localDY - bestLocalDY) <= 1 { continue }
                let score = scores[(localDY + radius) * diameter + localDX + radius]
                if score < secondScore {
                    secondScore = score
                }
            }
        }
        var subpixelX: CGFloat = 0
        var subpixelY: CGFloat = 0
        if abs(bestLocalDX) < radius {
            let row = (bestLocalDY + radius) * diameter
            subpixelX = parabolicMinimum(
                left: scores[row + bestLocalDX - 1 + radius],
                center: bestScore,
                right: scores[row + bestLocalDX + 1 + radius]
            )
        }
        if abs(bestLocalDY) < radius {
            let column = bestLocalDX + radius
            subpixelY = parabolicMinimum(
                left: scores[(bestLocalDY - 1 + radius) * diameter + column],
                center: bestScore,
                right: scores[(bestLocalDY + 1 + radius) * diameter + column]
            )
        }

        let quality = clamp(CGFloat((0.52 - bestScore) / 0.42), min: 0, max: 1)
        let uniqueness: CGFloat
        if secondScore.isFinite {
            uniqueness = clamp(CGFloat((secondScore - bestScore) / 0.12), min: 0, max: 1)
        } else {
            uniqueness = 0
        }
        let confidence = quality * 0.78 + uniqueness * 0.22
        guard confidence >= 0.22 else { return nil }
        return PatchVector(
            dx: CGFloat(shiftCenterX + bestLocalDX) + subpixelX,
            dy: CGFloat(shiftCenterY + bestLocalDY) + subpixelY,
            confidence: confidence
        )
    }

    private func normalizedPatchScore(
        reference: AnalysisFrame,
        current: AnalysisFrame,
        centerX: Int,
        centerY: Int,
        dx: Int,
        dy: Int
    ) -> Float? {
        var sumReference: Float = 0
        var sumCurrent: Float = 0
        var sumReferenceSquared: Float = 0
        var sumCurrentSquared: Float = 0
        var sumProduct: Float = 0
        var count: Float = 0

        for patchY in -patchRadius...patchRadius {
            let referenceY = centerY + patchY
            let currentY = referenceY + dy
            guard currentY >= 0, currentY < gridSize else { return nil }
            for patchX in -patchRadius...patchRadius {
                let referenceX = centerX + patchX
                let currentX = referenceX + dx
                guard currentX >= 0, currentX < gridSize else { return nil }
                let referenceIndex = referenceY * gridSize + referenceX
                let currentIndex = currentY * gridSize + currentX
                guard reference.roiMask[referenceIndex], current.roiMask[currentIndex] else {
                    continue
                }
                let referenceValue = reference.luma[referenceIndex]
                let currentValue = current.luma[currentIndex]
                sumReference += referenceValue
                sumCurrent += currentValue
                sumReferenceSquared += referenceValue * referenceValue
                sumCurrentSquared += currentValue * currentValue
                sumProduct += referenceValue * currentValue
                count += 1
            }
        }

        guard count >= 32 else { return nil }
        let covariance = sumProduct - sumReference * sumCurrent / count
        let referenceVariance = max(sumReferenceSquared - sumReference * sumReference / count, 0)
        let currentVariance = max(sumCurrentSquared - sumCurrent * sumCurrent / count, 0)
        let denominator = sqrt(referenceVariance * currentVariance)
        // patch 覆盖的源像素范围随格距收窄，灰度方差同比下降，门槛按 sqrt 缩放。
        guard denominator > 10 else { return nil }
        let correlation = max(-1, min(covariance / denominator, 1))
        return 1 - correlation
    }

    private func parabolicMinimum(left: Float, center: Float, right: Float) -> CGFloat {
        guard left.isFinite, right.isFinite else { return 0 }
        let denominator = left - 2 * center + right
        guard abs(denominator) > 0.0001 else { return 0 }
        return clamp(CGFloat(0.5 * (left - right) / denominator), min: -0.5, max: 0.5)
    }

    private func makeLumaGrid(from pixelBuffer: CVPixelBuffer) -> AnalysisFrame? {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        if format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
            format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
            guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
                return nil
            }
            return sampledGrid(
                lumaBaseAddress: baseAddress.assumingMemoryBound(to: UInt8.self),
                width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
                height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
                bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            )
        }

        guard format == kCVPixelFormatType_32BGRA,
              let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)
        else {
            return nil
        }
        return sampledBGRAGrid(
            baseAddress: baseAddress.assumingMemoryBound(to: UInt8.self),
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer)
        )
    }

    private func sampledGrid(
        lumaBaseAddress: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> AnalysisFrame {
        let geometry = samplingGeometry(width: width, height: height)
        var luma = Array(repeating: Float(0), count: gridSize * gridSize)
        for y in 0..<gridSize {
            let sourceY = geometry.cropY + (CGFloat(y) + 0.5) * geometry.step - 0.5
            for x in 0..<gridSize {
                let sourceX = geometry.cropX + (CGFloat(x) + 0.5) * geometry.step - 0.5
                luma[y * gridSize + x] = bilinearLuma(
                    baseAddress: lumaBaseAddress,
                    width: width,
                    height: height,
                    bytesPerRow: bytesPerRow,
                    x: sourceX,
                    y: sourceY
                )
            }
        }
        return AnalysisFrame(
            luma: luma,
            roiMask: currentROIMask(for: luma),
            sourceWidth: width,
            sourceHeight: height,
            sourceStep: geometry.step
        )
    }

    private func sampledBGRAGrid(
        baseAddress: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> AnalysisFrame {
        let geometry = samplingGeometry(width: width, height: height)
        var luma = Array(repeating: Float(0), count: gridSize * gridSize)
        for y in 0..<gridSize {
            let sourceY = geometry.cropY + (CGFloat(y) + 0.5) * geometry.step - 0.5
            for x in 0..<gridSize {
                let sourceX = geometry.cropX + (CGFloat(x) + 0.5) * geometry.step - 0.5
                luma[y * gridSize + x] = bilinearBGRALuma(
                    baseAddress: baseAddress,
                    width: width,
                    height: height,
                    bytesPerRow: bytesPerRow,
                    x: sourceX,
                    y: sourceY
                )
            }
        }
        return AnalysisFrame(
            luma: luma,
            roiMask: currentROIMask(for: luma),
            sourceWidth: width,
            sourceHeight: height,
            sourceStep: geometry.step
        )
    }

    private func currentROIMask(for luma: [Float]) -> [Bool] {
        let shouldRefresh = activeROIMask == nil || maskUpdateCounter.isMultiple(of: 15)
        maskUpdateCounter += 1
        guard shouldRefresh else { return activeROIMask ?? roiMask }

        // 自动检测望远镜出瞳亮圈质心与暗角边界，屏蔽静止镜筒黑边及内侧 8% 渐晕环。
        var samples: [Float] = []
        samples.reserveCapacity(1024)
        for index in stride(from: 0, to: luma.count, by: 64) where roiMask[index] {
            samples.append(luma[index])
        }
        guard samples.count >= 16 else {
            activeROIMask = roiMask
            latestVignetteOffset = .zero
            return roiMask
        }
        samples.sort()
        let highLuma = samples[min(samples.count - 1, samples.count * 85 / 100)]
        let lowLuma = samples[samples.count * 10 / 100]
        guard highLuma > 32, lowLuma < highLuma * 0.32 else {
            activeROIMask = roiMask
            latestVignetteOffset = .zero
            return roiMask
        }

        let threshold = max(Float(18), highLuma * 0.26)
        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        var brightCount: CGFloat = 0
        for y in stride(from: 4, to: gridSize - 4, by: 4) {
            for x in stride(from: 4, to: gridSize - 4, by: 4) {
                let index = y * gridSize + x
                if roiMask[index], luma[index] >= threshold {
                    sumX += CGFloat(x)
                    sumY += CGFloat(y)
                    brightCount += 1
                }
            }
        }
        let totalSampled = CGFloat((gridSize / 4) * (gridSize / 4))
        guard brightCount >= totalSampled * 0.15, brightCount < totalSampled * 0.72 else {
            activeROIMask = roiMask
            latestVignetteOffset = .zero
            return roiMask
        }
        let centerX = sumX / brightCount
        let centerY = sumY / brightCount
        let gridCenter = CGFloat(gridSize - 1) * 0.5
        latestVignetteOffset = CGPoint(
            x: (centerX - gridCenter) / max(gridCenter, 1),
            y: (centerY - gridCenter) / max(gridCenter, 1)
        )
        let estimatedRadius = sqrt(brightCount * 16 / .pi) * 0.90
        let safeRadiusSquared = max(estimatedRadius * estimatedRadius, 36 * 36)
        var refined = Array(repeating: false, count: gridSize * gridSize)
        for y in 2..<(gridSize - 2) {
            for x in 2..<(gridSize - 2) {
                let index = y * gridSize + x
                guard roiMask[index], luma[index] >= threshold else { continue }
                let dx = CGFloat(x) - centerX
                let dy = CGFloat(y) - centerY
                if dx * dx + dy * dy <= safeRadiusSquared {
                    refined[index] = true
                }
            }
        }
        activeROIMask = refined
        return refined
    }

    private func samplingGeometry(width: Int, height: Int) -> (
        cropX: CGFloat,
        cropY: CGFloat,
        step: CGFloat
    ) {
        let cropSide = CGFloat(min(width, height)) * 0.55
        return (
            (CGFloat(width) - cropSide) * 0.5,
            (CGFloat(height) - cropSide) * 0.5,
            cropSide / CGFloat(gridSize)
        )
    }

    private func makeROIMask() -> [Bool] {
        let center = (CGFloat(gridSize) - 1) * 0.5
        let radius = CGFloat(gridSize) * 0.43
        let radiusSquared = radius * radius
        var mask = Array(repeating: false, count: gridSize * gridSize)
        for y in 0..<gridSize {
            for x in 0..<gridSize {
                let dx = CGFloat(x) - center
                let dy = CGFloat(y) - center
                mask[y * gridSize + x] = dx * dx + dy * dy <= radiusSquared
            }
        }
        return mask
    }

    private func bilinearLuma(
        baseAddress: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        x: CGFloat,
        y: CGFloat
    ) -> Float {
        let x0 = clamp(Int(floor(x)), min: 0, max: max(width - 1, 0))
        let y0 = clamp(Int(floor(y)), min: 0, max: max(height - 1, 0))
        let x1 = min(x0 + 1, max(width - 1, 0))
        let y1 = min(y0 + 1, max(height - 1, 0))
        let fx = Float(x - CGFloat(x0))
        let fy = Float(y - CGFloat(y0))
        let top = Float(baseAddress[y0 * bytesPerRow + x0]) * (1 - fx) +
            Float(baseAddress[y0 * bytesPerRow + x1]) * fx
        let bottom = Float(baseAddress[y1 * bytesPerRow + x0]) * (1 - fx) +
            Float(baseAddress[y1 * bytesPerRow + x1]) * fx
        return top * (1 - fy) + bottom * fy
    }

    private func bilinearBGRALuma(
        baseAddress: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        x: CGFloat,
        y: CGFloat
    ) -> Float {
        let x0 = clamp(Int(floor(x)), min: 0, max: max(width - 1, 0))
        let y0 = clamp(Int(floor(y)), min: 0, max: max(height - 1, 0))
        let x1 = min(x0 + 1, max(width - 1, 0))
        let y1 = min(y0 + 1, max(height - 1, 0))
        let fx = Float(x - CGFloat(x0))
        let fy = Float(y - CGFloat(y0))
        let top = bgraLuma(baseAddress, bytesPerRow: bytesPerRow, x: x0, y: y0) * (1 - fx) +
            bgraLuma(baseAddress, bytesPerRow: bytesPerRow, x: x1, y: y0) * fx
        let bottom = bgraLuma(baseAddress, bytesPerRow: bytesPerRow, x: x0, y: y1) * (1 - fx) +
            bgraLuma(baseAddress, bytesPerRow: bytesPerRow, x: x1, y: y1) * fx
        return top * (1 - fy) + bottom * fy
    }

    private func bgraLuma(
        _ baseAddress: UnsafePointer<UInt8>,
        bytesPerRow: Int,
        x: Int,
        y: Int
    ) -> Float {
        let offset = y * bytesPerRow + x * 4
        let blue = Float(baseAddress[offset])
        let green = Float(baseAddress[offset + 1])
        let red = Float(baseAddress[offset + 2])
        return red * 0.299 + green * 0.587 + blue * 0.114
    }

    private func textureScore(_ frame: AnalysisFrame) -> CGFloat {
        var total: Float = 0
        var count: Float = 0
        for y in 1..<(gridSize - 1) {
            for x in 1..<(gridSize - 1) {
                let index = y * gridSize + x
                guard frame.roiMask[index], frame.roiMask[index + 1], frame.roiMask[index + gridSize] else {
                    continue
                }
                total += abs(frame.luma[index] - frame.luma[index + 1])
                total += abs(frame.luma[index] - frame.luma[index + gridSize])
                count += 2
            }
        }
        return CGFloat(total / max(count, 1))
    }

    private func patchTexture(_ frame: AnalysisFrame, centerX: Int, centerY: Int) -> CGFloat {
        var total: Float = 0
        var count: Float = 0
        for y in -patchRadius..<patchRadius {
            for x in -patchRadius..<patchRadius {
                let index = (centerY + y) * gridSize + centerX + x
                guard frame.roiMask[index], frame.roiMask[index + 1], frame.roiMask[index + gridSize] else {
                    continue
                }
                total += abs(frame.luma[index] - frame.luma[index + 1])
                total += abs(frame.luma[index] - frame.luma[index + gridSize])
                count += 2
            }
        }
        return CGFloat(total / max(count, 1))
    }

    private func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) * 0.5
        }
        return sorted[middle]
    }

    private func clamp<T: Comparable>(_ value: T, min minimum: T, max maximum: T) -> T {
        Swift.min(Swift.max(value, minimum), maximum)
    }
}

private final class VisualEstimatorShadow {
    private let queue = DispatchQueue(label: "com.puroo.scope.estimatorComparison", qos: .utility)
    private let available = DispatchSemaphore(value: 1)
    private let estimator = PhaseCorrelationEstimator()
    private var counter = 0

    func submit(reference: [Float], current: [Float], gridSize: Int,
                previousTime: Double, time: Double, sourceStep: CGFloat,
                width: Int, height: Int, visual: VisualMotionObservation?) {
        guard StabilizationTraceRecorder.shared.hasActiveSession else { return }
        counter += 1
        guard counter.isMultiple(of: 6), available.wait(timeout: .now()) == .success else { return }
        // Arrays are immutable copies of the sampled grid; no capture-pool buffers escape.
        queue.async {
            let start = CACurrentMediaTime()
            let phase = self.estimator.estimate(reference: reference, current: current, gridSize: gridSize)
            let values: [String: Any] = [
                "t": time, "previous_t": previousTime, "grid_size": gridSize,
                "source_step": sourceStep, "frame_w": width, "frame_h": height,
                "ncc_available": visual != nil,
                "ncc_dx": visual?.deltaX ?? 0, "ncc_dy": visual?.deltaY ?? 0,
                "ncc_confidence": visual?.confidence ?? 0,
                "phase_available": phase != nil, "phase_accepted": phase?.accepted ?? false,
                "phase_dx": (phase?.dx ?? 0) * Double(sourceStep) / Double(width),
                "phase_dy": (phase?.dy ?? 0) * Double(sourceStep) / Double(height),
                "phase_psr": phase?.peakToSidelobe ?? 0, "phase_peak_ratio": phase?.peakRatio ?? 0,
                "phase_ms": (CACurrentMediaTime() - start) * 1000,
                "production_estimator": "ncc", "shadow_only": true
            ]
            StabilizationTraceRecorder.shared.recordComparison(values, reference: reference, current: current) {
                self.available.signal()
            }
        }
    }
}

private struct GyroMotionCandidate {
    var automaticOffset: TimeInterval
    var deltaX: CGFloat
    var deltaY: CGFloat
    /// 绕光轴的相对转角，单位弧度。与放大倍率无关。
    var deltaRoll: CGFloat
    /// 利用帧曝光后已到达的未来 IMU 样本（Lookahead）预测的下一帧归一化位移增量。
    var lookaheadDeltaX: CGFloat = 0
    var lookaheadDeltaY: CGFloat = 0
    var hasLookahead: Bool = false
    /// 帧内上下边缘角速度差异引起的卷帘快门水平倾斜与垂直果冻伸缩（不含望远镜倍率）。
    var rollingShearX: CGFloat = 0
    var rollingStretchY: CGFloat = 0
}

private struct UnitQuaternion {
    var x: Double
    var y: Double
    var z: Double
    var w: Double

    var normalized: UnitQuaternion {
        let length = sqrt(x * x + y * y + z * z + w * w)
        guard length > 0.000001 else { return UnitQuaternion(x: 0, y: 0, z: 0, w: 1) }
        return UnitQuaternion(x: x / length, y: y / length, z: z / length, w: w / length)
    }

    var inverse: UnitQuaternion {
        UnitQuaternion(x: -x, y: -y, z: -z, w: w).normalized
    }

    func multiplied(by rhs: UnitQuaternion) -> UnitQuaternion {
        UnitQuaternion(
            x: w * rhs.x + x * rhs.w + y * rhs.z - z * rhs.y,
            y: w * rhs.y - x * rhs.z + y * rhs.w + z * rhs.x,
            z: w * rhs.z + x * rhs.y - y * rhs.x + z * rhs.w,
            w: w * rhs.w - x * rhs.x - y * rhs.y - z * rhs.z
        ).normalized
    }

    func slerp(to rhs: UnitQuaternion, amount: Double) -> UnitQuaternion {
        var target = rhs.normalized
        let source = normalized
        var dot = source.x * target.x + source.y * target.y + source.z * target.z + source.w * target.w
        if dot < 0 {
            target = UnitQuaternion(x: -target.x, y: -target.y, z: -target.z, w: -target.w)
            dot = -dot
        }
        if dot > 0.9995 {
            return UnitQuaternion(
                x: source.x + (target.x - source.x) * amount,
                y: source.y + (target.y - source.y) * amount,
                z: source.z + (target.z - source.z) * amount,
                w: source.w + (target.w - source.w) * amount
            ).normalized
        }
        let theta = acos(max(-1, min(dot, 1)))
        let sine = sin(theta)
        guard abs(sine) > 0.000001 else { return source }
        let left = sin((1 - amount) * theta) / sine
        let right = sin(amount * theta) / sine
        return UnitQuaternion(
            x: source.x * left + target.x * right,
            y: source.y * left + target.y * right,
            z: source.z * left + target.z * right,
            w: source.w * left + target.w * right
        ).normalized
    }

    var rotationVector: (x: Double, y: Double, z: Double) {
        let quaternion = normalized
        let clampedW = max(-1, min(quaternion.w, 1))
        var angle = 2 * acos(clampedW)
        if angle > .pi {
            angle -= .pi * 2
        }
        let sine = sqrt(max(1 - clampedW * clampedW, 0))
        guard sine > 0.00001 else {
            return (quaternion.x * 2, quaternion.y * 2, quaternion.z * 2)
        }
        return (
            quaternion.x / sine * angle,
            quaternion.y / sine * angle,
            quaternion.z / sine * angle
        )
    }
}

private final class QuaternionMotionEstimator {
    private let automaticOffsets: [TimeInterval] = [
        -0.006, -0.003, 0, 0.002, 0.004, 0.005, 0.006, 0.008
    ]
    private var previousFrameTime: TimeInterval?

    func reset() {
        previousFrameTime = nil
    }

    func candidates(
        samples: [StabilitySample],
        frameTime: TimeInterval,
        videoRotationAngle: CGFloat,
        tuning: StabilizationTuning,
        focalLengthPixelsX: CGFloat,
        focalLengthPixelsY: CGFloat,
        frameWidth: CGFloat,
        frameHeight: CGFloat
    ) -> [GyroMotionCandidate] {
        defer { previousFrameTime = frameTime }
        guard let previousFrameTime, !samples.isEmpty else { return [] }
        let frameSpan = max(min(frameTime - previousFrameTime, 1.0 / 20.0), 1.0 / 120.0)
        let halfReadout = min(frameSpan * 0.36, 0.0065)
        let normalizedAngle = ((Int(videoRotationAngle.rounded()) % 360) + 360) % 360
        let latestSampleTime = samples.last?.timestamp ?? frameTime
        var output: [GyroMotionCandidate] = []
        output.reserveCapacity(automaticOffsets.count)
        for automaticOffset in automaticOffsets {
            let totalOffset = tuning.motionTimeOffset + automaticOffset
            let tPrev = previousFrameTime + totalOffset
            let tCurr = frameTime + totalOffset
            guard let previous = interpolatedQuaternion(
                at: tPrev,
                samples: samples
            ), let current = interpolatedQuaternion(
                at: tCurr,
                samples: samples
            ) else {
                continue
            }
            let primary = projectedMotion(
                from: previous,
                to: current,
                normalizedAngle: normalizedAngle,
                focalLengthPixelsX: focalLengthPixelsX,
                focalLengthPixelsY: focalLengthPixelsY,
                frameWidth: frameWidth,
                frameHeight: frameHeight
            )

            // 利用帧曝光后已到达缓冲区的未来 4~14 ms 真实 IMU 样本实现零相位前瞻
            var lookaheadDeltaX: CGFloat = 0
            var lookaheadDeltaY: CGFloat = 0
            var hasLookahead = false
            let availableFuture = min(latestSampleTime - tCurr, frameSpan * 0.75)
            if availableFuture >= 0.0035,
               let future = interpolatedQuaternion(at: tCurr + availableFuture, samples: samples) {
                let futureMotion = projectedMotion(
                    from: current,
                    to: future,
                    normalizedAngle: normalizedAngle,
                    focalLengthPixelsX: focalLengthPixelsX,
                    focalLengthPixelsY: focalLengthPixelsY,
                    frameWidth: frameWidth,
                    frameHeight: frameHeight
                )
                let scale = CGFloat(frameSpan / max(availableFuture, 0.0035))
                lookaheadDeltaX = clamp(futureMotion.deltaX * scale, min: -0.06, max: 0.06)
                lookaheadDeltaY = clamp(futureMotion.deltaY * scale, min: -0.06, max: 0.06)
                hasLookahead = true
            }

            // 计算帧内上下边缘曝光时刻差引起的卷帘快门水平倾斜与垂直伸缩
            var rollingShearX: CGFloat = 0
            var rollingStretchY: CGFloat = 0
            if let prevTop = interpolatedQuaternion(at: tPrev - halfReadout, samples: samples),
               let currTop = interpolatedQuaternion(at: tCurr - halfReadout, samples: samples),
               let prevBottom = interpolatedQuaternion(at: tPrev + halfReadout, samples: samples),
               let currBottom = interpolatedQuaternion(at: min(tCurr + halfReadout, latestSampleTime), samples: samples) {
                let topMotion = projectedMotion(
                    from: prevTop,
                    to: currTop,
                    normalizedAngle: normalizedAngle,
                    focalLengthPixelsX: focalLengthPixelsX,
                    focalLengthPixelsY: focalLengthPixelsY,
                    frameWidth: frameWidth,
                    frameHeight: frameHeight
                )
                let bottomMotion = projectedMotion(
                    from: prevBottom,
                    to: currBottom,
                    normalizedAngle: normalizedAngle,
                    focalLengthPixelsX: focalLengthPixelsX,
                    focalLengthPixelsY: focalLengthPixelsY,
                    frameWidth: frameWidth,
                    frameHeight: frameHeight
                )
                rollingShearX = clamp(bottomMotion.deltaX - topMotion.deltaX, min: -0.015, max: 0.015)
                rollingStretchY = clamp(bottomMotion.deltaY - topMotion.deltaY, min: -0.015, max: 0.015)
            }

            output.append(
                GyroMotionCandidate(
                    automaticOffset: automaticOffset,
                    deltaX: primary.deltaX,
                    deltaY: primary.deltaY,
                    deltaRoll: primary.deltaRoll,
                    lookaheadDeltaX: lookaheadDeltaX,
                    lookaheadDeltaY: lookaheadDeltaY,
                    hasLookahead: hasLookahead,
                    rollingShearX: rollingShearX,
                    rollingStretchY: rollingStretchY
                )
            )
        }
        return output
    }

    private func projectedMotion(
        from previous: UnitQuaternion,
        to current: UnitQuaternion,
        normalizedAngle: Int,
        focalLengthPixelsX: CGFloat,
        focalLengthPixelsY: CGFloat,
        frameWidth: CGFloat,
        frameHeight: CGFloat
    ) -> (deltaX: CGFloat, deltaY: CGFloat, deltaRoll: CGFloat) {
        let relative = previous.inverse.multiplied(by: current)
        let rotation = relative.rotationVector
        let horizontalRotation: Double
        let verticalRotation: Double
        switch normalizedAngle {
        case 0:
            horizontalRotation = rotation.x
            verticalRotation = -rotation.y
        case 180:
            horizontalRotation = -rotation.x
            verticalRotation = rotation.y
        case 270:
            horizontalRotation = -rotation.y
            verticalRotation = -rotation.x
        default:
            horizontalRotation = rotation.y
            verticalRotation = rotation.x
        }
        let deltaX = clamp(
            CGFloat(horizontalRotation) * focalLengthPixelsX / max(frameWidth, 1),
            min: -0.06,
            max: 0.06
        )
        let deltaY = clamp(
            CGFloat(verticalRotation) * focalLengthPixelsY / max(frameHeight, 1),
            min: -0.06,
            max: 0.06
        )
        let deltaRoll = clamp(
            CGFloat(rotation.z),
            min: -0.05,
            max: 0.05
        )
        return (deltaX, deltaY, deltaRoll)
    }

    private func interpolatedQuaternion(
        at timestamp: TimeInterval,
        samples: [StabilitySample]
    ) -> UnitQuaternion? {
        var previous: StabilitySample?
        var next: StabilitySample?
        for sample in samples {
            if sample.timestamp <= timestamp {
                previous = sample
            }
            if sample.timestamp >= timestamp {
                next = sample
                break
            }
        }

        if let previous, let next {
            let span = next.timestamp - previous.timestamp
            let amount = span > 0 ? (timestamp - previous.timestamp) / span : 0
            return quaternion(from: previous).slerp(
                to: quaternion(from: next),
                amount: max(0, min(amount, 1))
            )
        }
        if let nearest = previous ?? next,
           abs(nearest.timestamp - timestamp) <= 1.0 / 100.0 {
            return quaternion(from: nearest)
        }
        return nil
    }

    private func quaternion(from sample: StabilitySample) -> UnitQuaternion {
        UnitQuaternion(
            x: sample.quaternionX,
            y: sample.quaternionY,
            z: sample.quaternionZ,
            w: sample.quaternionW
        ).normalized
    }

    private func clamp<T: Comparable>(_ value: T, min minimum: T, max maximum: T) -> T {
        Swift.min(Swift.max(value, minimum), maximum)
    }
}

private struct FusedMotionDelta {
    var deltaX: CGFloat
    var deltaY: CGFloat
    var lowFrequencyDeltaX: CGFloat
    var lowFrequencyDeltaY: CGFloat
    var highFrequencyDeltaX: CGFloat
    var highFrequencyDeltaY: CGFloat
    var deltaRoll: CGFloat
    var confidence: CGFloat
    var gyroTrust: CGFloat
    var gyroAvailable: Bool
    var predictedGyroDeltaX: CGFloat
    var predictedGyroDeltaY: CGFloat
    var automaticOffset: TimeInterval
    var opticalMagnification: CGFloat
    var referenceMagnification: CGFloat
    var gyroCorrelationX: CGFloat
    var gyroCorrelationY: CGFloat
    var gyroNormalizedError: CGFloat
    var isGyroCalibrationValid: Bool
    var calibrationState: String
    var calibrationAgeSeconds: Double
    var calibrationSamples: Int
    var rollingShearX: CGFloat = 0
    var rollingStretchY: CGFloat = 0
}

private final class ComplementaryMotionFusion {
    private static let referenceTrust: CGFloat = 0
    private static let minimumMagnification = CGFloat(TelescopeMagnificationOption.minimum)
    private static let maximumMagnification = CGFloat(TelescopeMagnificationOption.maximum)

    private struct LagCorrelation {
        var crossX: CGFloat = 0
        var crossY: CGFloat = 0
        var visualEnergyX: CGFloat = 0
        var visualEnergyY: CGFloat = 0
        var gyroEnergyX: CGFloat = 0
        var gyroEnergyY: CGFloat = 0
        var sampleCount: Int = 0
        var weightSum: CGFloat = 0

        var isObservable: Bool {
            weightSum > 0 && (visualEnergyX + visualEnergyY) / weightSum >= 0.000025 * 0.000025
        }

        /// 两轴合并的单参数最小二乘解。
        ///
        /// 陀螺增量已在投影阶段除以各自的画幅尺寸，因此两轴共享同一个未知量
        /// （望远镜倍率），合并回归比分轴各拟合一个增益更稳定。
        var combinedGain: CGFloat {
            let energy = gyroEnergyX + gyroEnergyY
            guard energy > 0 else { return 0 }
            return (crossX + crossY) / energy
        }

        var correlationX: CGFloat {
            normalizedCorrelation(cross: crossX, visual: visualEnergyX, gyro: gyroEnergyX)
        }

        var correlationY: CGFloat {
            normalizedCorrelation(cross: crossY, visual: visualEnergyY, gyro: gyroEnergyY)
        }

        // A quiet axis cannot disprove calibration. Include an axis when either
        // sensor sees meaningful energy, so a disagreement is still rejected.
        var observableAxisCorrelation: CGFloat {
            let visualTotal = visualEnergyX + visualEnergyY
            let gyroTotal = gyroEnergyX + gyroEnergyY
            guard visualTotal > 0, gyroTotal > 0 else { return 0 }
            let observableX = max(visualEnergyX / visualTotal, gyroEnergyX / gyroTotal) >= 0.05
            let observableY = max(visualEnergyY / visualTotal, gyroEnergyY / gyroTotal) >= 0.05
            if observableX && observableY { return min(correlationX, correlationY) }
            return observableX ? correlationX : correlationY
        }

        /// 单参数模型的归一化残差，必须与 combinedGain 同口径。
        ///
        /// 分轴各拟合一个增益会多出一个自由度，能把倍率或轴映射的错误
        /// 吸收进去而残差依然很低，从而放行本该判为失败的标定。
        var normalizedError: CGFloat {
            let visualEnergy = visualEnergyX + visualEnergyY
            let gyroEnergy = gyroEnergyX + gyroEnergyY
            guard visualEnergy > 0, gyroEnergy > 0 else { return 1 }
            let correlation = normalizedCorrelation(
                cross: crossX + crossY, visual: visualEnergy, gyro: gyroEnergy
            )
            return sqrt(max(1 - correlation * correlation, 0))
        }

        private func normalizedCorrelation(cross: CGFloat, visual: CGFloat, gyro: CGFloat) -> CGFloat {
            guard visual > 0, gyro > 0 else { return 0 }
            // Correlation is dimensionless: an absolute energy-product floor
            // incorrectly rejects subpixel motion and larger optical ratios.
            let denominator = sqrt(visual) * sqrt(gyro)
            guard denominator > 0, denominator.isFinite else { return 0 }
            return min(max(cross / denominator, -1), 1)
        }
    }

    private var correlations: [Int: LagCorrelation] = [:]
    private var selectedOffsetKey = 0
    private var estimatedMagnification = CGFloat(StabilizationTuning.defaultOpticalMagnification)
    private var referenceMagnification = CGFloat(StabilizationTuning.defaultOpticalMagnification)
    private var calibrationTrust = ComplementaryMotionFusion.referenceTrust
    private var lastCalibrationSampleCount = 0
    private var lastCalibrationObservation: TimeInterval?
    private var calibrationState = "unverified"
    private var measurementIsValidated = false
    private var visualLowVelocityX: CGFloat = 0
    private var visualLowVelocityY: CGFloat = 0
    private var gyroLowVelocityX: CGFloat = 0
    private var gyroLowVelocityY: CGFloat = 0
    private var lastTimestamp: TimeInterval?

    func reset(keepCalibration: Bool) {
        visualLowVelocityX = 0
        visualLowVelocityY = 0
        gyroLowVelocityX = 0
        gyroLowVelocityY = 0
        lastTimestamp = nil
        if !keepCalibration {
            correlations.removeAll(keepingCapacity: true)
            selectedOffsetKey = 0
            estimatedMagnification = referenceMagnification
            calibrationTrust = Self.referenceTrust
            lastCalibrationSampleCount = 0
            lastCalibrationObservation = nil
            calibrationState = "unverified"
            measurementIsValidated = false
        }
    }

    /// 用户换了另一台望远镜时，之前学到的倍率与相关能量全部作废。
    private func applyReferenceMagnification(_ requested: CGFloat) {
        let clamped = clamp(
            requested,
            min: Self.minimumMagnification,
            max: Self.maximumMagnification
        )
        guard abs(clamped - referenceMagnification) > 0.01 else { return }
        referenceMagnification = clamped
        estimatedMagnification = clamped
        correlations.removeAll(keepingCapacity: true)
        selectedOffsetKey = 0
        calibrationTrust = Self.referenceTrust
        lastCalibrationSampleCount = 0
        lastCalibrationObservation = nil
        calibrationState = "unverified"
        measurementIsValidated = false
    }

    /// 在视觉块匹配开始前，若陀螺倍率已完成可靠标定，输出当前帧预测位移以引导搜索中心。
    func predictedMotionHint(from candidates: [GyroMotionCandidate]) -> (dx: CGFloat, dy: CGFloat)? {
        guard measurementIsValidated, calibrationTrust >= 0.25,
              let selected = selectedCandidate(from: candidates) else {
            return nil
        }
        let dx = clamp(estimatedMagnification * selected.deltaX, min: -0.09, max: 0.09)
        let dy = clamp(estimatedMagnification * selected.deltaY, min: -0.09, max: 0.09)
        guard dx.isFinite, dy.isFinite else { return nil }
        return (dx, dy)
    }

    func update(
        timestamp: TimeInterval,
        visual: VisualMotionObservation?,
        gyroCandidates: [GyroMotionCandidate],
        tuning: StabilizationTuning
    ) -> FusedMotionDelta {
        applyReferenceMagnification(CGFloat(tuning.opticalMagnification))
        let elapsed = lastTimestamp.map { timestamp - $0 } ?? (1.0 / 60.0)
        lastTimestamp = timestamp
        if !elapsed.isFinite || elapsed <= 0 || elapsed > 0.12 {
            reset(keepCalibration: true)
            lastTimestamp = timestamp
        }
        let dt = CGFloat(min(max(elapsed, 1.0 / 120.0), 1.0 / 20.0))

        // A reference magnification is a prior, not a validated measurement.
        // Expire stale evidence before accepting new samples after an interruption.
        if let lastCalibrationObservation, timestamp - lastCalibrationObservation > 2 {
            correlations.removeAll(keepingCapacity: true)
            selectedOffsetKey = 0
            lastCalibrationSampleCount = 0
            calibrationTrust = 0
            measurementIsValidated = false
            calibrationState = "stale"
            self.lastCalibrationObservation = nil
        }

        let digitalZoom = max(tuning.displayZoomFactor / max(tuning.previewCropScale, 1), 1)
        let zoomMotionScale = min(max(sqrt(digitalZoom), 1), 2.2)
        if let visual {
            updateLagCorrelations(
                visual: visual,
                candidates: gyroCandidates,
                motionScale: zoomMotionScale
            )
            selectBestOffsetIfNeeded()
        }
        let maxAllowedMagnification = Self.maximumMagnification * digitalZoom
        let selected = selectedCandidate(from: gyroCandidates)
        let calibration = updateMagnificationFromSelectedCorrelation(
            maxAllowedMagnification: maxAllowedMagnification,
            digitalZoom: digitalZoom
        )
        let gyroTrust: CGFloat = selected == nil || !calibration.isValid ? 0 : calibration.trust

        let visualVelocityX = visual.map { $0.deltaX / dt }
        let visualVelocityY = visual.map { $0.deltaY / dt }
        let predictedGyroX: CGFloat
        let predictedGyroY: CGFloat
        if let selected {
            predictedGyroX = estimatedMagnification * selected.deltaX
            predictedGyroY = estimatedMagnification * selected.deltaY
        } else {
            predictedGyroX = 0
            predictedGyroY = 0
        }
        let gyroVelocityX = predictedGyroX / dt
        let gyroVelocityY = predictedGyroY / dt

        let cutoff = tuning.complementaryCutoffFrequency
        let alpha = CGFloat(1 - exp(-2 * Double.pi * cutoff * Double(dt)))
        if let visualVelocityX, let visualVelocityY {
            visualLowVelocityX += (visualVelocityX - visualLowVelocityX) * alpha
            visualLowVelocityY += (visualVelocityY - visualLowVelocityY) * alpha
        } else if gyroTrust > 0.20 {
            // 视觉短暂缺失时，用已验证的陀螺速度连续维护视觉低通状态，
            // 避免 visualLowVelocity 按 (1 - alpha) 坍塌并在视觉恢复时产生伪高频跳变。
            visualLowVelocityX += (gyroVelocityX - visualLowVelocityX) * alpha
            visualLowVelocityY += (gyroVelocityY - visualLowVelocityY) * alpha
        } else {
            visualLowVelocityX *= 1 - alpha
            visualLowVelocityY *= 1 - alpha
        }
        if selected != nil {
            gyroLowVelocityX += (gyroVelocityX - gyroLowVelocityX) * alpha
            gyroLowVelocityY += (gyroVelocityY - gyroLowVelocityY) * alpha
        } else {
            // Missing motion is not a measured zero. Do not blend stale gyro
            // filter memory into the visual high band on this frame.
            gyroLowVelocityX = 0
            gyroLowVelocityY = 0
        }

        // 利用帧曝光后已到达的未来 IMU 样本（Lookahead）执行前向-后向零相位超前平滑，
        // 消除因果低通在 2–7 Hz 生理手抖频段上的约 35° 相位滞后。
        let zeroPhaseVisualLowX: CGFloat
        let zeroPhaseVisualLowY: CGFloat
        let zeroPhaseGyroLowX: CGFloat
        let zeroPhaseGyroLowY: CGFloat
        if let selected, selected.hasLookahead, gyroTrust > 0.20 {
            let futureGyroVelX = (estimatedMagnification * selected.lookaheadDeltaX) / dt
            let futureGyroVelY = (estimatedMagnification * selected.lookaheadDeltaY) / dt
            let lookaheadBlend = alpha * 0.55 * gyroTrust
            zeroPhaseVisualLowX = visualLowVelocityX + (futureGyroVelX - visualLowVelocityX) * lookaheadBlend
            zeroPhaseVisualLowY = visualLowVelocityY + (futureGyroVelY - visualLowVelocityY) * lookaheadBlend
            zeroPhaseGyroLowX = gyroLowVelocityX + (futureGyroVelX - gyroLowVelocityX) * lookaheadBlend
            zeroPhaseGyroLowY = gyroLowVelocityY + (futureGyroVelY - gyroLowVelocityY) * lookaheadBlend
        } else {
            zeroPhaseVisualLowX = visualLowVelocityX
            zeroPhaseVisualLowY = visualLowVelocityY
            zeroPhaseGyroLowX = gyroLowVelocityX
            zeroPhaseGyroLowY = gyroLowVelocityY
        }

        let visualHighX = (visualVelocityX ?? zeroPhaseVisualLowX) - zeroPhaseVisualLowX
        let visualHighY = (visualVelocityY ?? zeroPhaseVisualLowY) - zeroPhaseVisualLowY
        let gyroHighX = gyroVelocityX - zeroPhaseGyroLowX
        let gyroHighY = gyroVelocityY - zeroPhaseGyroLowY
        let lowVelocityX: CGFloat
        let lowVelocityY: CGFloat
        let highVelocityX: CGFloat
        let highVelocityY: CGFloat
        if visual != nil {
            lowVelocityX = zeroPhaseVisualLowX
            lowVelocityY = zeroPhaseVisualLowY
            highVelocityX = visualHighX * (1 - gyroTrust) + gyroHighX * gyroTrust
            highVelocityY = visualHighY * (1 - gyroTrust) + gyroHighY * gyroTrust
        } else if gyroTrust > 0.20 {
            // 视觉失效期间由已验证的陀螺全量驱动低频与高频通道，不再把缺失的
            // 视觉当作 0 样本按 (1 - gyroTrust) 混入而人为折减约 20% 幅度。
            let fallbackWeight: CGFloat = calibration.isValid ? 1.0 : gyroTrust
            lowVelocityX = zeroPhaseGyroLowX * fallbackWeight
            lowVelocityY = zeroPhaseGyroLowY * fallbackWeight
            highVelocityX = gyroHighX * fallbackWeight
            highVelocityY = gyroHighY * fallbackWeight
        } else {
            lowVelocityX = 0
            lowVelocityY = 0
            highVelocityX = 0
            highVelocityY = 0
        }

        let bandLimit: CGFloat = 0.025 * zoomMotionScale
        let totalLimit: CGFloat = 0.04 * zoomMotionScale
        let lowDeltaX = clamp(lowVelocityX * dt, min: -bandLimit, max: bandLimit)
        let lowDeltaY = clamp(lowVelocityY * dt, min: -bandLimit, max: bandLimit)
        let highDeltaX = clamp(highVelocityX * dt, min: -bandLimit, max: bandLimit)
        let highDeltaY = clamp(highVelocityY * dt, min: -bandLimit, max: bandLimit)
        let fusedRollingShearX = clamp(
            (selected?.rollingShearX ?? 0) * estimatedMagnification * gyroTrust,
            min: -0.025,
            max: 0.025
        )
        let fusedRollingStretchY = clamp(
            (selected?.rollingStretchY ?? 0) * estimatedMagnification * gyroTrust,
            min: -0.025,
            max: 0.025
        )

        return FusedMotionDelta(
            deltaX: clamp(lowDeltaX + highDeltaX, min: -totalLimit, max: totalLimit),
            deltaY: clamp(lowDeltaY + highDeltaY, min: -totalLimit, max: totalLimit),
            lowFrequencyDeltaX: lowDeltaX,
            lowFrequencyDeltaY: lowDeltaY,
            highFrequencyDeltaX: highDeltaX,
            highFrequencyDeltaY: highDeltaY,
            deltaRoll: (selected?.deltaRoll ?? 0) * gyroTrust,
            confidence: visual?.confidence ?? gyroTrust,
            gyroTrust: gyroTrust,
            gyroAvailable: selected != nil,
            predictedGyroDeltaX: predictedGyroX,
            predictedGyroDeltaY: predictedGyroY,
            automaticOffset: TimeInterval(selectedOffsetKey) / 1000,
            opticalMagnification: estimatedMagnification,
            referenceMagnification: referenceMagnification,
            gyroCorrelationX: calibration.correlationX,
            gyroCorrelationY: calibration.correlationY,
            gyroNormalizedError: calibration.normalizedError,
            isGyroCalibrationValid: selected != nil && calibration.isValid,
            calibrationState: selected == nil ? "missing_imu" : calibrationState,
            calibrationAgeSeconds: lastCalibrationObservation.map { max(0, timestamp - $0) } ?? -1,
            calibrationSamples: correlations[selectedOffsetKey]?.sampleCount ?? 0,
            rollingShearX: fusedRollingShearX,
            rollingStretchY: fusedRollingStretchY
        )
    }

    private func updateLagCorrelations(
        visual: VisualMotionObservation,
        candidates: [GyroMotionCandidate],
        motionScale: CGFloat = 1
    ) {
        guard visual.confidence >= 0.55, visual.vectorCount >= 6 else { return }
        let maxMotion: CGFloat = 0.012 * max(motionScale, 1)
        let motionMagnitude = hypot(visual.deltaX, visual.deltaY)
        guard motionMagnitude.isFinite, motionMagnitude <= maxMotion else { return }
        let decay: CGFloat = 0.990
        let weight = visual.confidence * visual.confidence
        let visualX = clamp(visual.deltaX, min: -maxMotion, max: maxMotion)
        let visualY = clamp(visual.deltaY, min: -maxMotion, max: maxMotion)
        for candidate in candidates {
            guard candidate.deltaX.isFinite, candidate.deltaY.isFinite else { continue }
            let key = Int((candidate.automaticOffset * 1000).rounded())
            var correlation = correlations[key] ?? LagCorrelation()
            let gyroX = clamp(candidate.deltaX, min: -maxMotion, max: maxMotion)
            let gyroY = clamp(candidate.deltaY, min: -maxMotion, max: maxMotion)
            correlation.crossX = correlation.crossX * decay + weight * visualX * gyroX
            correlation.crossY = correlation.crossY * decay + weight * visualY * gyroY
            correlation.visualEnergyX = correlation.visualEnergyX * decay + weight * visualX * visualX
            correlation.visualEnergyY = correlation.visualEnergyY * decay + weight * visualY * visualY
            correlation.gyroEnergyX = correlation.gyroEnergyX * decay + weight * gyroX * gyroX
            correlation.gyroEnergyY = correlation.gyroEnergyY * decay + weight * gyroY * gyroY
            correlation.sampleCount += 1
            correlation.weightSum = correlation.weightSum * decay + weight
            correlations[key] = correlation
            lastCalibrationObservation = visual.timestamp
        }
    }

    private func selectBestOffsetIfNeeded() {
        guard correlations.count > 1 else {
            if let onlyKey = correlations.keys.first, correlations[selectedOffsetKey] == nil {
                selectedOffsetKey = onlyKey
            }
            return
        }
        var bestKey: Int?
        var bestError = CGFloat.greatestFiniteMagnitude
        for (key, correlation) in correlations {
            guard correlation.sampleCount >= 64,
                  correlation.isObservable,
                  correlation.observableAxisCorrelation >= 0.78,
                  correlation.normalizedError <= 0.55 else {
                continue
            }
            if correlation.normalizedError < bestError ||
                (abs(correlation.normalizedError - bestError) < 0.0001 && abs(key) < abs(bestKey ?? Int.max)) {
                bestError = correlation.normalizedError
                bestKey = key
            }
        }
        guard let bestKey, bestKey != selectedOffsetKey else { return }
        let current = correlations[selectedOffsetKey]
        let currentIsUsable = current.map {
            $0.sampleCount >= 64 && $0.isObservable && $0.observableAxisCorrelation >= 0.78
        } ?? false
        if !currentIsUsable || bestError + 0.005 < (current?.normalizedError ?? 1) {
            selectedOffsetKey = bestKey
            lastCalibrationSampleCount = 0
        }
    }

    private func selectedCandidate(from candidates: [GyroMotionCandidate]) -> GyroMotionCandidate? {
        candidates.min {
            abs(Int(($0.automaticOffset * 1000).rounded()) - selectedOffsetKey) <
                abs(Int(($1.automaticOffset * 1000).rounded()) - selectedOffsetKey)
        }
    }

    private func updateMagnificationFromSelectedCorrelation(
        maxAllowedMagnification: CGFloat,
        digitalZoom: CGFloat = 1
    ) -> (
        trust: CGFloat,
        correlationX: CGFloat,
        correlationY: CGFloat,
        normalizedError: CGFloat,
        isValid: Bool
    ) {
        guard let correlation = correlations[selectedOffsetKey] else {
            return (0, 0, 0, 1, false)
        }
        let targetMagnification = correlation.combinedGain
        guard correlation.sampleCount >= 64, correlation.isObservable else {
            calibrationState = correlation.isObservable ? "learning" : "low_excitation"
            measurementIsValidated = false
            calibrationTrust = 0
            return (
                0,
                correlation.correlationX,
                correlation.correlationY,
                correlation.normalizedError,
                false
            )
        }
        guard correlation.sampleCount > lastCalibrationSampleCount else {
            return (
                calibrationTrust,
                correlation.correlationX,
                correlation.correlationY,
                correlation.normalizedError,
                measurementIsValidated && calibrationTrust >= 0.20
            )
        }
        lastCalibrationSampleCount = correlation.sampleCount

        let axisCorrelation = correlation.observableAxisCorrelation
        // 可信度只看残差与相关性。不再检查倍率是否接近某个出厂参考值——
        // 那会让任何非标定倍率的望远镜被误判为标定失败并静默退回纯视觉稳像。
        // A regression at exactly 30x can round a few ulps above the bound.
        let gainTolerance: CGFloat = 0.000000001
        let magnificationIsFinite = targetMagnification.isFinite &&
            targetMagnification >= Self.minimumMagnification * 0.5 - gainTolerance &&
            targetMagnification <= maxAllowedMagnification + gainTolerance
        let measurementIsReliable = magnificationIsFinite &&
            axisCorrelation >= 0.78 &&
            correlation.normalizedError <= 0.55
        let wasValidated = measurementIsValidated
        measurementIsValidated = measurementIsReliable
        calibrationState = measurementIsReliable ? "validated" : "rejected"
        let zoomStepScale = max(1, digitalZoom * 0.65)
        let highZoomTrustBonus = clamp((digitalZoom - 1.5) * 0.018, min: 0, max: 0.05)

        if measurementIsReliable {
            let relativeMismatch = abs(targetMagnification - estimatedMagnification) / max(abs(targetMagnification), 0.5)
            let highConfidence = axisCorrelation >= 0.88 && correlation.normalizedError <= 0.35
            let gainRate: CGFloat = (!wasValidated || (relativeMismatch > 0.15 && highConfidence)) ? 0.18 : 0.035
            let baseMaxStep: CGFloat = (!wasValidated || (relativeMismatch > 0.15 && highConfidence)) ? 0.60 : 0.08
            let maxStep = baseMaxStep * zoomStepScale
            estimatedMagnification += clamp(
                (targetMagnification - estimatedMagnification) * gainRate,
                min: -maxStep,
                max: maxStep
            )
            estimatedMagnification = clamp(
                estimatedMagnification,
                min: Self.minimumMagnification,
                max: maxAllowedMagnification
            )
            measurementIsValidated = abs(estimatedMagnification - targetMagnification) / max(abs(targetMagnification), 0.5) <= 0.15
            calibrationState = measurementIsValidated ? "validated" : "gain_converging"
            let correlationQuality = clamp((axisCorrelation - 0.72) / 0.23, min: 0, max: 1)
            let residualQuality = clamp(
                (0.58 - correlation.normalizedError) / 0.34,
                min: 0,
                max: 1
            )
            let targetTrust: CGFloat = measurementIsValidated
                ? 0.70 + (0.15 + highZoomTrustBonus) * correlationQuality * residualQuality
                : 0
            calibrationTrust += (targetTrust - calibrationTrust) * 0.04
        } else if axisCorrelation < 0.25 || correlation.normalizedError > 0.90 {
            calibrationTrust += (0 - calibrationTrust) * 0.08
        } else {
            calibrationTrust += (0.35 - calibrationTrust) * 0.01
        }
        calibrationTrust = clamp(calibrationTrust, min: 0, max: 0.85 + highZoomTrustBonus)
        return (
            calibrationTrust,
            correlation.correlationX,
            correlation.correlationY,
            correlation.normalizedError,
            measurementIsValidated && calibrationTrust >= 0.20
        )
    }

    private func clamp<T: Comparable>(_ value: T, min minimum: T, max maximum: T) -> T {
        Swift.min(Swift.max(value, minimum), maximum)
    }
}

private struct VirtualCameraCropResult {
    var correctionX: CGFloat
    var correctionY: CGFloat
    var correctionRoll: CGFloat
    var isIntentionalPan: Bool
    var cropUsage: CGFloat
    var boundaryPressure: CGFloat
    var requestedLowX: CGFloat = 0
    var requestedLowY: CGFloat = 0
    var requestedHighX: CGFloat = 0
    var requestedHighY: CGFloat = 0
    var appliedLowX: CGFloat = 0
    var appliedLowY: CGFloat = 0
    var appliedHighX: CGFloat = 0
    var appliedHighY: CGFloat = 0
    var preUsage: CGFloat = 0
    var correctionShearX: CGFloat = 0
    var correctionStretchY: CGFloat = 0
}

private struct CropTranslationAllocation {
    let low: CGFloat
    let high: CGFloat
    var total: CGFloat { low + high }

    static func resolve(low: CGFloat, high: CGFloat, limit: CGFloat) -> Self {
        guard low.isFinite, high.isFinite, limit.isFinite, limit > 0 else {
            return Self(low: 0, high: 0)
        }
        let boundedHigh = min(max(high, -limit), limit)
        let lowRoom = max(0, limit - abs(boundedHigh))
        return Self(low: min(max(low, -lowRoom), lowRoom), high: boundedHigh)
    }
}

private final class VirtualCameraTrajectoryController {
    private var lowPathX: CGFloat = 0
    private var lowPathY: CGFloat = 0
    private var highOffsetX: CGFloat = 0
    private var highOffsetY: CGFloat = 0
    private var desiredX: CGFloat = 0
    private var desiredY: CGFloat = 0
    private var rollPath: CGFloat = 0
    private var desiredRoll: CGFloat = 0
    private var rollingShearOffset: CGFloat = 0
    private var rollingStretchOffset: CGFloat = 0
    private var lastTimestamp: TimeInterval?
    private var recentVelocities: [CGPoint] = []
    private var isPanning = false
    private var panEnterCount = 0
    private var panExitCount = 0
    private var boundaryHoldCount = 0

    func reset() {
        lowPathX = 0
        lowPathY = 0
        highOffsetX = 0
        highOffsetY = 0
        desiredX = 0
        desiredY = 0
        rollPath = 0
        desiredRoll = 0
        rollingShearOffset = 0
        rollingStretchOffset = 0
        lastTimestamp = nil
        recentVelocities.removeAll(keepingCapacity: true)
        isPanning = false
        panEnterCount = 0
        panExitCount = 0
        boundaryHoldCount = 0
    }

    func nudgeDesired(dx: CGFloat, dy: CGFloat) {
        guard dx.isFinite, dy.isFinite else { return }
        desiredX = clamp(desiredX + dx, min: lowPathX - 0.35, max: lowPathX + 0.35)
        desiredY = clamp(desiredY + dy, min: lowPathY - 0.35, max: lowPathY + 0.35)
    }

    func update(
        timestamp: TimeInterval,
        lowFrequencyDeltaX: CGFloat,
        lowFrequencyDeltaY: CGFloat,
        highFrequencyDeltaX: CGFloat,
        highFrequencyDeltaY: CGFloat,
        deltaRoll: CGFloat,
        confidence: CGFloat,
        tuning: StabilizationTuning,
        rollingShearX: CGFloat = 0,
        rollingStretchY: CGFloat = 0
    ) -> VirtualCameraCropResult {
        guard tuning.usesDigitalStabilization else {
            reset()
            return VirtualCameraCropResult(
                correctionX: 0,
                correctionY: 0,
                correctionRoll: 0,
                isIntentionalPan: false,
                cropUsage: 0,
                boundaryPressure: 0
            )
        }

        let elapsed = lastTimestamp.map { timestamp - $0 } ?? (1.0 / 60.0)
        lastTimestamp = timestamp
        guard elapsed.isFinite, elapsed > 0, elapsed < 0.12 else {
            reset()
            lastTimestamp = timestamp
            return VirtualCameraCropResult(
                correctionX: 0,
                correctionY: 0,
                correctionRoll: 0,
                isIntentionalPan: false,
                cropUsage: 0,
                boundaryPressure: 0
            )
        }
        let dt = CGFloat(min(max(elapsed, 1.0 / 120.0), 1.0 / 20.0))
        // 置信度达到常规阈值（0.55）后保持全量低频积分，避免与 lowFrequencyStabilizationAmount 形成双重折扣。
        let lowFrequencyWeight = clamp(0.65 + (confidence / 0.55) * 0.35, min: 0.65, max: 1)
        let measuredLowDeltaX = lowFrequencyDeltaX * lowFrequencyWeight
        let measuredLowDeltaY = lowFrequencyDeltaY * lowFrequencyWeight
        lowPathX += measuredLowDeltaX
        lowPathY += measuredLowDeltaY
        rollPath += deltaRoll

        let highMemory = max(tuning.highFrequencyMemory, 0.06)
        let highLeak = CGFloat(exp(-Double(dt) / highMemory))
        highOffsetX = highOffsetX * highLeak + highFrequencyDeltaX
        highOffsetY = highOffsetY * highLeak + highFrequencyDeltaY
        rollingShearOffset = rollingShearOffset * highLeak + rollingShearX
        rollingStretchOffset = rollingStretchOffset * highLeak + rollingStretchY

        let lowVelocityX = measuredLowDeltaX / dt
        let lowVelocityY = measuredLowDeltaY / dt
        let instantaneousVelocityX = (measuredLowDeltaX + highFrequencyDeltaX) / dt
        let instantaneousVelocityY = (measuredLowDeltaY + highFrequencyDeltaY) / dt
        let panState = updatePanState(
            velocityX: lowVelocityX,
            velocityY: lowVelocityY,
            instantaneousVelocityX: instantaneousVelocityX,
            instantaneousVelocityY: instantaneousVelocityY,
            threshold: tuning.panActivationSpeed
        )
        let hardLimit = max(tuning.maximumCropOffsetFraction, 0.001)
        let lowAmount = tuning.lowFrequencyStabilizationAmount
        let highAmount = tuning.highFrequencyCompensationAmount
        // Boundary pressure and the allocator both use output-viewport units.
        let renderScale = max(tuning.previewCropScale, 1)
        let lowRenderGain = lowAmount * renderScale
        let lowCorrectionX = (desiredX - lowPathX) * lowRenderGain
        let lowCorrectionY = (desiredY - lowPathY) * lowRenderGain
        let preUsage = max(abs(lowCorrectionX), abs(lowCorrectionY)) / hardLimit

        if preUsage >= 0.72 {
            boundaryHoldCount = min(boundaryHoldCount + 1, 24)
        } else {
            boundaryHoldCount = max(boundaryHoldCount - 2, 0)
        }
        let sustainedBoundary = clamp(
            CGFloat(boundaryHoldCount - 5) / 10,
            min: 0,
            max: 1
        )
        let boundaryPressure = smoothstep(
            lower: 0.72,
            upper: 0.96,
            value: preUsage
        ) * sustainedBoundary
        let isActivelyPanning = panState &&
            hypot(instantaneousVelocityX, instantaneousVelocityY) >= tuning.panActivationSpeed * 0.30
        if isActivelyPanning {
            followDesiredPath(deltaTime: dt, followFrequency: tuning.panFollowFrequency)
        } else {
            // Release only incoming outward motion, not a stored pose after the
            // hand stops. A pressured axis must not pull the other axis along.
            for axis in 0..<2 {
                let correction = axis == 0 ? lowCorrectionX : lowCorrectionY
                let delta = axis == 0 ? measuredLowDeltaX : measuredLowDeltaY
                guard correction * delta < 0 else { continue }
                let pressure = smoothstep(lower: 0.72, upper: 0.96,
                    value: abs(correction) / hardLimit) * sustainedBoundary
                let amount = CGFloat(1 - exp(-2 * Double.pi
                    * tuning.boundaryFollowFrequency * Double(pressure) * Double(dt)))
                if axis == 0 { desiredX += delta * amount }
                else { desiredY += delta * amount }
            }
        }

        let requestedLowX = (desiredX - lowPathX) * lowRenderGain
        let requestedLowY = (desiredY - lowPathY) * lowRenderGain
        let requestedHighX = -highOffsetX * highAmount * renderScale
        let requestedHighY = -highOffsetY * highAmount * renderScale
        // Keep the high band linear while there is geometric room. Constrain
        // the slow offset first instead of compressing their combined signal.
        let allocatedX = CropTranslationAllocation.resolve(
            low: requestedLowX, high: requestedHighX, limit: hardLimit)
        let allocatedY = CropTranslationAllocation.resolve(
            low: requestedLowY, high: requestedHighY, limit: hardLimit)
        if lowRenderGain > 0 {
            // Anti-windup: a clamped slow path must not delay a later reversal.
            desiredX += (allocatedX.low - requestedLowX) / lowRenderGain
            desiredY += (allocatedY.low - requestedLowY) / lowRenderGain
        }
        let correctionX = allocatedX.total
        let correctionY = allocatedY.total

        let usage = clamp(max(abs(correctionX), abs(correctionY)) / hardLimit, min: 0, max: 1)

        // 滚转与平移同构：虚拟相机缓慢跟随构图，逐帧抖动被反向抵消。
        // 可用角度取决于平移剩下多少行程，见 maximumRollRadians 的说明。
        desiredRoll += (rollPath - desiredRoll) * CGFloat(
            1 - exp(-2 * Double.pi * tuning.rollFollowFrequency * Double(dt))
        )
        let rollLimit = tuning.maximumRollRadians(cropUsage: usage)
        // 平移的 0.72 是针对裁切几何过补偿的实测修正；旋转以弧度直接作用
        // 于渲染变换，不经过同一套平移几何，不能共用该系数。
        let correctionRoll = rollLimit > 0
            ? softLimit(desiredRoll - rollPath, limit: rollLimit)
            : 0
        let headroomScale = clamp(1 - usage * 0.65, min: 0.25, max: 1)
        let correctionShearX = softLimit(
            -rollingShearOffset * highAmount * headroomScale,
            limit: 0.032 * headroomScale
        )
        let correctionStretchY = softLimit(
            -rollingStretchOffset * highAmount * headroomScale,
            limit: 0.024 * headroomScale
        )
        return VirtualCameraCropResult(
            correctionX: correctionX,
            correctionY: correctionY,
            correctionRoll: correctionRoll,
            isIntentionalPan: panState,
            cropUsage: clamp(usage, min: 0, max: 1),
            boundaryPressure: boundaryPressure,
            requestedLowX: requestedLowX,
            requestedLowY: requestedLowY,
            requestedHighX: requestedHighX,
            requestedHighY: requestedHighY,
            appliedLowX: allocatedX.low,
            appliedLowY: allocatedY.low,
            appliedHighX: allocatedX.high,
            appliedHighY: allocatedY.high,
            preUsage: preUsage,
            correctionShearX: correctionShearX,
            correctionStretchY: correctionStretchY
        )
    }

    private func updatePanState(
        velocityX: CGFloat,
        velocityY: CGFloat,
        instantaneousVelocityX: CGFloat,
        instantaneousVelocityY: CGFloat,
        threshold: CGFloat
    ) -> Bool {
        recentVelocities.append(CGPoint(x: velocityX, y: velocityY))
        if recentVelocities.count > 12 {
            recentVelocities.removeFirst(recentVelocities.count - 12)
        }
        guard recentVelocities.count >= 6 else { return isPanning }

        var directionX: CGFloat = 0
        var directionY: CGFloat = 0
        var speedTotal: CGFloat = 0
        var movingCount: CGFloat = 0
        for velocity in recentVelocities {
            let speed = hypot(velocity.x, velocity.y)
            guard speed > 0.004 else { continue }
            directionX += velocity.x / speed
            directionY += velocity.y / speed
            speedTotal += speed
            movingCount += 1
        }
        let coherence = movingCount >= 4 ? hypot(directionX, directionY) / movingCount : 0
        let meanSpeed = movingCount > 0 ? speedTotal / movingCount : 0
        let instantaneousSpeed = hypot(instantaneousVelocityX, instantaneousVelocityY)

        if isPanning {
            if instantaneousSpeed < threshold * 0.35 ||
                coherence < 0.55 ||
                meanSpeed < threshold * 0.55 {
                panExitCount += 1
            } else {
                panExitCount = 0
            }
            if panExitCount >= 3 {
                isPanning = false
                panExitCount = 0
                panEnterCount = 0
            }
        } else {
            if movingCount >= 5, coherence >= 0.78, meanSpeed >= threshold {
                panEnterCount += 1
            } else {
                panEnterCount = max(0, panEnterCount - 1)
            }
            // 60 fps 下约 150 ms。真实平移会持续得比这久，而手抖的方向
            // 一致性维持不了这么长，原来的 4 帧（66 ms）挡不住。
            if panEnterCount >= 9 {
                isPanning = true
                panEnterCount = 0
                panExitCount = 0
            }
        }
        return isPanning
    }

    private func followDesiredPath(
        deltaTime: CGFloat,
        followFrequency: Double
    ) {
        guard followFrequency > 0.001 else { return }
        let amount = CGFloat(
            1 - exp(-2 * Double.pi * followFrequency * Double(deltaTime))
        )
        desiredX += (lowPathX - desiredX) * amount
        desiredY += (lowPathY - desiredY) * amount
    }

    private func smoothstep(lower: CGFloat, upper: CGFloat, value: CGFloat) -> CGFloat {
        let amount = clamp((value - lower) / max(upper - lower, 0.0001), min: 0, max: 1)
        return amount * amount * (3 - 2 * amount)
    }

    private func softLimit(_ value: CGFloat, limit: CGFloat) -> CGFloat {
        let knee = limit * 0.72
        let magnitude = abs(value)
        guard magnitude > knee else { return value }
        let room = max(limit - knee, 0.0001)
        let excess = magnitude - knee
        let softenedMagnitude = knee + room * CGFloat(1 - exp(-Double(excess / room)))
        let sign: CGFloat = value < 0 ? -1 : 1
        return sign * min(softenedMagnitude, limit * 0.995)
    }

    private func clamp<T: Comparable>(_ value: T, min minimum: T, max maximum: T) -> T {
        Swift.min(Swift.max(value, minimum), maximum)
    }
}
