import AVFoundation
import CoreImage
import Metal
import MetalKit
import QuartzCore
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

private struct CropWindowTrajectoryState {
    private var x: CGFloat = 0
    private var y: CGFloat = 0
    private var velocityX: CGFloat = 0
    private var velocityY: CGFloat = 0
    private var lastTimestamp: TimeInterval?
    private var lastPreference: StabilizationPreference?

    mutating func reset() {
        x = 0
        y = 0
        velocityX = 0
        velocityY = 0
        lastTimestamp = nil
        lastPreference = nil
    }

    mutating func update(
        target correction: PreviewVisualCorrection,
        preference: StabilizationPreference
    ) -> PreviewVisualCorrection {
        let settings = CropWindowTrajectorySettings(preference: preference)
        let timestamp = correction.timestamp.isFinite && correction.timestamp > 0
            ? correction.timestamp
            : CACurrentMediaTime()

        if lastPreference != preference {
            x = 0
            y = 0
            velocityX = 0
            velocityY = 0
            lastPreference = preference
            lastTimestamp = timestamp
        }

        let elapsed = lastTimestamp.map { timestamp - $0 } ?? (1.0 / 60.0)
        let dt = clamp(CGFloat(elapsed), min: 1.0 / 120.0, max: 1.0 / 20.0)
        lastTimestamp = timestamp

        var targetX = correction.normalizedX
        var targetY = correction.normalizedY
        let targetMagnitude = (targetX * targetX + targetY * targetY).squareRoot()
        if targetMagnitude <= settings.deadZone {
            targetX = 0
            targetY = 0
        } else if targetMagnitude > 0 {
            let scale = (targetMagnitude - settings.deadZone) / targetMagnitude
            targetX *= scale
            targetY *= scale
        }

        targetX = clamp(targetX, min: -settings.maximumOffset, max: settings.maximumOffset)
        targetY = clamp(targetY, min: -settings.maximumOffset, max: settings.maximumOffset)

        let edgeDamping = dampingForEdge(
            x: x,
            y: y,
            maximumOffset: settings.maximumOffset,
            softLimit: settings.softLimit
        )
        let desiredVelocityX = (targetX - x) * settings.responseRate * edgeDamping
        let desiredVelocityY = (targetY - y) * settings.responseRate * edgeDamping
        let maximumVelocity = settings.maximumVelocity * edgeDamping
        let maximumVelocityStep = settings.maximumAcceleration * dt

        velocityX += clamp(desiredVelocityX - velocityX, min: -maximumVelocityStep, max: maximumVelocityStep)
        velocityY += clamp(desiredVelocityY - velocityY, min: -maximumVelocityStep, max: maximumVelocityStep)
        velocityX = clamp(velocityX, min: -maximumVelocity, max: maximumVelocity)
        velocityY = clamp(velocityY, min: -maximumVelocity, max: maximumVelocity)

        x += velocityX * dt
        y += velocityY * dt

        let recenterAlpha = CGFloat(1 - exp(-Double(dt * settings.centeringRate)))
        if targetX == 0 {
            x += (0 - x) * recenterAlpha
        }
        if targetY == 0 {
            y += (0 - y) * recenterAlpha
        }

        if (x * x + y * y).squareRoot() < settings.snapToCenterThreshold,
           targetX == 0,
           targetY == 0 {
            x = 0
            y = 0
            velocityX = 0
            velocityY = 0
        }

        x = clamp(x, min: -settings.maximumOffset, max: settings.maximumOffset)
        y = clamp(y, min: -settings.maximumOffset, max: settings.maximumOffset)

        return PreviewVisualCorrection(
            normalizedX: x,
            normalizedY: y,
            confidence: correction.confidence,
            timestamp: timestamp
        )
    }

    private func dampingForEdge(
        x: CGFloat,
        y: CGFloat,
        maximumOffset: CGFloat,
        softLimit: CGFloat
    ) -> CGFloat {
        guard maximumOffset > 0 else { return 0 }
        let usage = max(abs(x), abs(y)) / maximumOffset
        guard usage > softLimit else { return 1 }
        let remaining = max(0, 1 - usage)
        let softRange = max(0.001, 1 - softLimit)
        return clamp(remaining / softRange, min: 0.22, max: 1)
    }

    private func clamp<T: Comparable>(_ value: T, min minimum: T, max maximum: T) -> T {
        Swift.min(Swift.max(value, minimum), maximum)
    }
}

private struct CropWindowTrajectorySettings {
    var maximumOffset: CGFloat
    var deadZone: CGFloat
    var responseRate: CGFloat
    var centeringRate: CGFloat
    var maximumVelocity: CGFloat
    var maximumAcceleration: CGFloat
    var softLimit: CGFloat
    var snapToCenterThreshold: CGFloat

    init(preference: StabilizationPreference) {
        switch preference {
        case .off:
            maximumOffset = 0
            deadZone = .infinity
            responseRate = 0
            centeringRate = 0
            maximumVelocity = 0
            maximumAcceleration = 0
            softLimit = 1
            snapToCenterThreshold = 0
        case .auto:
            maximumOffset = 0.15
            deadZone = 0.015
            responseRate = 18.0
            centeringRate = 12.0
            maximumVelocity = 0.35
            maximumAcceleration = 2.4
            softLimit = 0.78
            snapToCenterThreshold = 0.006
        case .balanced:
            maximumOffset = 0.22
            deadZone = 0.004
            responseRate = 54.0
            centeringRate = 8.0
            maximumVelocity = 1.20
            maximumAcceleration = 14.0
            softLimit = 0.90
            snapToCenterThreshold = 0.003
        case .strong:
            maximumOffset = 0.22
            deadZone = 0.004
            responseRate = 54.0
            centeringRate = 8.0
            maximumVelocity = 1.20
            maximumAcceleration = 14.0
            softLimit = 0.90
            snapToCenterThreshold = 0.003
        }
    }
}

private struct GyroRotation {
    var pitch: Double
    var yaw: Double
    var roll: Double

    static let zero = GyroRotation(pitch: 0, yaw: 0, roll: 0)

    static func + (lhs: GyroRotation, rhs: GyroRotation) -> GyroRotation {
        GyroRotation(
            pitch: lhs.pitch + rhs.pitch,
            yaw: lhs.yaw + rhs.yaw,
            roll: lhs.roll + rhs.roll
        )
    }

    static func - (lhs: GyroRotation, rhs: GyroRotation) -> GyroRotation {
        GyroRotation(
            pitch: lhs.pitch - rhs.pitch,
            yaw: lhs.yaw - rhs.yaw,
            roll: lhs.roll - rhs.roll
        )
    }

    mutating func add(_ delta: GyroRotation) {
        pitch += delta.pitch
        yaw += delta.yaw
        roll += delta.roll
    }
}

private final class MotionTrajectoryStabilizer {
    private var lastPreference: StabilizationPreference?
    private var lastFrameTime: TimeInterval?
    private var rawTrajectory = GyroRotation.zero
    private var smoothedTrajectory = GyroRotation.zero
    private var filteredDirectX: CGFloat = 0
    private var filteredDirectY: CGFloat = 0
    private var filteredDirectRoll: CGFloat = 0
    private var lastTransform = PreviewRenderTransform.identity

    func reset() {
        lastPreference = nil
        lastFrameTime = nil
        rawTrajectory = .zero
        smoothedTrajectory = .zero
        resetDirectGyroCorrection()
        lastTransform = .identity
    }

    func transform(
        at timestamp: TimeInterval,
        samples: [StabilitySample],
        preference: StabilizationPreference,
        viewportSize: CGSize
    ) -> PreviewRenderTransform {
        guard preference.usesElectronicPreviewStabilization,
              timestamp.isFinite,
              viewportSize.width > 1,
              viewportSize.height > 1
        else {
            reset()
            return .identity
        }

        if lastPreference != preference {
            lastPreference = preference
            lastFrameTime = timestamp
            rawTrajectory = .zero
            smoothedTrajectory = .zero
            resetDirectGyroCorrection()
            lastTransform = PreviewRenderTransform(
                scale: preference.previewCropScale,
                rotationRadians: 0,
                translationX: 0,
                translationY: 0
            )
            return lastTransform
        }

        guard let previousFrameTime = lastFrameTime else {
            lastFrameTime = timestamp
            return lastTransform
        }

        let deltaTime = timestamp - previousFrameTime
        guard deltaTime.isFinite, deltaTime > 0 else {
            return lastTransform
        }

        if deltaTime > 0.15 {
            lastFrameTime = timestamp
            rawTrajectory = .zero
            smoothedTrajectory = .zero
            resetDirectGyroCorrection()
            lastTransform = PreviewRenderTransform(
                scale: preference.previewCropScale,
                rotationRadians: 0,
                translationX: 0,
                translationY: 0
            )
            return lastTransform
        }

        lastFrameTime = timestamp
        let delta = integrate(samples: samples, from: previousFrameTime, to: timestamp)
        rawTrajectory.add(delta)

        let frameScale = max(deltaTime / (1.0 / 60.0), 0.25)
        let alpha = pow(preference.trajectorySmoothingAlpha, frameScale)
        smoothedTrajectory.pitch = smoothedTrajectory.pitch * alpha + rawTrajectory.pitch * (1 - alpha)
        smoothedTrajectory.yaw = smoothedTrajectory.yaw * alpha + rawTrajectory.yaw * (1 - alpha)
        smoothedTrajectory.roll = smoothedTrajectory.roll * alpha + rawTrajectory.roll * (1 - alpha)

        let compensation = rawTrajectory - smoothedTrajectory
        let scale = preference.previewCropScale
        let maxX = max(12, viewportSize.width * (scale - 1) * preference.previewCropTravelFactor)
        let maxY = max(12, viewportSize.height * (scale - 1) * preference.previewCropTravelFactor)
        let gain = preference.previewStabilizationGain
        var translationX = clamp(CGFloat(compensation.pitch) * gain, min: -maxX, max: maxX)
        var translationY = clamp(CGFloat(-compensation.yaw) * gain, min: -maxY, max: maxY)
        let rollLimit: CGFloat = preference == .strong ? .pi / 30 : .pi / 44
        var roll = clamp(
            CGFloat(-compensation.roll) * preference.trajectoryRollGain,
            min: -rollLimit,
            max: rollLimit
        )

        let direct = smoothedGyroCorrection(
            samples: samples,
            preference: preference,
            maxX: maxX,
            maxY: maxY,
            rollLimit: rollLimit,
            deltaTime: deltaTime
        )
        translationX = clamp(translationX + direct.x, min: -maxX, max: maxX)
        translationY = clamp(translationY + direct.y, min: -maxY, max: maxY)
        roll = clamp(roll + direct.roll, min: -rollLimit, max: rollLimit)

        lastTransform = PreviewRenderTransform(
            scale: scale,
            rotationRadians: roll,
            translationX: translationX,
            translationY: translationY
        )
        return lastTransform
    }

    private func integrate(
        samples: [StabilitySample],
        from start: TimeInterval,
        to end: TimeInterval
    ) -> GyroRotation {
        guard samples.count >= 2 else { return .zero }

        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        var total = GyroRotation.zero
        var previous = ordered[0]

        for current in ordered.dropFirst() {
            let segmentStart = max(start, previous.timestamp)
            let segmentEnd = min(end, current.timestamp)
            if segmentEnd > segmentStart {
                let dt = segmentEnd - segmentStart
                total.pitch += (previous.rotationX + current.rotationX) * 0.5 * dt
                total.yaw += (previous.rotationY + current.rotationY) * 0.5 * dt
                total.roll += (previous.rotationZ + current.rotationZ) * 0.5 * dt
            }
            previous = current
        }

        return total
    }

    private func smoothedGyroCorrection(
        samples: [StabilitySample],
        preference: StabilizationPreference,
        maxX: CGFloat,
        maxY: CGFloat,
        rollLimit: CGFloat,
        deltaTime: TimeInterval
    ) -> (x: CGFloat, y: CGFloat, roll: CGFloat) {
        guard preference == .balanced || preference == .strong else {
            resetDirectGyroCorrection()
            return (0, 0, 0)
        }

        let suffixCount = preference == .balanced ? 8 : 10
        let recent = samples.suffix(suffixCount)
        guard !recent.isEmpty else { return (0, 0, 0) }

        let divisor = Double(recent.count)
        let rateX = recent.reduce(0) { $0 + $1.rotationX } / divisor
        let rateY = recent.reduce(0) { $0 + $1.rotationY } / divisor
        let rateZ = recent.reduce(0) { $0 + $1.rotationZ } / divisor
        let floor = preference == .balanced ? 0.0040 : 0.0026
        let gain: CGFloat = preference == .balanced ? 1150 : 1850
        let rollGain: CGFloat = preference == .balanced ? 0.006 : 0.010
        let responseRate = preference == .balanced ? 18.0 : 26.0
        let maximumStepFraction: CGFloat = preference == .balanced ? 1.25 : 1.90

        let xRate = deadzone(rateX, floor: floor)
        let yRate = deadzone(rateY, floor: floor)
        let zRate = deadzone(rateZ, floor: floor)

        let targetX: CGFloat
        let targetY: CGFloat
        let targetRoll: CGFloat
        switch preference {
        case .balanced:
            targetX = clamp(CGFloat(xRate) * gain, min: -maxX * 0.26, max: maxX * 0.26)
            targetY = clamp(CGFloat(-yRate) * gain, min: -maxY * 0.26, max: maxY * 0.26)
            targetRoll = clamp(CGFloat(-zRate) * rollGain, min: -rollLimit * 0.35, max: rollLimit * 0.35)
        case .strong:
            targetX = clamp(CGFloat(xRate) * gain, min: -maxX * 0.38, max: maxX * 0.38)
            targetY = clamp(CGFloat(-yRate) * gain, min: -maxY * 0.38, max: maxY * 0.38)
            targetRoll = clamp(CGFloat(-zRate) * rollGain, min: -rollLimit * 0.50, max: rollLimit * 0.50)
        case .off, .auto:
            resetDirectGyroCorrection()
            return (0, 0, 0)
        }

        let dt = clamp(CGFloat(deltaTime), min: 1.0 / 300.0, max: 1.0 / 30.0)
        let alpha = CGFloat(1 - exp(-Double(dt) * responseRate))
        let maxStepX = max(1.0, maxX * maximumStepFraction * dt)
        let maxStepY = max(1.0, maxY * maximumStepFraction * dt)
        let maxStepRoll = max(0.001, rollLimit * maximumStepFraction * dt)

        filteredDirectX += clamp((targetX - filteredDirectX) * alpha, min: -maxStepX, max: maxStepX)
        filteredDirectY += clamp((targetY - filteredDirectY) * alpha, min: -maxStepY, max: maxStepY)
        filteredDirectRoll += clamp((targetRoll - filteredDirectRoll) * alpha, min: -maxStepRoll, max: maxStepRoll)

        return (filteredDirectX, filteredDirectY, filteredDirectRoll)
    }

    private func deadzone(_ value: Double, floor: Double) -> Double {
        let magnitude = abs(value)
        guard magnitude > floor else { return 0 }
        return value > 0 ? magnitude - floor : -(magnitude - floor)
    }

    private func resetDirectGyroCorrection() {
        filteredDirectX = 0
        filteredDirectY = 0
        filteredDirectRoll = 0
    }

    private func clamp<T: Comparable>(_ value: T, min minimum: T, max maximum: T) -> T {
        Swift.min(Swift.max(value, minimum), maximum)
    }
}

final class PreviewContainerView: UIView, CameraFrameSink, StabilizedRecordingFrameSink {
    private let metalView: MTKView
    private let renderer: StabilizedMetalPreviewRenderer
    private let visualAnalyzer = PreviewFrameMotionAnalyzer()
    private let frameClockMapper = PreviewFrameClockMapper()
    private let overviewCIContext = CIContext()
    private let overviewContainer = UIView()
    private let overviewImageView = UIImageView()
    private let cropWindowView = UIView()
    private let cropCenterHorizontalView = UIView()
    private let cropCenterVerticalView = UIView()
    private let viewportLock = NSLock()
    private let preferenceLock = NSLock()
    private let trajectoryLock = NSLock()
    private var viewportSize = CGSize.zero
    private var stabilizationPreference: StabilizationPreference = .off
    private weak var motionMonitor: MotionStabilityMonitor?
    private var trajectoryStabilizer = MotionTrajectoryStabilizer()
    private var latestCropCorrection = PreviewVisualCorrection.identity
    private var latestMotionCorrection = PreviewVisualCorrection.identity
    private var cropTrajectory = CropWindowTrajectoryState()
    private var overviewImageAspectRatio: CGFloat = 1
    private var lastOverviewUpdateTime: TimeInterval = 0

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

        visualAnalyzer.onCorrection = { [weak self] correction in
            self?.applyVisualCropCorrection(correction)
        }

        addSubview(metalView)
        configureOverview()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        metalView.frame = bounds
        layoutOverview()
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

    func applyPreviewTransform(_ transform: PreviewRenderTransform, at timestamp: TimeInterval) {
        renderer.setRenderTransform(transform, at: timestamp)
    }

    func updateStabilizationPreference(_ preference: StabilizationPreference) {
        preferenceLock.lock()
        stabilizationPreference = preference
        preferenceLock.unlock()

        visualAnalyzer.setPreference(preference)
        renderer.setPreviewDelayFrames(preference.visualPreviewDelayFrames)
        renderer.setCropWindowScale(preference.usesCropWindowStabilization ? preference.previewCropScale : 1)
        trajectoryLock.lock()
        trajectoryStabilizer.reset()
        trajectoryLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.cropTrajectory.reset()
            self.latestCropCorrection = .identity
            self.latestMotionCorrection = .identity
            self.renderer.setVisualCorrection(.identity)
            self.overviewContainer.isHidden = !preference.usesCropWindowStabilization
            self.layoutOverview()
            self.layoutCropWindow(correction: self.combinedCropCorrection())
        }
    }

    func stopVisualAnalysis() {
        visualAnalyzer.setPreference(.off)
        renderer.setVisualCorrection(.identity)
        renderer.setCropWindowScale(1)
        trajectoryLock.lock()
        trajectoryStabilizer.reset()
        trajectoryLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.cropTrajectory.reset()
            self.latestCropCorrection = .identity
            self.latestMotionCorrection = .identity
            self.overviewContainer.isHidden = true
            self.layoutCropWindow(correction: .identity)
        }
    }

    func updateMotionMonitor(_ motionMonitor: MotionStabilityMonitor?) {
        self.motionMonitor = motionMonitor
        trajectoryLock.lock()
        trajectoryStabilizer.reset()
        trajectoryLock.unlock()
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

    func cameraController(
        _ controller: CameraController,
        didOutput pixelBuffer: CVPixelBuffer,
        at timestamp: CMTime
    ) {
        guard let motionTime = frameClockMapper.motionTime(for: timestamp) else { return }
        let transform = trajectoryTransform(at: motionTime)
        let viewportSize = currentViewportSize
        applyPreviewTransform(transform, at: motionTime)
        updateMotionCropCorrection(
            PreviewVisualCorrection(
                normalizedX: viewportSize.width > 1 ? transform.translationX / viewportSize.width : 0,
                normalizedY: viewportSize.height > 1 ? transform.translationY / viewportSize.height : 0,
                confidence: transform == .identity ? 0 : 1,
                timestamp: motionTime
            )
        )
        renderer.enqueue(pixelBuffer: pixelBuffer, motionTime: motionTime)
        visualAnalyzer.enqueue(pixelBuffer: pixelBuffer, motionTime: motionTime)
        updateOverviewThumbnailIfNeeded(pixelBuffer: pixelBuffer, motionTime: motionTime)
    }

    private func trajectoryTransform(at motionTime: TimeInterval) -> PreviewRenderTransform {
        preferenceLock.lock()
        let preference = stabilizationPreference
        preferenceLock.unlock()

        guard preference.usesElectronicPreviewStabilization,
              let motionMonitor
        else {
            trajectoryLock.lock()
            trajectoryStabilizer.reset()
            trajectoryLock.unlock()
            return .identity
        }

        let sampleWindow = motionMonitor.latestSampleWindow(duration: 0.18)
        let trajectoryTime = sampleWindow?.timestamp ?? motionTime
        let samples = sampleWindow?.samples ?? motionMonitor.samples(from: motionTime - 0.18, to: motionTime)
        trajectoryLock.lock()
        let transform = trajectoryStabilizer.transform(
            at: trajectoryTime,
            samples: samples,
            preference: preference,
            viewportSize: currentViewportSize
        )
        trajectoryLock.unlock()
        return transform
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
        cropWindowView.layer.borderWidth = 2
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

    private func layoutOverview() {
        let width = min(max(bounds.width * 0.28, 92), 128)
        let height = width * 1.34
        let topInset = max(bounds.height * 0.08, 44)
        overviewContainer.frame = CGRect(
            x: bounds.maxX - width - 18,
            y: topInset,
            width: width,
            height: height
        )
        overviewImageView.frame = overviewContainer.bounds
        layoutCropWindow(correction: combinedCropCorrection())
    }

    private func applyVisualCropCorrection(_ correction: PreviewVisualCorrection) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if correction == .identity {
                self.cropTrajectory.reset()
                self.latestCropCorrection = .identity
                self.renderer.setVisualCorrection(.identity)
                self.layoutCropWindow(correction: self.combinedCropCorrection())
                return
            }

            self.preferenceLock.lock()
            let preference = self.stabilizationPreference
            self.preferenceLock.unlock()

            let filteredCorrection = self.cropTrajectory.update(
                target: correction,
                preference: preference
            )
            self.latestCropCorrection = filteredCorrection
            self.renderer.setVisualCorrection(filteredCorrection)
            self.layoutCropWindow(correction: self.combinedCropCorrection())
        }
    }

    fileprivate func updateMotionCropCorrection(_ correction: PreviewVisualCorrection) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.latestMotionCorrection = correction
            self.layoutCropWindow(correction: self.combinedCropCorrection())
        }
    }

    private func combinedCropCorrection() -> PreviewVisualCorrection {
        PreviewVisualCorrection(
            normalizedX: latestCropCorrection.normalizedX + latestMotionCorrection.normalizedX,
            normalizedY: latestCropCorrection.normalizedY + latestMotionCorrection.normalizedY,
            confidence: max(latestCropCorrection.confidence, latestMotionCorrection.confidence),
            timestamp: max(latestCropCorrection.timestamp, latestMotionCorrection.timestamp)
        )
    }

    private func layoutCropWindow(correction: PreviewVisualCorrection) {
        preferenceLock.lock()
        let preference = stabilizationPreference
        preferenceLock.unlock()

        guard preference.usesCropWindowStabilization else {
            cropWindowView.frame = .zero
            return
        }

        let imageRect = AVMakeRect(
            aspectRatio: CGSize(width: max(overviewImageAspectRatio, 0.1), height: 1),
            insideRect: overviewContainer.bounds
        )
        guard imageRect.width > 2, imageRect.height > 2 else { return }

        let cropScale = max(preference.previewCropScale, 1.0001)
        let cropWidth = imageRect.width / cropScale
        let cropHeight = imageRect.height / cropScale
        let halfWidth = cropWidth * 0.5
        let halfHeight = cropHeight * 0.5
        let centerX = clamp(
            imageRect.midX - correction.normalizedX * imageRect.width,
            min: imageRect.minX + halfWidth,
            max: imageRect.maxX - halfWidth
        )
        let centerY = clamp(
            imageRect.midY + correction.normalizedY * imageRect.height,
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
        preferenceLock.lock()
        let shouldUpdate = stabilizationPreference.usesCropWindowStabilization
        preferenceLock.unlock()
        guard shouldUpdate,
              motionTime.isFinite,
              motionTime - lastOverviewUpdateTime >= 0.2
        else {
            return
        }
        lastOverviewUpdateTime = motionTime

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let targetWidth: CGFloat = 160
        let scale = targetWidth / max(image.extent.width, 1)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let targetRect = CGRect(
            x: 0,
            y: 0,
            width: image.extent.width * scale,
            height: image.extent.height * scale
        )
        guard let cgImage = overviewCIContext.createCGImage(scaled, from: targetRect) else { return }
        let thumbnail = UIImage(cgImage: cgImage)
        let aspectRatio = image.extent.width / max(image.extent.height, 1)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.overviewImageAspectRatio = aspectRatio
            self.overviewImageView.image = thumbnail
            self.layoutCropWindow(correction: self.combinedCropCorrection())
        }
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
    }

    private struct TimedRenderTransform {
        var transform: PreviewRenderTransform
        var timestamp: TimeInterval
    }

    private let commandQueue: MTLCommandQueue
    private let ciContext: CIContext
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let recorder = StabilizedPreviewRecorder()
    private let stateLock = NSLock()

    private var frameQueue: [QueuedPreviewFrame] = []
    private var correctionHistory: [PreviewVisualCorrection] = [.identity]
    private var renderTransformHistory: [TimedRenderTransform] = [
        TimedRenderTransform(transform: .identity, timestamp: 0)
    ]
    private var previewDelayFrames = 0
    private var cropWindowScale: CGFloat = 1

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

    func enqueue(pixelBuffer: CVPixelBuffer, motionTime: TimeInterval) {
        guard motionTime.isFinite else { return }

        stateLock.lock()
        frameQueue.append(
            QueuedPreviewFrame(
                pixelBuffer: pixelBuffer,
                motionTime: motionTime
            )
        )
        let maximumFrameCount = max(previewDelayFrames + 8, 12)
        if frameQueue.count > maximumFrameCount {
            frameQueue.removeFirst(frameQueue.count - maximumFrameCount)
        }
        stateLock.unlock()
    }

    func setRenderTransform(_ transform: PreviewRenderTransform, at timestamp: TimeInterval) {
        stateLock.lock()
        let resolvedTimestamp = timestamp.isFinite ? timestamp : CACurrentMediaTime()
        renderTransformHistory.append(
            TimedRenderTransform(transform: transform, timestamp: resolvedTimestamp)
        )
        if renderTransformHistory.count > 180 {
            renderTransformHistory.removeFirst(renderTransformHistory.count - 180)
        }
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

    func setCropWindowScale(_ scale: CGFloat) {
        stateLock.lock()
        cropWindowScale = max(1, min(scale, 1.60))
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

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        stateLock.lock()
        let queuedFrame = nextFrameForDisplay()
        let transform = queuedFrame.map { renderTransformForFrame(at: $0.motionTime) } ?? .identity
        let correction = queuedFrame.map { correctionForFrame(at: $0.motionTime) } ?? .identity
        let cropScale = cropWindowScale
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
                visualCorrection: correction,
                cropWindowScale: cropScale
            )
        )

        recorder.append(
            stabilizedImage: fitted,
            timestamp: queuedFrame.motionTime,
            outputSize: drawableSize,
            ciContext: ciContext,
            colorSpace: colorSpace
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
                rotationRadians: previous.transform.rotationRadians + (next.transform.rotationRadians - previous.transform.rotationRadians) * amount,
                translationX: previous.transform.translationX + (next.transform.translationX - previous.transform.translationX) * amount,
                translationY: previous.transform.translationY + (next.transform.translationY - previous.transform.translationY) * amount
            )
        } else {
            selected = previous.transform
        }

        if previousIndex > 4 {
            renderTransformHistory.removeFirst(previousIndex - 3)
        }

        return selected
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
        visualCorrection: PreviewVisualCorrection,
        cropWindowScale: CGFloat
    ) -> CGAffineTransform {
        let imageWidth = max(imageExtent.width, 1)
        let imageHeight = max(imageExtent.height, 1)
        let baseScale = max(drawableSize.width / imageWidth, drawableSize.height / imageHeight)
        let stabilizedScale = baseScale * max(previewTransform.scale, cropWindowScale)
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
    private var lastPresentationTime: CMTime?
    private var writtenFrameCount: Int64 = 0
    private var recordingFrameRate = 60
    private var outputWidth = 0
    private var outputHeight = 0
    private var targetFrameRate = 60
    private var pendingAppendCount = 0

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
        recordingFrameRate = targetFrameRate
        pendingAppendCount = 0
        state = .waitingForFirstFrame
        lock.unlock()
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

    func append(
        stabilizedImage: CIImage,
        timestamp: TimeInterval,
        outputSize: CGSize,
        ciContext: CIContext,
        colorSpace: CGColorSpace
    ) {
        lock.lock()
        guard state == .waitingForFirstFrame || state == .recording,
              timestamp.isFinite,
              pendingAppendCount < 3
        else {
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
                timestamp: timestamp,
                outputSize: outputSize,
                ciContext: ciContext,
                colorSpace: colorSpace
            )
        }
    }

    private func appendOnRecordingQueue(
        stabilizedImage: CIImage,
        timestamp: TimeInterval,
        outputSize: CGSize,
        ciContext: CIContext,
        colorSpace: CGColorSpace
    ) {
        lock.lock()
        guard state == .waitingForFirstFrame || state == .recording,
              timestamp.isFinite
        else {
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
              let pixelBufferPool = adaptor.pixelBufferPool,
              input.isReadyForMoreMediaData
        else {
            lock.unlock()
            return
        }

        guard writer.status == .writing else {
            let error = writer.error ?? StabilizedPreviewRecorderError.writerFailed
            finishLocked(result: .failure(error))
            return
        }
        let currentOutputWidth = outputWidth
        let currentOutputHeight = outputHeight
        lock.unlock()

        var pixelBuffer: CVPixelBuffer?
        let createResult = CVPixelBufferPoolCreatePixelBuffer(
            nil,
            pixelBufferPool,
            &pixelBuffer
        )
        guard createResult == kCVReturnSuccess, let pixelBuffer else {
            lock.lock()
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
            bounds: CGRect(
                x: 0,
                y: 0,
                width: currentOutputWidth,
                height: currentOutputHeight
            ),
            colorSpace: colorSpace
        )

        lock.lock()
        guard state == .recording,
              writer.status == .writing
        else {
            lock.unlock()
            return
        }

        let presentationTime = CMTime(
            value: CMTimeValue(writtenFrameCount),
            timescale: CMTimeScale(max(recordingFrameRate, 1))
        )
        if let lastPresentationTime,
           CMTimeCompare(presentationTime, lastPresentationTime) <= 0 {
            lock.unlock()
            return
        }

        if !adaptor.append(pixelBuffer, withPresentationTime: presentationTime) {
            let error = writer.error ?? StabilizedPreviewRecorderError.appendFailed
            finishLocked(result: .failure(error))
            return
        }
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
        let bitrate = min(max(outputWidth * outputHeight * expectedFrameRate / 12, 4_000_000), 12_000_000)
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
        lastPresentationTime = nil
        state = .recording
    }

    private func compatibleRecordingSize(for drawableSize: CGSize) -> (width: Int, height: Int) {
        let sourceWidth = max(drawableSize.width, 1)
        let sourceHeight = max(drawableSize.height, 1)
        let maxWidth: CGFloat = 1080
        let maxHeight: CGFloat = 1920
        let scale = min(maxWidth / sourceWidth, maxHeight / sourceHeight, 1)
        let width = compatibleVideoDimension(sourceWidth * scale)
        let height = compatibleVideoDimension(sourceHeight * scale)
        return (width, height)
    }

    private func compatibleVideoDimension(_ value: CGFloat) -> Int {
        let rounded = max(16, Int(value.rounded(.down)))
        return max(16, rounded - (rounded % 16))
    }

    private func finishWriterLocked() {
        guard let writer,
              let input,
              let outputURL
        else {
            finishLocked(result: .failure(StabilizedPreviewRecorderError.writerMissing))
            return
        }

        state = .finishing
        input.markAsFinished()
        let completion = self.completion
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

private final class PreviewFrameMotionAnalyzer {
    var onCorrection: ((PreviewVisualCorrection) -> Void)?

    private struct VisualShift {
        var dx: CGFloat
        var dy: CGFloat
        var confidence: CGFloat
    }

    private struct AnalysisFrame {
        var luma: [UInt8]
        var roiMask: [Bool]
    }

    private struct PatchVector {
        var dx: CGFloat
        var dy: CGFloat
        var confidence: CGFloat
    }

    private let queue = DispatchQueue(label: "com.puroo.scope.preview.visualLock", qos: .userInteractive)
    private let busyLock = NSLock()
    private let gridSize = 88
    private let searchRadius = 5
    private let patchRadius = 3
    private let anchorStride = 8
    private var isBusy = false
    private var preference: StabilizationPreference = .off
    private var lastFrame: AnalysisFrame?
    private var lastFrameTimestamp: TimeInterval?
    private var lastAnalysisTimestamp: TimeInterval?
    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    private var correction = PreviewVisualCorrection.identity
    private var recentShifts: [VisualShift] = []

    func setPreference(_ nextPreference: StabilizationPreference) {
        queue.async { [weak self] in
            guard let self, self.preference != nextPreference else { return }
            self.preference = nextPreference
            self.resetAnalysisState()
            self.emit(.identity)
        }
    }

    func enqueue(pixelBuffer: CVPixelBuffer, motionTime: TimeInterval) {
        guard motionTime.isFinite else { return }

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
            self.process(pixelBuffer: retainedPixelBuffer, timestamp: motionTime)
        }
    }

    private func process(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) {
        guard preference.usesCropWindowStabilization,
              preference.visualAnalysisMinimumInterval.isFinite
        else {
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
            recentShifts.removeAll(keepingCapacity: true)
            emit(correction)
            return
        }

        let dt = min(max(elapsed, 1.0 / 120.0), 1.0 / 8.0)
        guard let shift = estimateShift(reference: previousFrame, current: currentFrame) else {
            recentShifts.removeAll(keepingCapacity: true)
            decayCorrection(deltaTime: dt, timestamp: timestamp)
            return
        }

        apply(shift: deadzoned(filteredShift(shift)), deltaTime: dt, timestamp: timestamp)
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
        let targetX = clamp(
            -accumulatedX / CGFloat(gridSize) * gain,
            min: -maximumOffset,
            max: maximumOffset
        )
        let targetY = clamp(
            -accumulatedY / CGFloat(gridSize) * gain,
            min: -maximumOffset,
            max: maximumOffset
        )
        let response = CGFloat(1 - exp(-deltaTime * preference.visualHighPassResponseRate))
        let stepLimit = correctionStepLimit(deltaTime: deltaTime)
        let nextX = limitedCorrection(
            current: correction.normalizedX,
            target: targetX,
            response: response,
            maximumStep: stepLimit
        )
        let nextY = limitedCorrection(
            current: correction.normalizedY,
            target: targetY,
            response: response,
            maximumStep: stepLimit
        )

        correction = PreviewVisualCorrection(
            normalizedX: nextX,
            normalizedY: nextY,
            confidence: shift.confidence,
            timestamp: timestamp
        )
        emit(correction)
    }

    private func deadzoned(_ shift: VisualShift) -> VisualShift {
        let magnitude = (shift.dx * shift.dx + shift.dy * shift.dy).squareRoot()
        let deadZone = preference.visualShiftDeadZone
        guard magnitude > deadZone else {
            return VisualShift(dx: 0, dy: 0, confidence: shift.confidence * 0.35)
        }

        let scale = (magnitude - deadZone) / magnitude
        return VisualShift(
            dx: shift.dx * scale,
            dy: shift.dy * scale,
            confidence: shift.confidence
        )
    }

    private func microJitterGate(for shift: VisualShift) -> CGFloat {
        let magnitude = (shift.dx * shift.dx + shift.dy * shift.dy).squareRoot()
        let smallMotion = clamp((CGFloat(3.1) - magnitude) / 2.4, min: 0, max: 1)
        let confidence = clamp((shift.confidence - 0.20) / 0.38, min: 0, max: 1)
        return smallMotion * confidence
    }

    private func decayCorrection(deltaTime: TimeInterval, timestamp: TimeInterval) {
        let leak = CGFloat(exp(-deltaTime * preference.visualHighPassLeakRate))
        accumulatedX *= leak
        accumulatedY *= leak

        let targetX = -accumulatedX / CGFloat(gridSize) * preference.visualHighPassCorrectionGain
        let targetY = -accumulatedY / CGFloat(gridSize) * preference.visualHighPassCorrectionGain
        let response = CGFloat(1 - exp(-deltaTime * preference.visualHighPassResponseRate))
        let stepLimit = correctionStepLimit(deltaTime: deltaTime)
        let nextX = limitedCorrection(
            current: correction.normalizedX,
            target: targetX,
            response: response,
            maximumStep: stepLimit
        )
        let nextY = limitedCorrection(
            current: correction.normalizedY,
            target: targetY,
            response: response,
            maximumStep: stepLimit
        )

        correction = PreviewVisualCorrection(
            normalizedX: nextX,
            normalizedY: nextY,
            confidence: max(0, correction.confidence * leak),
            timestamp: timestamp
        )
        emit(correction)
    }

    private func correctionStepLimit(deltaTime: TimeInterval) -> CGFloat {
        let scale = clamp(CGFloat(deltaTime / (1.0 / 60.0)), min: 0.5, max: 8.0)
        return preference.visualCorrectionMaximumStep * scale
    }

    private func limitedCorrection(
        current: CGFloat,
        target: CGFloat,
        response: CGFloat,
        maximumStep: CGFloat
    ) -> CGFloat {
        let requestedStep = (target - current) * response
        return current + clamp(requestedStep, min: -maximumStep, max: maximumStep)
    }

    private func filteredShift(_ shift: VisualShift) -> VisualShift {
        recentShifts.append(shift)
        let historyLimit = visualShiftHistoryLimit
        if recentShifts.count > historyLimit {
            recentShifts.removeFirst(recentShifts.count - historyLimit)
        }
        guard recentShifts.count >= visualShiftMedianSampleCount else { return shift }

        let medianDx = median(recentShifts.map(\.dx))
        let medianDy = median(recentShifts.map(\.dy))
        let deviationX = shift.dx - medianDx
        let deviationY = shift.dy - medianDy
        let deviation = (deviationX * deviationX + deviationY * deviationY).squareRoot()
        if preference == .strong {
            return VisualShift(
                dx: medianDx,
                dy: medianDy,
                confidence: min(shift.confidence, median(recentShifts.map(\.confidence)) * 0.72)
            )
        }

        guard deviation > visualShiftMedianDeviationLimit else { return shift }

        return VisualShift(
            dx: medianDx,
            dy: medianDy,
            confidence: min(shift.confidence, median(recentShifts.map(\.confidence)) * 0.85)
        )
    }

    private func estimateShift(reference: AnalysisFrame, current: AnalysisFrame) -> VisualShift? {
        let texture = textureScore(reference)
        guard texture > 2.0 else { return nil }

        let vectors = patchVectors(reference: reference, current: current)
        guard vectors.count >= 5 else { return nil }

        let medianDx = median(vectors.map(\.dx))
        let medianDy = median(vectors.map(\.dy))
        let inlierRadius = visualShiftInlierRadius
        let inliers = vectors.filter { vector in
            let residualX = vector.dx - medianDx
            let residualY = vector.dy - medianDy
            return (residualX * residualX + residualY * residualY).squareRoot() <= inlierRadius
        }
        let minimumInliers = max(5, Int((CGFloat(vectors.count) * visualShiftMinimumInlierRatio).rounded(.up)))
        guard inliers.count >= minimumInliers else { return nil }

        let totalWeight = max(inliers.reduce(CGFloat(0)) { $0 + $1.confidence }, 0.0001)
        let dx = inliers.reduce(CGFloat(0)) { $0 + $1.dx * $1.confidence } / totalWeight
        let dy = inliers.reduce(CGFloat(0)) { $0 + $1.dy * $1.confidence } / totalWeight
        let meanResidual = inliers.reduce(CGFloat(0)) { partial, vector in
            let residualX = vector.dx - dx
            let residualY = vector.dy - dy
            return partial + (residualX * residualX + residualY * residualY).squareRoot()
        } / CGFloat(max(inliers.count, 1))
        guard meanResidual <= visualShiftMaximumMeanResidual else { return nil }

        let textureConfidence = clamp((texture - 2.0) / 8.0, min: 0, max: 1)
        let matchConfidence = clamp(totalWeight / CGFloat(max(inliers.count, 1)), min: 0, max: 1)
        let coverageConfidence = clamp(CGFloat(inliers.count) / CGFloat(max(vectors.count, 1)), min: 0, max: 1)
        let consistencyConfidence = clamp((1.6 - meanResidual) / 1.6, min: 0, max: 1)
        let confidence = clamp(
            textureConfidence * 0.22 +
            matchConfidence * 0.34 +
            coverageConfidence * 0.22 +
            consistencyConfidence * 0.22,
            min: 0,
            max: 1
        )

        guard confidence > 0.24 else { return nil }
        return VisualShift(dx: dx, dy: dy, confidence: confidence)
    }

    private func patchVectors(reference: AnalysisFrame, current: AnalysisFrame) -> [PatchVector] {
        let margin = searchRadius + patchRadius + 2
        let start = margin
        let end = gridSize - margin
        var vectors: [PatchVector] = []
        vectors.reserveCapacity(48)

        for y in stride(from: start, to: end, by: anchorStride) {
            for x in stride(from: start, to: end, by: anchorStride) {
                let index = y * gridSize + x
                guard reference.roiMask[index],
                      current.roiMask[index],
                      patchTexture(reference, centerX: x, centerY: y) > 2.0,
                      let vector = bestPatchVector(reference: reference, current: current, centerX: x, centerY: y)
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
        var bestScore = CGFloat.greatestFiniteMagnitude
        var secondScore = CGFloat.greatestFiniteMagnitude
        var bestDx = 0
        var bestDy = 0

        for dy in -searchRadius...searchRadius {
            for dx in -searchRadius...searchRadius {
                guard let score = patchMatchScore(
                    reference: reference,
                    current: current,
                    centerX: centerX,
                    centerY: centerY,
                    dx: dx,
                    dy: dy
                ) else {
                    continue
                }

                if score < bestScore {
                    secondScore = bestScore
                    bestScore = score
                    bestDx = dx
                    bestDy = dy
                } else if score < secondScore {
                    secondScore = score
                }
            }
        }

        guard bestScore.isFinite, bestScore < 33 else { return nil }

        let uniqueness: CGFloat
        if secondScore.isFinite {
            uniqueness = clamp((secondScore - bestScore) / max(bestScore, 1), min: 0, max: 1)
        } else {
            uniqueness = 0
        }
        let matchConfidence = clamp((33 - bestScore) / 25, min: 0, max: 1)
        let confidence = clamp(matchConfidence * 0.78 + uniqueness * 0.22, min: 0, max: 1)
        guard confidence > 0.20 else { return nil }

        return PatchVector(
            dx: CGFloat(bestDx),
            dy: CGFloat(bestDy),
            confidence: confidence
        )
    }

    private func patchMatchScore(
        reference: AnalysisFrame,
        current: AnalysisFrame,
        centerX: Int,
        centerY: Int,
        dx: Int,
        dy: Int
    ) -> CGFloat? {
        var sad = 0
        var count = 0

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

                let delta = Int(reference.luma[referenceIndex]) - Int(current.luma[currentIndex])
                sad += delta < 0 ? -delta : delta
                count += 1
            }
        }

        guard count >= 28 else { return nil }
        return CGFloat(sad) / CGFloat(count)
    }

    private func makeLumaGrid(from pixelBuffer: CVPixelBuffer) -> AnalysisFrame? {
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
        let cropSide = CGFloat(min(width, height)) * 0.84
        let cropX = (CGFloat(width) - cropSide) * 0.5
        let cropY = (CGFloat(height) - cropSide) * 0.5
        let step = cropSide / CGFloat(gridSize)
        var luma = Array(repeating: UInt8(0), count: gridSize * gridSize)
        var roiMask = Array(repeating: false, count: gridSize * gridSize)
        let center = (CGFloat(gridSize) - 1) * 0.5
        let radius = CGFloat(gridSize) * 0.41
        let radiusSquared = radius * radius

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
                let index = y * gridSize + x
                luma[index] = UInt8((77 * red + 150 * green + 29 * blue) >> 8)

                let centeredX = CGFloat(x) - center
                let centeredY = CGFloat(y) - center
                roiMask[index] = centeredX * centeredX + centeredY * centeredY <= radiusSquared
            }
        }

        return AnalysisFrame(luma: luma, roiMask: roiMask)
    }

    private func textureScore(_ frame: AnalysisFrame) -> CGFloat {
        var total = 0
        var count = 0
        for y in 1..<(gridSize - 1) {
            let row = y * gridSize
            let nextRow = (y + 1) * gridSize
            for x in 1..<(gridSize - 1) {
                let index = row + x
                guard frame.roiMask[index],
                      frame.roiMask[index + 1],
                      frame.roiMask[nextRow + x]
                else {
                    continue
                }
                total += abs(Int(frame.luma[index]) - Int(frame.luma[index + 1]))
                total += abs(Int(frame.luma[index]) - Int(frame.luma[nextRow + x]))
                count += 2
            }
        }
        return CGFloat(total) / CGFloat(max(count, 1))
    }

    private func patchTexture(_ frame: AnalysisFrame, centerX: Int, centerY: Int) -> CGFloat {
        var total = 0
        var count = 0

        for patchY in -patchRadius..<patchRadius {
            let y = centerY + patchY
            let row = y * gridSize
            let nextRow = (y + 1) * gridSize
            for patchX in -patchRadius..<patchRadius {
                let x = centerX + patchX
                let index = row + x
                guard frame.roiMask[index],
                      frame.roiMask[index + 1],
                      frame.roiMask[nextRow + x]
                else {
                    continue
                }

                total += abs(Int(frame.luma[index]) - Int(frame.luma[index + 1]))
                total += abs(Int(frame.luma[index]) - Int(frame.luma[nextRow + x]))
                count += 2
            }
        }

        return CGFloat(total) / CGFloat(max(count, 1))
    }

    private var visualShiftInlierRadius: CGFloat {
        switch preference {
        case .strong:
            return 0.72
        case .balanced:
            return 1.20
        case .auto:
            return 1.10
        case .off:
            return 1.45
        }
    }

    private var visualShiftMinimumInlierRatio: CGFloat {
        switch preference {
        case .strong:
            return 0.66
        case .balanced:
            return 0.50
        case .auto:
            return 0.54
        case .off:
            return 0.34
        }
    }

    private var visualShiftMaximumMeanResidual: CGFloat {
        switch preference {
        case .strong:
            return 0.58
        case .balanced:
            return 0.95
        case .auto:
            return 0.82
        case .off:
            return 1.6
        }
    }

    private var visualShiftMedianDeviationLimit: CGFloat {
        switch preference {
        case .strong:
            return 0.42
        case .balanced:
            return 1.4
        case .auto:
            return 0.9
        case .off:
            return .greatestFiniteMagnitude
        }
    }

    private var visualShiftHistoryLimit: Int {
        switch preference {
        case .strong:
            return 9
        case .balanced, .auto:
            return 3
        case .off:
            return 1
        }
    }

    private var visualShiftMedianSampleCount: Int {
        switch preference {
        case .strong:
            return 5
        case .balanced, .auto:
            return 3
        case .off:
            return 1
        }
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

    private func resetAnalysisState() {
        lastFrame = nil
        lastFrameTimestamp = nil
        lastAnalysisTimestamp = nil
        accumulatedX = 0
        accumulatedY = 0
        correction = .identity
        recentShifts.removeAll(keepingCapacity: true)
    }

    private func emit(_ correction: PreviewVisualCorrection) {
        let sign = preference.visualCorrectionSign
        guard sign != 0 else {
            onCorrection?(.identity)
            return
        }

        onCorrection?(
            PreviewVisualCorrection(
                normalizedX: correction.normalizedX * sign,
                normalizedY: correction.normalizedY * sign,
                confidence: correction.confidence,
                timestamp: correction.timestamp
            )
        )
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
        uiView.updateMotionMonitor(nil)
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
        private var renderedX: CGFloat = 0
        private var renderedY: CGFloat = 0
        private var microPitch: Double = 0
        private var microRoll: Double = 0
        private var microYaw: Double = 0
        private var microPitchBaseline: Double = 0
        private var microRollBaseline: Double = 0
        private var microYawBaseline: Double = 0
        private var lastOverlayTimestamp: TimeInterval = 0
        private let stateLock = NSLock()
        private weak var camera: CameraController?
        private weak var motionMonitor: MotionStabilityMonitor?
        private var motionObserverID: UUID?
        private var latestPreference: StabilizationPreference = .balanced
        private var latestVisualState: PreviewStabilizationState = .identity

        private struct GyroAxisCorrection {
            var targetX: CGFloat
            var targetY: CGFloat
            var velocityX: CGFloat
            var velocityY: CGFloat
            var microX: CGFloat
            var microY: CGFloat
        }

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

            if let motionObserverID, self.motionMonitor !== motionMonitor {
                self.motionMonitor?.removeSampleObserver(motionObserverID)
                self.motionObserverID = nil
            }
            self.motionMonitor = motionMonitor
            view.updateMotionMonitor(motionMonitor)
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
                renderedX = 0
                renderedY = 0
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
            let travelFactor = preference.previewCropTravelFactor
            let maxX = max(12, viewportSize.width * (scale - 1) * travelFactor)
            let maxY = max(12, viewportSize.height * (scale - 1) * travelFactor)
            let visualGain = preference.visualStabilizationGain
            let velocityLeadGain = preference.gyroVelocityLeadGain
            let velocityFloor = preference.gyroVelocityNoiseFloor
            updateMicroJitterIntegrator(sample: sample, preference: preference, deltaTime: dt)
            let microAngleLimit = preference.gyroMicroJitterAngleLimit
            let microPitchDelta = clamp(CGFloat(microPitch - microPitchBaseline), min: -microAngleLimit, max: microAngleLimit)
            let microYawDelta = clamp(CGFloat(microYaw - microYawBaseline), min: -microAngleLimit, max: microAngleLimit)
            let microRollDelta = clamp(CGFloat(microRoll - microRollBaseline), min: -microAngleLimit, max: microAngleLimit)

            let axisCorrection = gyroAxisCorrection(
                preference: preference,
                pitchDelta: pitchDelta,
                yawDelta: yawDelta,
                rotationX: sample.rotationX,
                rotationY: sample.rotationY,
                microPitchDelta: microPitchDelta,
                microYawDelta: microYawDelta,
                gain: gain,
                velocityLeadGain: velocityLeadGain,
                velocityFloor: velocityFloor,
                microGain: preference.gyroMicroJitterGain
            )
            var targetX = axisCorrection.targetX
            var targetY = axisCorrection.targetY
            let targetRoll = -rollDelta * 0.45
            let velocityX = axisCorrection.velocityX
            let velocityY = axisCorrection.velocityY
            let velocityRoll = -deadzone(sample.rotationZ, floor: velocityFloor) * preference.rollVelocityLeadGain

            targetX += axisCorrection.microX
            targetY += axisCorrection.microY
            let microRollTarget = -microRollDelta * preference.gyroMicroRollGain

            targetX += visualState.normalizedX * viewportSize.width * visualGain
            targetY += visualState.normalizedY * viewportSize.height * visualGain

            targetX = clamp(targetX, min: -maxX, max: maxX)
            targetY = clamp(targetY, min: -maxY, max: maxY)

            let rollLimit: CGFloat
            switch preference {
            case .strong:
                rollLimit = .pi / 30
            case .balanced:
                rollLimit = .pi / 30
            case .off, .auto:
                rollLimit = .pi / 58
            }
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

            let requestedFinalX = clamp(smoothedX + leadX, min: -maxX, max: maxX)
            let requestedFinalY = clamp(smoothedY + leadY, min: -maxY, max: maxY)
            let limitedTranslation = rateLimitedTranslation(
                requestedX: requestedFinalX,
                requestedY: requestedFinalY,
                preference: preference,
                viewportSize: viewportSize,
                deltaTime: dt,
                maxX: maxX,
                maxY: maxY
            )
            let finalX = limitedTranslation.x
            let finalY = limitedTranslation.y
            let finalRoll = clamp(smoothedRoll + leadRoll, min: -rollLimit, max: rollLimit)
            updateCropOverlayIfNeeded(
                view: view,
                preference: preference,
                timestamp: timestamp,
                translationX: finalX,
                translationY: finalY,
                viewportSize: viewportSize
            )

            view.applyPreviewTransform(
                PreviewRenderTransform(
                    scale: scale,
                    rotationRadians: finalRoll,
                    translationX: finalX,
                    translationY: finalY
                ),
                at: timestamp
            )
        }

        private func gyroAxisCorrection(
            preference: StabilizationPreference,
            pitchDelta: CGFloat,
            yawDelta: CGFloat,
            rotationX: Double,
            rotationY: Double,
            microPitchDelta: CGFloat,
            microYawDelta: CGFloat,
            gain: CGFloat,
            velocityLeadGain: CGFloat,
            velocityFloor: Double,
            microGain: CGFloat
        ) -> GyroAxisCorrection {
            switch preference {
            case .auto:
                return GyroAxisCorrection(
                    targetX: pitchDelta * gain,
                    targetY: -yawDelta * gain,
                    velocityX: deadzone(rotationX, floor: velocityFloor) * velocityLeadGain,
                    velocityY: -deadzone(rotationY, floor: velocityFloor) * velocityLeadGain,
                    microX: microPitchDelta * microGain,
                    microY: -microYawDelta * microGain
                )
            case .balanced:
                return GyroAxisCorrection(
                    targetX: yawDelta * gain,
                    targetY: -pitchDelta * gain,
                    velocityX: deadzone(rotationY, floor: velocityFloor) * velocityLeadGain,
                    velocityY: -deadzone(rotationX, floor: velocityFloor) * velocityLeadGain,
                    microX: microYawDelta * microGain,
                    microY: -microPitchDelta * microGain
                )
            case .strong:
                return GyroAxisCorrection(
                    targetX: -yawDelta * gain,
                    targetY: pitchDelta * gain,
                    velocityX: -deadzone(rotationY, floor: velocityFloor) * velocityLeadGain,
                    velocityY: deadzone(rotationX, floor: velocityFloor) * velocityLeadGain,
                    microX: -microYawDelta * microGain,
                    microY: microPitchDelta * microGain
                )
            case .off:
                return GyroAxisCorrection(
                    targetX: 0,
                    targetY: 0,
                    velocityX: 0,
                    velocityY: 0,
                    microX: 0,
                    microY: 0
                )
            }
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
            renderedX = 0
            renderedY = 0
            lastOverlayTimestamp = 0
            resetMicroJitterIntegrator()
            view.updateMotionCropCorrection(.identity)
            view.applyPreviewTransform(.identity, at: CACurrentMediaTime())
        }

        private func updateCropOverlayIfNeeded(
            view: PreviewContainerView,
            preference: StabilizationPreference,
            timestamp: TimeInterval,
            translationX: CGFloat,
            translationY: CGFloat,
            viewportSize: CGSize
        ) {
            guard preference.usesCropWindowStabilization,
                  viewportSize.width > 1,
                  viewportSize.height > 1
            else {
                return
            }

            let overlayInterval = 1.0 / 60.0
            guard lastOverlayTimestamp == 0 || timestamp - lastOverlayTimestamp >= overlayInterval else {
                return
            }

            lastOverlayTimestamp = timestamp
            view.updateMotionCropCorrection(
                PreviewVisualCorrection(
                    normalizedX: translationX / viewportSize.width,
                    normalizedY: translationY / viewportSize.height,
                    confidence: 1,
                    timestamp: timestamp
                )
            )
        }

        private func rateLimitedTranslation(
            requestedX: CGFloat,
            requestedY: CGFloat,
            preference: StabilizationPreference,
            viewportSize: CGSize,
            deltaTime: TimeInterval,
            maxX: CGFloat,
            maxY: CGFloat
        ) -> CGPoint {
            let limitFraction = preference.previewTranslationStepLimitFraction
            guard limitFraction > 0 else {
                renderedX = requestedX
                renderedY = requestedY
                return CGPoint(x: requestedX, y: requestedY)
            }

            let frameScale = CGFloat(deltaTime / (1.0 / 60.0))
            let maxStep = max(1, min(viewportSize.width, viewportSize.height) * limitFraction * frameScale)
            renderedX += clamp(requestedX - renderedX, min: -maxStep, max: maxStep)
            renderedY += clamp(requestedY - renderedY, min: -maxStep, max: maxStep)
            renderedX = clamp(renderedX, min: -maxX, max: maxX)
            renderedY = clamp(renderedY, min: -maxY, max: maxY)
            return CGPoint(x: renderedX, y: renderedY)
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
