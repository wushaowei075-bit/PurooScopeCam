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
}

struct StabilizationDebugSnapshot {
    var strength: Double
    var cropScale: CGFloat
    var visualDeltaX: CGFloat
    var visualDeltaY: CGFloat
    var visualConfidence: CGFloat
    var visualVectorCount: Int
    var visualTexture: CGFloat
    var fusedDeltaX: CGFloat
    var fusedDeltaY: CGFloat
    var correctionX: CGFloat
    var correctionY: CGFloat
    var gyroTrust: CGFloat
    var automaticTimeOffsetMilliseconds: Double
    var calibrationXX: CGFloat
    var calibrationXY: CGFloat
    var calibrationYX: CGFloat
    var calibrationYY: CGFloat
    var isIntentionalPan: Bool
    var cropUsage: CGFloat
    var analysisMilliseconds: Double
    var droppedAnalysisFrames: Int
    var motionSampleCount: Int

    func overlayText(systemModeName: String) -> String {
        """
        防抖调试  系统:\(systemModeName)  单链路
        强度:\(format(strength * 100, digits: 0))%  裁切:\(format(Double(cropScale), digits: 2))x  状态:\(isIntentionalPan ? "平移" : "稳像")
        视觉 X:\(format(Double(visualDeltaX), digits: 5)) Y:\(format(Double(visualDeltaY), digits: 5)) C:\(format(Double(visualConfidence), digits: 2)) V:\(visualVectorCount)
        融合 X:\(format(Double(fusedDeltaX), digits: 5)) Y:\(format(Double(fusedDeltaY), digits: 5))  陀螺信任:\(format(Double(gyroTrust), digits: 2))
        裁切 X:\(format(Double(correctionX), digits: 4)) Y:\(format(Double(correctionY), digits: 4)) 使用:\(format(Double(cropUsage * 100), digits: 0))%
        自动同步:\(format(automaticTimeOffsetMilliseconds, digits: 0))ms  矩阵:\(format(Double(calibrationXX), digits: 2)),\(format(Double(calibrationXY), digits: 2)),\(format(Double(calibrationYX), digits: 2)),\(format(Double(calibrationYY), digits: 2))
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
    private var fileHandle: FileHandle?
    private var writeBuffer = Data()
    private var isActive = false

    private init() {}

    func startSession(metadata: [String: Any]) {
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
                self.isActive = true

                var header = metadata
                header["type"] = "session"
                header["created_at"] = ISO8601DateFormatter().string(from: Date())
                header["format_version"] = 2
                self.appendJSONObject(header)
                self.flushIfNeeded(force: true)
            } catch {
                self.fileHandle = nil
                self.isActive = false
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
            self.isActive = false
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

    func recordFrame(_ result: StabilizationFrameResult) {
        let debug = result.debug
        record(
            type: "frame",
            timestamp: result.timestamp,
            values: [
                "strength": debug.strength,
                "visual_dx": debug.visualDeltaX,
                "visual_dy": debug.visualDeltaY,
                "visual_confidence": debug.visualConfidence,
                "visual_vectors": debug.visualVectorCount,
                "fused_dx": debug.fusedDeltaX,
                "fused_dy": debug.fusedDeltaY,
                "crop_x": debug.correctionX,
                "crop_y": debug.correctionY,
                "crop_usage": debug.cropUsage,
                "pan": debug.isIntentionalPan,
                "gyro_trust": debug.gyroTrust,
                "auto_offset_ms": debug.automaticTimeOffsetMilliseconds,
                "analysis_ms": debug.analysisMilliseconds,
                "analysis_drops": debug.droppedAnalysisFrames,
                "motion_samples": debug.motionSampleCount
            ]
        )
    }

    private func record(type: String, timestamp: TimeInterval, values: [String: Any]) {
        guard timestamp.isFinite else { return }
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
    private struct FrameInput {
        var pixelBuffer: CVPixelBuffer
        var timestamp: TimeInterval
        var motionReferenceTime: TimeInterval
        var motionSamples: [StabilitySample]
        var tuning: StabilizationTuning
        var viewportSize: CGSize
        var focalLengthPixelsX: CGFloat
        var focalLengthPixelsY: CGFloat
    }

    var onResult: ((StabilizationFrameResult) -> Void)?

    private let queue = DispatchQueue(label: "com.puroo.scope.frameStabilization", qos: .userInteractive)
    private let pendingLock = NSLock()
    private var isProcessing = false
    private var pendingInput: FrameInput?
    private var droppedAnalysisFrames = 0
    private var visualTracker = SubpixelFrameMotionTracker()
    private var motionEstimator = QuaternionMotionEstimator()
    private var fusion = ComplementaryMotionFusion()
    private var trajectory = VirtualCameraTrajectoryController()

    func enqueue(
        pixelBuffer: CVPixelBuffer,
        timestamp: TimeInterval,
        motionReferenceTime: TimeInterval,
        motionSamples: [StabilitySample],
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

        let input = FrameInput(
            pixelBuffer: pixelBuffer,
            timestamp: timestamp,
            motionReferenceTime: motionReferenceTime,
            motionSamples: motionSamples,
            tuning: tuning,
            viewportSize: viewportSize,
            focalLengthPixelsX: max(focalLengthPixelsX, 1),
            focalLengthPixelsY: max(focalLengthPixelsY, 1)
        )

        pendingLock.lock()
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
        pendingInput = nil
        pendingLock.unlock()
        queue.async { [weak self] in
            self?.resetProcessingState()
        }
    }

    private func processLoop(startingWith firstInput: FrameInput) {
        var input = firstInput
        while true {
            autoreleasepool {
                process(input)
            }

            pendingLock.lock()
            if let next = pendingInput {
                pendingInput = nil
                pendingLock.unlock()
                input = next
            } else {
                isProcessing = false
                pendingLock.unlock()
                return
            }
        }
    }

    private func process(_ input: FrameInput) {
        let analysisStart = CACurrentMediaTime()
        let visual = visualTracker.process(
            pixelBuffer: input.pixelBuffer,
            timestamp: input.timestamp
        )
        let gyroCandidates = motionEstimator.candidates(
            samples: input.motionSamples,
            frameTime: input.motionReferenceTime,
            tuning: input.tuning,
            focalLengthPixelsX: input.focalLengthPixelsX,
            focalLengthPixelsY: input.focalLengthPixelsY,
            frameWidth: CGFloat(CVPixelBufferGetWidth(input.pixelBuffer)),
            frameHeight: CGFloat(CVPixelBufferGetHeight(input.pixelBuffer))
        )
        let fused = fusion.update(
            timestamp: input.timestamp,
            visual: visual,
            gyroCandidates: gyroCandidates,
            tuning: input.tuning
        )
        let crop = trajectory.update(
            timestamp: input.timestamp,
            deltaX: fused.deltaX,
            deltaY: fused.deltaY,
            confidence: fused.confidence,
            tuning: input.tuning
        )
        let analysisMilliseconds = (CACurrentMediaTime() - analysisStart) * 1000

        pendingLock.lock()
        let droppedFrames = droppedAnalysisFrames
        pendingLock.unlock()

        let transform = PreviewRenderTransform(
            scale: input.tuning.previewCropScale,
            rotationRadians: 0,
            translationX: crop.correctionX * input.viewportSize.width,
            translationY: crop.correctionY * input.viewportSize.height
        )
        let debug = StabilizationDebugSnapshot(
            strength: input.tuning.strength,
            cropScale: input.tuning.previewCropScale,
            visualDeltaX: visual?.deltaX ?? 0,
            visualDeltaY: visual?.deltaY ?? 0,
            visualConfidence: visual?.confidence ?? 0,
            visualVectorCount: visual?.vectorCount ?? 0,
            visualTexture: visual?.texture ?? 0,
            fusedDeltaX: fused.deltaX,
            fusedDeltaY: fused.deltaY,
            correctionX: crop.correctionX,
            correctionY: crop.correctionY,
            gyroTrust: fused.gyroTrust,
            automaticTimeOffsetMilliseconds: fused.automaticOffset * 1000,
            calibrationXX: fused.calibrationXX,
            calibrationXY: fused.calibrationXY,
            calibrationYX: fused.calibrationYX,
            calibrationYY: fused.calibrationYY,
            isIntentionalPan: crop.isIntentionalPan,
            cropUsage: crop.cropUsage,
            analysisMilliseconds: analysisMilliseconds,
            droppedAnalysisFrames: droppedFrames,
            motionSampleCount: input.motionSamples.count
        )
        let result = StabilizationFrameResult(
            timestamp: input.timestamp,
            transform: transform,
            normalizedCorrectionX: crop.correctionX,
            normalizedCorrectionY: crop.correctionY,
            debug: debug
        )
        StabilizationTraceRecorder.shared.recordFrame(result)
        onResult?(result)
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

    private let gridSize = 192
    private let searchRadius = 5
    private let patchRadius = 3
    private let anchorStride = 24
    private var previousFrame: AnalysisFrame?
    private var previousTimestamp: TimeInterval?

    func reset() {
        previousFrame = nil
        previousTimestamp = nil
    }

    func process(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) -> VisualMotionObservation? {
        guard let current = makeLumaGrid(from: pixelBuffer) else { return nil }
        guard let previousFrame, let previousTimestamp else {
            self.previousFrame = current
            self.previousTimestamp = timestamp
            return nil
        }

        self.previousFrame = current
        self.previousTimestamp = timestamp
        let elapsed = timestamp - previousTimestamp
        guard elapsed.isFinite, elapsed > 0, elapsed < 0.12 else { return nil }
        guard let estimate = estimateShift(reference: previousFrame, current: current) else {
            return nil
        }

        let sourceShiftX = estimate.dx * current.sourceStep
        let sourceShiftY = estimate.dy * current.sourceStep
        return VisualMotionObservation(
            timestamp: timestamp,
            deltaX: sourceShiftX / CGFloat(max(current.sourceWidth, 1)),
            deltaY: sourceShiftY / CGFloat(max(current.sourceHeight, 1)),
            confidence: estimate.confidence,
            vectorCount: estimate.vectorCount,
            texture: estimate.texture
        )
    }

    private func estimateShift(
        reference: AnalysisFrame,
        current: AnalysisFrame
    ) -> (dx: CGFloat, dy: CGFloat, confidence: CGFloat, vectorCount: Int, texture: CGFloat)? {
        let texture = textureScore(reference)
        guard texture >= 3.0 else { return nil }
        let vectors = patchVectors(reference: reference, current: current)
        guard vectors.count >= 6 else { return nil }

        let medianX = median(vectors.map(\.dx))
        let medianY = median(vectors.map(\.dy))
        let inliers = vectors.filter { vector in
            hypot(vector.dx - medianX, vector.dy - medianY) <= 0.90
        }
        guard inliers.count >= max(6, Int(ceil(Double(vectors.count) * 0.55))) else {
            return nil
        }

        let weight = max(inliers.reduce(CGFloat(0)) { $0 + $1.confidence }, 0.0001)
        let dx = inliers.reduce(CGFloat(0)) { $0 + $1.dx * $1.confidence } / weight
        let dy = inliers.reduce(CGFloat(0)) { $0 + $1.dy * $1.confidence } / weight
        let residual = inliers.reduce(CGFloat(0)) {
            $0 + hypot($1.dx - dx, $1.dy - dy)
        } / CGFloat(inliers.count)
        guard residual <= 0.62 else { return nil }

        let coverage = CGFloat(inliers.count) / CGFloat(vectors.count)
        let matchConfidence = weight / CGFloat(inliers.count)
        let consistency = clamp((0.62 - residual) / 0.62, min: 0, max: 1)
        let textureConfidence = clamp((texture - 3) / 9, min: 0, max: 1)
        let confidence = clamp(
            coverage * 0.25 + matchConfidence * 0.35 + consistency * 0.25 + textureConfidence * 0.15,
            min: 0,
            max: 1
        )
        guard confidence >= 0.24 else { return nil }
        return (dx, dy, confidence, inliers.count, texture)
    }

    private func patchVectors(reference: AnalysisFrame, current: AnalysisFrame) -> [PatchVector] {
        let margin = searchRadius + patchRadius + 2
        var vectors: [PatchVector] = []
        vectors.reserveCapacity(64)
        for y in stride(from: margin, to: gridSize - margin, by: anchorStride) {
            for x in stride(from: margin, to: gridSize - margin, by: anchorStride) {
                let index = y * gridSize + x
                guard reference.roiMask[index],
                      current.roiMask[index],
                      patchTexture(reference, centerX: x, centerY: y) > 3.2,
                      let vector = bestPatchVector(
                          reference: reference,
                          current: current,
                          centerX: x,
                          centerY: y
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
        centerY: Int
    ) -> PatchVector? {
        let diameter = searchRadius * 2 + 1
        var scores = Array(repeating: Float.greatestFiniteMagnitude, count: diameter * diameter)
        var bestScore = Float.greatestFiniteMagnitude
        var secondScore = Float.greatestFiniteMagnitude
        var bestDX = 0
        var bestDY = 0

        for dy in -searchRadius...searchRadius {
            for dx in -searchRadius...searchRadius {
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
                scores[(dy + searchRadius) * diameter + dx + searchRadius] = score
                if score < bestScore {
                    secondScore = bestScore
                    bestScore = score
                    bestDX = dx
                    bestDY = dy
                } else if score < secondScore {
                    secondScore = score
                }
            }
        }

        guard bestScore.isFinite, bestScore < 0.52 else { return nil }
        var subpixelX: CGFloat = 0
        var subpixelY: CGFloat = 0
        if abs(bestDX) < searchRadius {
            let row = (bestDY + searchRadius) * diameter
            subpixelX = parabolicMinimum(
                left: scores[row + bestDX - 1 + searchRadius],
                center: bestScore,
                right: scores[row + bestDX + 1 + searchRadius]
            )
        }
        if abs(bestDY) < searchRadius {
            let column = bestDX + searchRadius
            subpixelY = parabolicMinimum(
                left: scores[(bestDY - 1 + searchRadius) * diameter + column],
                center: bestScore,
                right: scores[(bestDY + 1 + searchRadius) * diameter + column]
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
            dx: CGFloat(bestDX) + subpixelX,
            dy: CGFloat(bestDY) + subpixelY,
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
        guard denominator > 24 else { return nil }
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
            roiMask: makeROIMask(),
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
            roiMask: makeROIMask(),
            sourceWidth: width,
            sourceHeight: height,
            sourceStep: geometry.step
        )
    }

    private func samplingGeometry(width: Int, height: Int) -> (
        cropX: CGFloat,
        cropY: CGFloat,
        step: CGFloat
    ) {
        let cropSide = CGFloat(min(width, height)) * 0.88
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

private struct GyroMotionCandidate {
    var automaticOffset: TimeInterval
    var deltaX: CGFloat
    var deltaY: CGFloat
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
    private let automaticOffsets: [TimeInterval] = stride(from: -0.04, through: 0.0401, by: 0.01)
        .map { $0 }
    private var previousFrameTime: TimeInterval?

    func reset() {
        previousFrameTime = nil
    }

    func candidates(
        samples: [StabilitySample],
        frameTime: TimeInterval,
        tuning: StabilizationTuning,
        focalLengthPixelsX: CGFloat,
        focalLengthPixelsY: CGFloat,
        frameWidth: CGFloat,
        frameHeight: CGFloat
    ) -> [GyroMotionCandidate] {
        defer { previousFrameTime = frameTime }
        guard let previousFrameTime, !samples.isEmpty else { return [] }
        var output: [GyroMotionCandidate] = []
        output.reserveCapacity(automaticOffsets.count)
        for automaticOffset in automaticOffsets {
            let totalOffset = tuning.motionTimeOffset + automaticOffset
            guard let previous = interpolatedQuaternion(
                at: previousFrameTime + totalOffset,
                samples: samples
            ), let current = interpolatedQuaternion(
                at: frameTime + totalOffset,
                samples: samples
            ) else {
                continue
            }
            let relative = previous.inverse.multiplied(by: current)
            let rotation = relative.rotationVector
            let mapped = tuning.gyroAxisMapping.map(x: rotation.x, y: rotation.y)
            let deltaX = clamp(
                CGFloat(mapped.horizontal) * focalLengthPixelsX / max(frameWidth, 1),
                min: -0.06,
                max: 0.06
            )
            let deltaY = clamp(
                CGFloat(mapped.vertical) * focalLengthPixelsY / max(frameHeight, 1),
                min: -0.06,
                max: 0.06
            )
            output.append(
                GyroMotionCandidate(
                    automaticOffset: automaticOffset,
                    deltaX: deltaX,
                    deltaY: deltaY
                )
            )
        }
        return output
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
    var confidence: CGFloat
    var gyroTrust: CGFloat
    var automaticOffset: TimeInterval
    var calibrationXX: CGFloat
    var calibrationXY: CGFloat
    var calibrationYX: CGFloat
    var calibrationYY: CGFloat
}

private final class ComplementaryMotionFusion {
    private struct LagCorrelation {
        var crossXX: CGFloat = 0
        var crossXY: CGFloat = 0
        var crossYX: CGFloat = 0
        var crossYY: CGFloat = 0
        var visualEnergy: CGFloat = 0
        var gyroEnergy: CGFloat = 0
        var sampleCount: Int = 0

        var score: CGFloat {
            let crossEnergy = sqrt(
                crossXX * crossXX + crossXY * crossXY +
                    crossYX * crossYX + crossYY * crossYY
            )
            let denominator = sqrt(max(visualEnergy * gyroEnergy, 0.0000000001))
            return min(crossEnergy / denominator, 1)
        }
    }

    private var correlations: [Int: LagCorrelation] = [:]
    private var selectedOffsetKey = 0
    private var calibrationXX: CGFloat = 0
    private var calibrationXY: CGFloat = 0
    private var calibrationYX: CGFloat = 0
    private var calibrationYY: CGFloat = 0
    private var calibrationCount = 0
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
            calibrationXX = 0
            calibrationXY = 0
            calibrationYX = 0
            calibrationYY = 0
            calibrationCount = 0
        }
    }

    func update(
        timestamp: TimeInterval,
        visual: VisualMotionObservation?,
        gyroCandidates: [GyroMotionCandidate],
        tuning: StabilizationTuning
    ) -> FusedMotionDelta {
        let elapsed = lastTimestamp.map { timestamp - $0 } ?? (1.0 / 60.0)
        lastTimestamp = timestamp
        if !elapsed.isFinite || elapsed <= 0 || elapsed > 0.12 {
            reset(keepCalibration: true)
            lastTimestamp = timestamp
        }
        let dt = CGFloat(min(max(elapsed, 1.0 / 120.0), 1.0 / 20.0))

        if let visual {
            updateLagCorrelations(visual: visual, candidates: gyroCandidates)
            selectBestOffsetIfReady()
        }
        let selected = selectedCandidate(from: gyroCandidates)
        if let visual, let selected {
            updateCalibration(visual: visual, gyro: selected)
        }

        let selectedScore = correlations[selectedOffsetKey]?.score ?? 0
        let trainingProgress = min(CGFloat(calibrationCount) / 120, 1)
        let gyroTrust = min(
            0.90,
            trainingProgress * clamp((selectedScore - 0.12) / 0.58, min: 0, max: 1)
        )

        let visualVelocityX = (visual?.deltaX ?? 0) / dt
        let visualVelocityY = (visual?.deltaY ?? 0) / dt
        let predictedGyroX: CGFloat
        let predictedGyroY: CGFloat
        if let selected {
            predictedGyroX = calibrationXX * selected.deltaX + calibrationXY * selected.deltaY
            predictedGyroY = calibrationYX * selected.deltaX + calibrationYY * selected.deltaY
        } else {
            predictedGyroX = 0
            predictedGyroY = 0
        }
        let gyroVelocityX = predictedGyroX / dt
        let gyroVelocityY = predictedGyroY / dt

        let cutoff = tuning.complementaryCutoffFrequency
        let alpha = CGFloat(1 - exp(-2 * Double.pi * cutoff * Double(dt)))
        visualLowVelocityX += (visualVelocityX - visualLowVelocityX) * alpha
        visualLowVelocityY += (visualVelocityY - visualLowVelocityY) * alpha
        gyroLowVelocityX += (gyroVelocityX - gyroLowVelocityX) * alpha
        gyroLowVelocityY += (gyroVelocityY - gyroLowVelocityY) * alpha

        let visualHighX = visualVelocityX - visualLowVelocityX
        let visualHighY = visualVelocityY - visualLowVelocityY
        let gyroHighX = gyroVelocityX - gyroLowVelocityX
        let gyroHighY = gyroVelocityY - gyroLowVelocityY
        let fusedVelocityX: CGFloat
        let fusedVelocityY: CGFloat
        if visual != nil {
            fusedVelocityX = visualLowVelocityX + visualHighX * (1 - gyroTrust) + gyroHighX * gyroTrust
            fusedVelocityY = visualLowVelocityY + visualHighY * (1 - gyroTrust) + gyroHighY * gyroTrust
        } else if gyroTrust > 0.15 {
            fusedVelocityX = gyroVelocityX
            fusedVelocityY = gyroVelocityY
        } else {
            fusedVelocityX = 0
            fusedVelocityY = 0
        }

        return FusedMotionDelta(
            deltaX: clamp(fusedVelocityX * dt, min: -0.05, max: 0.05),
            deltaY: clamp(fusedVelocityY * dt, min: -0.05, max: 0.05),
            confidence: visual?.confidence ?? gyroTrust,
            gyroTrust: gyroTrust,
            automaticOffset: TimeInterval(selectedOffsetKey) / 1000,
            calibrationXX: calibrationXX,
            calibrationXY: calibrationXY,
            calibrationYX: calibrationYX,
            calibrationYY: calibrationYY
        )
    }

    private func updateLagCorrelations(
        visual: VisualMotionObservation,
        candidates: [GyroMotionCandidate]
    ) {
        let decay: CGFloat = 0.975
        for candidate in candidates {
            let key = Int((candidate.automaticOffset * 1000).rounded())
            var correlation = correlations[key] ?? LagCorrelation()
            correlation.crossXX = correlation.crossXX * decay + visual.deltaX * candidate.deltaX
            correlation.crossXY = correlation.crossXY * decay + visual.deltaX * candidate.deltaY
            correlation.crossYX = correlation.crossYX * decay + visual.deltaY * candidate.deltaX
            correlation.crossYY = correlation.crossYY * decay + visual.deltaY * candidate.deltaY
            correlation.visualEnergy = correlation.visualEnergy * decay +
                visual.deltaX * visual.deltaX + visual.deltaY * visual.deltaY
            correlation.gyroEnergy = correlation.gyroEnergy * decay +
                candidate.deltaX * candidate.deltaX + candidate.deltaY * candidate.deltaY
            correlation.sampleCount += 1
            correlations[key] = correlation
        }
    }

    private func selectBestOffsetIfReady() {
        let candidates = correlations.filter { $0.value.sampleCount >= 24 }
        guard let best = candidates.max(by: { $0.value.score < $1.value.score }) else { return }
        let currentScore = correlations[selectedOffsetKey]?.score ?? 0
        if best.key == selectedOffsetKey || best.value.score >= currentScore + 0.025 {
            selectedOffsetKey = best.key
        }
    }

    private func selectedCandidate(from candidates: [GyroMotionCandidate]) -> GyroMotionCandidate? {
        candidates.min {
            abs(Int(($0.automaticOffset * 1000).rounded()) - selectedOffsetKey) <
                abs(Int(($1.automaticOffset * 1000).rounded()) - selectedOffsetKey)
        }
    }

    private func updateCalibration(
        visual: VisualMotionObservation,
        gyro: GyroMotionCandidate
    ) {
        guard visual.confidence >= 0.30 else { return }
        let energy = gyro.deltaX * gyro.deltaX + gyro.deltaY * gyro.deltaY
        guard energy >= 0.00000004 else { return }

        let predictedX = calibrationXX * gyro.deltaX + calibrationXY * gyro.deltaY
        let predictedY = calibrationYX * gyro.deltaX + calibrationYY * gyro.deltaY
        let errorX = visual.deltaX - predictedX
        let errorY = visual.deltaY - predictedY
        let learningRate = CGFloat(0.018) * visual.confidence
        let denominator = energy + 0.0000002
        let stepXX = clamp(learningRate * errorX * gyro.deltaX / denominator, min: -0.04, max: 0.04)
        let stepXY = clamp(learningRate * errorX * gyro.deltaY / denominator, min: -0.04, max: 0.04)
        let stepYX = clamp(learningRate * errorY * gyro.deltaX / denominator, min: -0.04, max: 0.04)
        let stepYY = clamp(learningRate * errorY * gyro.deltaY / denominator, min: -0.04, max: 0.04)
        calibrationXX = clamp(calibrationXX + stepXX, min: -2, max: 2)
        calibrationXY = clamp(calibrationXY + stepXY, min: -2, max: 2)
        calibrationYX = clamp(calibrationYX + stepYX, min: -2, max: 2)
        calibrationYY = clamp(calibrationYY + stepYY, min: -2, max: 2)
        calibrationCount += 1
    }

    private func clamp<T: Comparable>(_ value: T, min minimum: T, max maximum: T) -> T {
        Swift.min(Swift.max(value, minimum), maximum)
    }
}

private struct VirtualCameraCropResult {
    var correctionX: CGFloat
    var correctionY: CGFloat
    var isIntentionalPan: Bool
    var cropUsage: CGFloat
}

private final class VirtualCameraTrajectoryController {
    private var rawX: CGFloat = 0
    private var rawY: CGFloat = 0
    private var desiredX: CGFloat = 0
    private var desiredY: CGFloat = 0
    private var velocityX: CGFloat = 0
    private var velocityY: CGFloat = 0
    private var accelerationX: CGFloat = 0
    private var accelerationY: CGFloat = 0
    private var lastTimestamp: TimeInterval?
    private var recentVelocities: [CGPoint] = []

    func reset() {
        rawX = 0
        rawY = 0
        desiredX = 0
        desiredY = 0
        velocityX = 0
        velocityY = 0
        accelerationX = 0
        accelerationY = 0
        lastTimestamp = nil
        recentVelocities.removeAll(keepingCapacity: true)
    }

    func update(
        timestamp: TimeInterval,
        deltaX: CGFloat,
        deltaY: CGFloat,
        confidence: CGFloat,
        tuning: StabilizationTuning
    ) -> VirtualCameraCropResult {
        guard tuning.usesDigitalStabilization else {
            reset()
            return VirtualCameraCropResult(
                correctionX: 0,
                correctionY: 0,
                isIntentionalPan: false,
                cropUsage: 0
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
                isIntentionalPan: false,
                cropUsage: 0
            )
        }
        let dt = CGFloat(min(max(elapsed, 1.0 / 120.0), 1.0 / 20.0))
        let measurementWeight = clamp(0.35 + confidence * 0.65, min: 0.35, max: 1)
        let measuredDeltaX = deltaX * measurementWeight
        let measuredDeltaY = deltaY * measurementWeight
        rawX += measuredDeltaX
        rawY += measuredDeltaY

        let panState = updatePanState(
            velocityX: measuredDeltaX / dt,
            velocityY: measuredDeltaY / dt,
            threshold: tuning.panActivationSpeed
        )
        let hardLimit = max(tuning.maximumCropOffsetFraction, 0.001)
        let preCorrectionX = desiredX - rawX
        let preCorrectionY = desiredY - rawY
        let preUsage = max(abs(preCorrectionX), abs(preCorrectionY)) / hardLimit

        var followFrequency = panState
            ? tuning.panFollowFrequency
            : tuning.staticFollowFrequency
        if preUsage > 0.72 {
            followFrequency = max(followFrequency, 6 + Double(preUsage) * 6)
        }
        advanceDesiredPath(
            deltaTime: dt,
            followFrequency: followFrequency,
            tuning: tuning
        )

        let amount = tuning.stabilizationAmount
        var correctionX = (desiredX - rawX) * amount
        var correctionY = (desiredY - rawY) * amount
        correctionX = clamp(correctionX, min: -hardLimit, max: hardLimit)
        correctionY = clamp(correctionY, min: -hardLimit, max: hardLimit)

        if amount > 0.001 {
            if abs(correctionX) >= hardLimit * 0.999 {
                desiredX = rawX + correctionX / amount
                velocityX *= 0.65
            }
            if abs(correctionY) >= hardLimit * 0.999 {
                desiredY = rawY + correctionY / amount
                velocityY *= 0.65
            }
        }
        let usage = max(abs(correctionX), abs(correctionY)) / hardLimit
        return VirtualCameraCropResult(
            correctionX: correctionX,
            correctionY: correctionY,
            isIntentionalPan: panState,
            cropUsage: clamp(usage, min: 0, max: 1)
        )
    }

    private func updatePanState(
        velocityX: CGFloat,
        velocityY: CGFloat,
        threshold: CGFloat
    ) -> Bool {
        recentVelocities.append(CGPoint(x: velocityX, y: velocityY))
        if recentVelocities.count > 8 {
            recentVelocities.removeFirst(recentVelocities.count - 8)
        }
        guard recentVelocities.count >= 5 else { return false }

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
        guard movingCount >= 4 else { return false }
        let coherence = hypot(directionX, directionY) / movingCount
        let meanSpeed = speedTotal / movingCount
        return coherence >= 0.82 && meanSpeed >= threshold
    }

    private func advanceDesiredPath(
        deltaTime: CGFloat,
        followFrequency: Double,
        tuning: StabilizationTuning
    ) {
        let omega = CGFloat(2 * Double.pi * followFrequency)
        let requestedAccelerationX = omega * omega * (rawX - desiredX) - 2 * omega * velocityX
        let requestedAccelerationY = omega * omega * (rawY - desiredY) - 2 * omega * velocityY
        let jerkStep = tuning.maximumTrajectoryJerk * deltaTime
        accelerationX += clamp(
            requestedAccelerationX - accelerationX,
            min: -jerkStep,
            max: jerkStep
        )
        accelerationY += clamp(
            requestedAccelerationY - accelerationY,
            min: -jerkStep,
            max: jerkStep
        )
        accelerationX = clamp(
            accelerationX,
            min: -tuning.maximumTrajectoryAcceleration,
            max: tuning.maximumTrajectoryAcceleration
        )
        accelerationY = clamp(
            accelerationY,
            min: -tuning.maximumTrajectoryAcceleration,
            max: tuning.maximumTrajectoryAcceleration
        )
        velocityX += accelerationX * deltaTime
        velocityY += accelerationY * deltaTime
        velocityX = clamp(
            velocityX,
            min: -tuning.maximumTrajectoryVelocity,
            max: tuning.maximumTrajectoryVelocity
        )
        velocityY = clamp(
            velocityY,
            min: -tuning.maximumTrajectoryVelocity,
            max: tuning.maximumTrajectoryVelocity
        )
        desiredX += velocityX * deltaTime
        desiredY += velocityY * deltaTime
    }

    private func clamp<T: Comparable>(_ value: T, min minimum: T, max maximum: T) -> T {
        Swift.min(Swift.max(value, minimum), maximum)
    }
}
