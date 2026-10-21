import AVFoundation
import AudioToolbox
import Combine
import Photos
import simd
import UIKit

private enum CameraFeedbackSound {
    static func playFocus() {
        play(systemSoundID: 1104, hapticStyle: .light)
    }

    static func playShutter() {
        play(systemSoundID: 1108, hapticStyle: .medium)
    }

    private static func play(
        systemSoundID: SystemSoundID,
        hapticStyle: UIImpactFeedbackGenerator.FeedbackStyle
    ) {
        DispatchQueue.main.async {
            AudioServicesPlaySystemSound(systemSoundID)
            let generator = UIImpactFeedbackGenerator(style: hapticStyle)
            generator.prepare()
            generator.impactOccurred()
        }
    }
}

struct CameraFrameMetadata {
    var presentationTime: CMTime
    var exposureDuration: TimeInterval
    var videoRotationAngle: CGFloat
    var focalLengthPixelsX: CGFloat
    var focalLengthPixelsY: CGFloat
    var frameWidth: Int
    var frameHeight: Int
    var callbackTime: TimeInterval
    var iso: Float
    var exposureTargetOffset: Float
    var activeSystemStabilization: Int
    var maximumExposureDuration: Double
}

protocol CameraFrameSink: AnyObject {
    func receiveAudio(_ sampleBuffer: CMSampleBuffer)
    func resetPreview()
    func sourceFocusPoint(from point: CGPoint) -> CGPoint?
    func cameraController(
        _ controller: CameraController,
        didOutput pixelBuffer: CVPixelBuffer,
        metadata: CameraFrameMetadata
    )

    func cameraController(
        _ controller: CameraController,
        didUpdateTargetFrameRate frameRate: Int
    )
}

extension CameraFrameSink {
    func cameraController(
        _ controller: CameraController,
        didUpdateTargetFrameRate frameRate: Int
    ) {}
}

protocol StabilizedRecordingFrameSink: AnyObject {
    var isStabilizedRecording: Bool { get }

    func startStabilizedRecording(
        to outputURL: URL,
        includeAudio: Bool,
        completion: @escaping (Result<URL, Error>) -> Void
    )
    func stopStabilizedRecording()
}

protocol StabilizedPhotoFrameSink: AnyObject {
    func photoContext() -> StabilizedPhotoContext?
    func waitForOptimalPhotoMoment(maxWait: TimeInterval, completion: @escaping () -> Void)
    func processPhoto(_ data: Data, context: StabilizedPhotoContext, completion: @escaping (Result<Data, Error>) -> Void)
    func captureStabilizedPhoto(
        completion: @escaping (Result<Data, Error>) -> Void
    )
}

extension StabilizedPhotoFrameSink {
    func waitForOptimalPhotoMoment(maxWait: TimeInterval, completion: @escaping () -> Void) {
        completion()
    }
}

struct StabilizedPhotoContext {
    var sourceSize: CGSize
    var viewport: CGSize
    var transform: PreviewRenderTransform
    var cropScale: CGFloat
}

final class CameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published private(set) var authorizationStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var status = CaptureStatus()
    @Published var stabilizationPreference: StabilizationPreference = .balanced {
        didSet {
            applySelectedStabilizationMode()
            let desiredZoomFactor = requestedZoomFactor
            sessionQueue.async { [weak self] in
                self?.applyZoomFactorOnSessionQueue(desiredZoomFactor)
            }
        }
    }
    @Published private(set) var isStabilizationEnabled = true
    @Published private(set) var telescopeMagnification: Double = StabilizationTuning.defaultOpticalMagnification
    @Published var zoomFactor: CGFloat = 1
    @Published var exposureBias: Float = 0
    @Published var captureQualityPreference: CaptureQualityOption = .default4K60 {
        didSet {
            applySelectedCaptureQuality()
        }
    }
    @Published private(set) var captureQualityOptions: [CaptureQualityOption] = [.automatic, .default4K60]
    @Published private(set) var activeCaptureQuality: CaptureQualityOption = .default4K60
    @Published private(set) var focusLocked = false
    @Published private(set) var exposureLocked = false
    @Published private(set) var pendingMediaCount = 0

    private let sessionQueue = DispatchQueue(label: "com.puroo.scope.camera.session")
    private let videoOutputQueue = DispatchQueue(label: "com.puroo.scope.camera.videoOutput", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var audioDeviceInput: AVCaptureDeviceInput?
    private var audioSessionActivated = false
    private let sinkLock = NSLock()
    private let mediaQueue = DispatchQueue(label: "com.puroo.scope.media", qos: .utility)

    private var videoDeviceInput: AVCaptureDeviceInput?
    private weak var previewFrameSink: CameraFrameSink?
    private weak var previewRecordingSink: StabilizedRecordingFrameSink?
    private weak var previewPhotoSink: StabilizedPhotoFrameSink?
    private var isConfigured = false
    private var targetFrameRate = 60
    private var requestedZoomFactor: CGFloat = 1
    private var requestedVideoRotationAngle: CGFloat = 90
    private var isVideoOrientationLocked = false
    private var subjectAreaObserver: NSObjectProtocol?
    private var sessionObservers: [NSObjectProtocol] = []
    private var shouldRunSession = false
    private var recordingActive = false
    private var finishingRecording = false
    private var recordingRequestPending = false
    private var photoBusy = false
    private var burstRemaining = 0
    private var burstSequenceActive = false
    private var burstFiles: [(url: URL, score: Double)] = []
    private var photoContexts: [Int64: StabilizedPhotoContext] = [:]
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var savingURLs: Set<URL> = []
    private var requestedQualityOnQueue: CaptureQualityOption = .default4K60
    private var stabilizationExposureEnabled = true // sessionQueue only
    private var exposurePolicy = StabilizationExposurePolicy()
    private var lastExposurePolicyRequest: TimeInterval = 0 // videoOutputQueue only
    private var appliedExposureCap: Double?

    private struct CaptureQualityApplication {
        var options: [CaptureQualityOption]
        var selected: CaptureQualityOption
    }

    deinit {
        sessionObservers.forEach(NotificationCenter.default.removeObserver)
        if let subjectAreaObserver {
            NotificationCenter.default.removeObserver(subjectAreaObserver)
        }
    }

    func requestAccessAndConfigure() {
        let currentStatus = AVCaptureDevice.authorizationStatus(for: .video)
        publish { $0.authorizationStatus = currentStatus }

        switch currentStatus {
        case .authorized:
            publishStatus { if $0.errorMessage == "相机权限不可用。" { $0.errorMessage = nil } }
            sessionQueue.async { [weak self] in self?.shouldRunSession = true }
            configureIfNeeded()
            refreshPendingMedia()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                self?.publish { $0.authorizationStatus = granted ? .authorized : .denied }
                if granted {
                    self?.sessionQueue.async { [weak self] in self?.shouldRunSession = true }
                    self?.configureIfNeeded()
                }
            }
        case .denied, .restricted:
            publishStatus(error: "相机权限不可用。")
        @unknown default:
            publishStatus(error: "相机权限状态未知。")
        }
    }

    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.shouldRunSession, self.isConfigured else { return }
            if !self.session.isRunning {
                self.restoreContinuousAutoControlsOnSessionQueue(recenter: false)
                self.session.startRunning()
            }
            self.publishStatus {
                $0.isSessionRunning = self.session.isRunning
                if self.session.isRunning && $0.errorMessage == "相机发生中断，正在恢复。" { $0.errorMessage = nil }
            }
        }
    }

    func stopSession() {
        beginFinishingBackgroundTask()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.shouldRunSession = false
            self.burstRemaining = 0
            self.stopRecordingOnSessionQueue()
            if self.session.isRunning { self.session.stopRunning() }
            self.frameSink?.resetPreview()
            self.publishStatus { $0.isSessionRunning = false }
            if !self.recordingActive && !self.finishingRecording && !self.photoBusy {
                self.releaseAudioInput()
                self.endBackgroundTaskWhenSavesFinish()
            }
        }
    }

    private var frameSink: CameraFrameSink? {
        sinkLock.lock()
        defer { sinkLock.unlock() }
        return previewFrameSink
    }

    private func beginFinishingBackgroundTask() {
        let begin = {
            guard self.backgroundTask == .invalid else { return }
            self.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save capture") { [weak self] in
                self?.endFinishingBackgroundTask()
            }
        }
        if Thread.isMainThread { begin() } else { DispatchQueue.main.async(execute: begin) }
    }

    private func endFinishingBackgroundTask() {
        DispatchQueue.main.async {
            guard self.backgroundTask != .invalid else { return }
            UIApplication.shared.endBackgroundTask(self.backgroundTask)
            self.backgroundTask = .invalid
        }
    }

    private func endBackgroundTaskWhenSavesFinish() {
        mediaQueue.async {
            if self.savingURLs.isEmpty { self.endFinishingBackgroundTask() }
        }
    }

    func setPreviewFrameSink(_ sink: CameraFrameSink?) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.sinkLock.lock()
            self.previewFrameSink = sink
            self.sinkLock.unlock()
            self.previewRecordingSink = sink as? StabilizedRecordingFrameSink
            self.previewPhotoSink = sink as? StabilizedPhotoFrameSink
            sink?.cameraController(self, didUpdateTargetFrameRate: self.targetFrameRate)
        }
    }

    func setVideoOrientation(_ orientation: UIInterfaceOrientation) {
        let angle: CGFloat
        switch orientation {
        case .portrait:
            angle = 90
        case .landscapeRight:
            angle = 0
        case .landscapeLeft:
            angle = 180
        case .portraitUpsideDown:
            angle = 270
        default:
            return
        }

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.requestedVideoRotationAngle = angle
            guard !self.isVideoOrientationLocked, !self.photoBusy, self.burstRemaining == 0 else { return }
            self.applyRequestedVideoRotation()
        }
    }

    func setStabilizationEnabled(_ enabled: Bool) {
        guard isStabilizationEnabled != enabled else { return }

        isStabilizationEnabled = enabled
        StabilizationTraceRecorder.shared.recordControl(
            "stabilization_enabled",
            values: ["value": enabled]
        )

        let desiredZoomFactor = requestedZoomFactor
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.applyZoomFactorOnSessionQueue(desiredZoomFactor)
            self.stabilizationExposureEnabled = enabled
            self.updateStabilizationExposureOnSessionQueue()
        }
    }

    func setTelescopeMagnification(_ value: Double) {
        let clamped = min(
            max(value, TelescopeMagnificationOption.minimum),
            TelescopeMagnificationOption.maximum
        )
        guard abs(telescopeMagnification - clamped) >= 0.001 else { return }
        telescopeMagnification = clamped
        StabilizationTraceRecorder.shared.recordControl(
            "telescope_magnification",
            values: ["value": clamped]
        )
    }

    func setZoomFactor(_ value: CGFloat) {
        let maxZoom = StabilizationTuning.maximumDisplayZoom
        let clamped = min(max(value, 1), maxZoom)
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDeviceInput?.device else { return }
            do {
                try device.lockForConfiguration()
                let deviceMax = min(device.activeFormat.videoMaxZoomFactor, maxZoom)
                device.videoZoomFactor = min(clamped, deviceMax)
                device.unlockForConfiguration()
                self.publish { $0.zoomFactor = min(clamped, deviceMax) }
            } catch {
                self.publishStatus(error: "无法设置变焦。")
            }
        }
    }

    func setDisplayedZoomFactor(_ value: CGFloat) {
        let clamped = min(max(value, 1), StabilizationTuning.maximumDisplayZoom)
        sessionQueue.async { [weak self] in
            self?.requestedZoomFactor = clamped
            self?.applyZoomFactorOnSessionQueue(clamped)
        }
    }

    private func applyZoomFactorOnSessionQueue(_ desiredDisplayZoom: CGFloat) {
        guard let device = videoDeviceInput?.device else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            let maxZoom = StabilizationTuning.maximumDisplayZoom
            let tuning = StabilizationTuning(
                isEnabled: isStabilizationEnabled,
                displayZoomFactor: desiredDisplayZoom
            )
            let cropScale = tuning.usesDigitalStabilization ? tuning.previewCropScale : 1
            let deviceMax = min(device.activeFormat.videoMaxZoomFactor, maxZoom)
            let compensatedDeviceZoom = desiredDisplayZoom / max(cropScale, 1)
            let deviceZoom = min(max(compensatedDeviceZoom, 1), deviceMax)
            device.videoZoomFactor = deviceZoom

            let actualDisplayZoom = min(max(deviceZoom * max(cropScale, 1), 1), maxZoom)
            publish { $0.zoomFactor = actualDisplayZoom }
        } catch {
            publishStatus(error: "无法设置变焦。")
        }
    }

    func setExposureBias(_ value: Float) {
        let clamped = min(max(value, -3), 3)
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDeviceInput?.device else { return }
            do {
                try device.lockForConfiguration()
                if !self.exposureLocked,
                   device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                device.setExposureTargetBias(clamped, completionHandler: nil)
                device.unlockForConfiguration()
                self.publish { $0.exposureBias = clamped }
            } catch {
                self.publishStatus(error: "无法设置曝光。")
            }
        }
    }

    func setFocusLocked(_ locked: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDeviceInput?.device else { return }
            do {
                try device.lockForConfiguration()
                if locked, device.isFocusModeSupported(.locked) {
                    device.focusMode = .locked
                } else if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                device.unlockForConfiguration()
                self.publish { $0.focusLocked = locked }
            } catch {
                self.publishStatus(error: "无法切换对焦模式。")
            }
        }
    }

    func focus(at devicePoint: CGPoint) {
        CameraFeedbackSound.playFocus()
        let point = CGPoint(
            x: min(max(devicePoint.x, 0), 1),
            y: min(max(devicePoint.y, 0), 1)
        )
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDeviceInput?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    } else if device.isFocusModeSupported(.autoFocus) {
                        device.focusMode = .autoFocus
                    }
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    } else if device.isExposureModeSupported(.autoExpose) {
                        device.exposureMode = .autoExpose
                    }
                }
                device.isSubjectAreaChangeMonitoringEnabled = true
                device.unlockForConfiguration()
                self.publish {
                    $0.focusLocked = false
                    $0.exposureLocked = false
                }
            } catch {
                self.publishStatus(error: "无法在所选位置对焦。")
            }
        }
    }

    func focusInPreview(at normalizedPoint: CGPoint) {
        guard let source = frameSink?.sourceFocusPoint(from: normalizedPoint) else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let angle = self.videoOutput.connection(with: .video)?.videoRotationAngle ?? 90
            let devicePoint: CGPoint
            switch Int(angle.rounded()) {
            case 90: devicePoint = CGPoint(x: source.y, y: 1 - source.x)
            case 180: devicePoint = CGPoint(x: 1 - source.x, y: 1 - source.y)
            case 270: devicePoint = CGPoint(x: 1 - source.y, y: source.x)
            default: devicePoint = source
            }
            self.focus(at: devicePoint)
        }
    }

    func setExposureLocked(_ locked: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDeviceInput?.device else { return }
            do {
                try device.lockForConfiguration()
                if locked, device.isExposureModeSupported(.locked) {
                    device.exposureMode = .locked
                } else if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                device.isSubjectAreaChangeMonitoringEnabled = true
                device.unlockForConfiguration()
                self.publish { $0.exposureLocked = locked }
            } catch {
                self.publishStatus(error: "无法切换测光模式。")
            }
        }
    }

    func capturePhoto() {
        sessionQueue.async { [weak self] in
            guard let self, self.burstRemaining == 0, !self.photoBusy else { return }
            guard let sink = self.previewPhotoSink, self.isStabilizationEnabled else {
                self.capturePhotoOnSessionQueue()
                return
            }
            sink.waitForOptimalPhotoMoment(maxWait: 0.055) { [weak self] in
                self?.sessionQueue.async {
                    self?.capturePhotoOnSessionQueue()
                }
            }
        }
    }

    private func capturePhotoOnSessionQueue() {
        guard !photoBusy, !recordingActive, !finishingRecording, !recordingRequestPending else { return }
        guard isConfigured, session.isRunning, let context = previewPhotoSink?.photoContext() else {
            burstRemaining = 0
            finishPhotoStep()
            publishStatus(message: "取景画面尚未就绪，请稍后拍摄。")
            return
        }
        photoBusy = true
        publishStatus { $0.isCapturingPhoto = true }
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        settings.flashMode = .off
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        settings.photoQualityPrioritization = burstRemaining > 0 ? .speed : .quality
        photoContexts[settings.uniqueID] = context
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    func captureBurst(plan: BurstCapturePlan = .defaultTelescope) {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, self.session.isRunning,
                  !self.photoBusy, !self.recordingActive, !self.finishingRecording, !self.recordingRequestPending,
                  self.burstRemaining == 0 else { return }
            self.publishStatus(message: "正在连拍...")
            self.burstRemaining = max(1, min(plan.frameCount, 16))
            self.burstSequenceActive = true
            self.burstFiles = []
            self.publishStatus { $0.isCapturingBurst = true }
            self.capturePhotoOnSessionQueue()
        }
    }

    func toggleRecording() {
        sessionQueue.async { [weak self] in
            guard let self, !self.finishingRecording, !self.photoBusy, self.burstRemaining == 0 else { return }
            if self.recordingActive {
                self.stopRecordingOnSessionQueue()
            } else if !self.recordingRequestPending {
                self.requestRecordingWithAudio()
            }
        }
    }

    private func configureIfNeeded() {
        sessionQueue.async { [weak self] in
            guard let self, !self.isConfigured else {
                self?.startSession()
                return
            }

            self.session.beginConfiguration()
            self.session.sessionPreset = .inputPriority
            defer { self.session.commitConfiguration() }

            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                self.publishStatus(error: "后置相机不可用。")
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else {
                    self.publishStatus(error: "无法添加相机输入。")
                    return
                }
                self.session.addInput(input)
                self.videoDeviceInput = input
            } catch {
                self.publishStatus(error: "无法创建相机输入。")
                return
            }

            self.configureDeviceDefaults(device)
            self.configureVideoOutput()
            self.configurePhotoOutput()
            self.configureMovieOutput()
            self.installSessionObservers()
            self.applySelectedStabilizationMode()
            self.applyZoomFactorOnSessionQueue(self.requestedZoomFactor)

            self.isConfigured = true
            self.startSession()
        }
    }

    private func configureDeviceDefaults(_ device: AVCaptureDevice) {
        installSubjectAreaObserver(for: device)
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            let qualityApplication = configureCaptureQuality(device)
            configureContinuousAutoControls(device, recenter: true)
            if device.isSmoothAutoFocusSupported {
                device.isSmoothAutoFocusEnabled = true
            }
            if device.isLowLightBoostSupported {
                device.automaticallyEnablesLowLightBoostWhenAvailable = true
            }
            publishCaptureQuality(qualityApplication)
        } catch {
            publishStatus(error: "无法配置相机默认参数。")
        }
    }

    private func installSubjectAreaObserver(for device: AVCaptureDevice) {
        if let subjectAreaObserver {
            NotificationCenter.default.removeObserver(subjectAreaObserver)
        }
        subjectAreaObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.subjectAreaDidChangeNotification,
            object: device,
            queue: nil
        ) { [weak self] _ in
            self?.sessionQueue.async { [weak self] in
                self?.restoreContinuousAutoControlsOnSessionQueue(recenter: true)
            }
        }
    }

    private func restoreContinuousAutoControlsOnSessionQueue(recenter: Bool) {
        guard let device = videoDeviceInput?.device else { return }
        do {
            try device.lockForConfiguration()
            configureContinuousAutoControls(device, recenter: recenter)
            device.unlockForConfiguration()
        } catch {
            publishStatus(error: "无法恢复自动测光。")
        }
    }

    private func configureContinuousAutoControls(
        _ device: AVCaptureDevice,
        recenter: Bool
    ) {
        let center = CGPoint(x: 0.5, y: 0.5)

        if recenter, device.isFocusPointOfInterestSupported {
            device.focusPointOfInterest = center
        }
        if !focusLocked, device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }

        if recenter, device.isExposurePointOfInterestSupported {
            device.exposurePointOfInterest = center
        }
        if !exposureLocked, device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }

        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        device.isSubjectAreaChangeMonitoringEnabled = true
        exposurePolicy = StabilizationExposurePolicy()
        appliedExposureCap = nil
        device.activeMaxExposureDuration = .invalid
    }

    private func updateStabilizationExposureOnSessionQueue() {
        guard let device = videoDeviceInput?.device else { return }
        let proposed = exposurePolicy.update(enabled: stabilizationExposureEnabled,
            automatic: device.exposureMode == .continuousAutoExposure,
            duration: CMTimeGetSeconds(device.exposureDuration), iso: Double(device.iso),
            maximumISO: Double(device.activeFormat.maxISO), targetOffset: Double(device.exposureTargetOffset),
            zoomFactor: Double(requestedZoomFactor))
        let cap = StabilizationExposurePolicy.boundedDuration(proposed,
            minimum: CMTimeGetSeconds(device.activeFormat.minExposureDuration),
            maximum: CMTimeGetSeconds(device.activeFormat.maxExposureDuration))
        let actualCap = CMTimeGetSeconds(device.activeMaxExposureDuration)
        let needsReapplication = cap.map { !actualCap.isFinite || abs(actualCap - $0) > 0.00001 } ?? false
        guard cap != appliedExposureCap || needsReapplication else { return }
        do {
            try device.lockForConfiguration()
            device.activeMaxExposureDuration = cap.map { CMTime(seconds: $0, preferredTimescale: 1_000_000) } ?? .invalid
            device.unlockForConfiguration()
            appliedExposureCap = cap
            StabilizationTraceRecorder.shared.recordControl("exposure_policy", values: [
                "max_exposure_s": cap ?? -1, "short_exposure": cap != nil,
                "continuous_ae": device.exposureMode == .continuousAutoExposure,
                "iso": device.iso, "exposure_target_offset": device.exposureTargetOffset
            ])
        } catch {
            StabilizationTraceRecorder.shared.recordControl("exposure_policy_failed")
        }
    }

    private func configureCaptureQuality(_ device: AVCaptureDevice) -> CaptureQualityApplication {
        let options = supportedCaptureQualityOptions(for: device)
        let selected = selectedCaptureQuality(from: options)

        if let format = preferredFormat(for: selected, on: device) {
            device.activeFormat = format
            let frameDuration = CMTime(
                value: 1,
                timescale: CMTimeScale(selected.frameRate)
            )
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            targetFrameRate = selected.frameRate
        } else {
            targetFrameRate = currentFrameRate(for: device)
        }

        return CaptureQualityApplication(options: options, selected: selected)
    }

    private func supportedCaptureQualityOptions(for device: AVCaptureDevice) -> [CaptureQualityOption] {
        let targets = [
            CaptureQualityOption(width: 3840, height: 2160, frameRate: 60),
            CaptureQualityOption(width: 3840, height: 2160, frameRate: 30),
            CaptureQualityOption(width: 1920, height: 1080, frameRate: 60),
            CaptureQualityOption(width: 1920, height: 1080, frameRate: 30),
            CaptureQualityOption(width: 1280, height: 720, frameRate: 60),
            CaptureQualityOption(width: 1280, height: 720, frameRate: 30)
        ]

        let supportedTargets = targets.filter { preferredFormat(for: $0, on: device) != nil }
        return supportedTargets.isEmpty ? [.automatic] : [.automatic] + supportedTargets
    }

    private func selectedCaptureQuality(from options: [CaptureQualityOption]) -> CaptureQualityOption {
        let explicitOptions = options.filter { !$0.isAutomatic }
        guard let automaticSelection = explicitOptions.first(where: {
            $0.width == 3840 && $0.height == 2160 && $0.frameRate == 60
        }) ?? explicitOptions.first(where: {
            $0.width == 1920 && $0.height == 1080 && $0.frameRate == 60
        }) ?? explicitOptions.first else {
            return .automatic
        }

        if requestedQualityOnQueue.isAutomatic {
            return automaticSelection
        }

        return explicitOptions.first { $0 == requestedQualityOnQueue } ?? automaticSelection
    }

    private func preferredFormat(
        for option: CaptureQualityOption,
        on device: AVCaptureDevice
    ) -> AVCaptureDevice.Format? {
        guard !option.isAutomatic else { return nil }

        let matchingFormats = device.formats.filter { format in
            formatMatches(option, format: format) &&
                format.videoSupportedFrameRateRanges.contains { range in
                    range.minFrameRate <= Double(option.frameRate) &&
                        range.maxFrameRate >= Double(option.frameRate)
                }
        }

        return matchingFormats.max { lhs, rhs in
            formatScore(lhs, for: option) < formatScore(rhs, for: option)
        }
    }

    private func formatMatches(
        _ option: CaptureQualityOption,
        format: AVCaptureDevice.Format
    ) -> Bool {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return max(dimensions.width, dimensions.height) == max(option.width, option.height) &&
            min(dimensions.width, dimensions.height) == min(option.width, option.height)
    }

    private func formatScore(
        _ format: AVCaptureDevice.Format,
        for option: CaptureQualityOption
    ) -> Int {
        let stabilizationScore = format.isVideoStabilizationModeSupported(.standard) ? 100 : 0
        let cinematicScore = format.isVideoStabilizationModeSupported(.cinematic) ? 40 : 0
        return stabilizationScore + cinematicScore + option.frameRate
    }

    private func currentFrameRate(for device: AVCaptureDevice) -> Int {
        let frameDuration = device.activeVideoMinFrameDuration
        let duration = CMTimeGetSeconds(frameDuration)
        if duration.isFinite, duration > 0 {
            return max(24, min(Int((1.0 / duration).rounded()), 60))
        }

        let maximumFrameRate = device.activeFormat.videoSupportedFrameRateRanges
            .map(\.maxFrameRate)
            .max() ?? 30
        return max(24, min(Int(maximumFrameRate.rounded()), 60))
    }

    private func applySelectedCaptureQuality() {
        let requested = captureQualityPreference
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDeviceInput?.device else { return }
            guard !self.recordingActive, !self.finishingRecording, !self.photoBusy, self.burstRemaining == 0 else {
                self.publishStatus(error: "录制中不能切换画质。")
                return
            }

            do {
                self.requestedQualityOnQueue = requested
                self.session.beginConfiguration()
                defer { self.session.commitConfiguration() }
                try device.lockForConfiguration()
                let qualityApplication = self.configureCaptureQuality(device)
                self.configureContinuousAutoControls(device, recenter: false)
                device.unlockForConfiguration()
                self.configurePhotoDimensions(device)
                self.frameSink?.resetPreview()
                self.publishCaptureQuality(qualityApplication)
                self.applySelectedStabilizationMode()
                self.applyZoomFactorOnSessionQueue(self.requestedZoomFactor)
            } catch {
                self.publishStatus(error: "无法切换画质。")
            }
        }
    }

    private func publishCaptureQuality(_ qualityApplication: CaptureQualityApplication) {
        let options = qualityApplication.options
        let selected = qualityApplication.selected
        publish {
            $0.captureQualityOptions = options
            $0.activeCaptureQuality = selected
        }
        notifyPreviewFrameRate(targetFrameRate)
    }

    private func notifyPreviewFrameRate(_ frameRate: Int) {
        videoOutputQueue.async { [weak self] in
            guard let self else { return }
            self.frameSink?.cameraController(self, didUpdateTargetFrameRate: frameRate)
        }
    }

    private func configureVideoOutput() {
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.automaticallyConfiguresOutputBufferDimensions = false
        videoOutput.deliversPreviewSizedOutputBuffers = false
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        videoOutput.setSampleBufferDelegate(self, queue: videoOutputQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
            configureVideoOutputConnection()
        }
    }

    private func configureVideoOutputConnection() {
        guard let connection = videoOutput.connection(with: .video) else { return }
        applyVideoRotation(to: connection)
        if connection.isVideoMirroringSupported {
            connection.isVideoMirrored = false
        }
        if connection.isCameraIntrinsicMatrixDeliverySupported {
            connection.isCameraIntrinsicMatrixDeliveryEnabled = true
        }
        applyPreviewStabilization(to: connection)
    }

    private func configurePhotoOutput() {
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality
            if let device = videoDeviceInput?.device { configurePhotoDimensions(device) }
            applyVideoRotation(to: photoOutput.connection(with: .video))
        }
    }

    private func configurePhotoDimensions(_ device: AVCaptureDevice) {
        if let size = device.activeFormat.supportedMaxPhotoDimensions.max(by: {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        }) {
            photoOutput.maxPhotoDimensions = size
        }
    }

    private func installSessionObservers() {
        guard sessionObservers.isEmpty else { return }
        let center = NotificationCenter.default
        sessionObservers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
            self?.beginFinishingBackgroundTask()
            self?.sessionQueue.async { [weak self] in
                guard let self else { return }
                let wasRecording = self.recordingActive
                self.burstRemaining = 0
                self.stopRecordingOnSessionQueue()
                self.publishStatus { $0.isSessionRunning = false }
                self.publishStatus(message: wasRecording ? "相机暂时中断，已结束当前录像。" : "相机暂时中断，等待恢复。")
                if !self.recordingActive && !self.photoBusy { self.endBackgroundTaskWhenSavesFinish() }
            }
        })
        for name in [AVCaptureSession.interruptionEndedNotification, AVCaptureSession.runtimeErrorNotification] {
            sessionObservers.append(center.addObserver(forName: name, object: session, queue: nil) { [weak self] notification in
                self?.sessionQueue.async { [weak self] in
                    guard let self else { return }
                    if notification.name == AVCaptureSession.runtimeErrorNotification {
                        self.stopRecordingOnSessionQueue()
                        self.publishStatus(error: "相机发生中断，正在恢复。")
                    }
                    self.frameSink?.resetPreview()
                    if self.shouldRunSession { self.startSession() }
                }
            })
        }
    }

    private func requestRecordingWithAudio() {
        guard session.isRunning, shouldRunSession else { return }
        recordingRequestPending = true
        let proceed: (Bool) -> Void = { [weak self] granted in
            self?.sessionQueue.async { [weak self] in
                guard let self else { return }
                self.recordingRequestPending = false
                guard self.shouldRunSession, self.session.isRunning, !self.photoBusy, self.burstRemaining == 0 else { return }
                if granted { self.configureAudioInput() }
                self.startRecording()
                if self.audioDeviceInput == nil { self.publishStatus(message: "未启用麦克风，本次录像无声音。") }
            }
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: proceed(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio, completionHandler: proceed)
        default: proceed(false)
        }
    }

    private func configureAudioInput() {
        guard audioDeviceInput == nil else { return }
        defer {
            if audioDeviceInput == nil && audioSessionActivated {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                audioSessionActivated = false
            }
        }
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetooth])
            try audioSession.setActive(true)
            audioSessionActivated = true
            guard let device = AVCaptureDevice.default(for: .audio) else { return }
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            guard session.canAddInput(input), session.canAddOutput(audioOutput) else { return }
            session.addInput(input)
            session.addOutput(audioOutput)
            audioOutput.setSampleBufferDelegate(self, queue: videoOutputQueue)
            audioDeviceInput = input
        } catch {
            publishStatus(message: "麦克风暂不可用，本次仅录制画面。")
        }
    }

    private func releaseAudioInput() {
        if let input = audioDeviceInput {
            session.beginConfiguration()
            session.removeOutput(audioOutput)
            session.removeInput(input)
            audioDeviceInput = nil
            session.commitConfiguration()
        }
        if audioSessionActivated {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioSessionActivated = false
        }
    }

    private func configureMovieOutput() {
        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
            applyVideoRotation(to: movieOutput.connection(with: .video))
        }
    }

    private func applyRequestedVideoRotation() {
        applyVideoRotation(to: videoOutput.connection(with: .video))
        applyVideoRotation(to: photoOutput.connection(with: .video))
        applyVideoRotation(to: movieOutput.connection(with: .video))
        StabilizationTraceRecorder.shared.recordControl(
            "video_orientation",
            values: ["angle": requestedVideoRotationAngle]
        )
    }

    private func applyVideoRotation(to connection: AVCaptureConnection?) {
        guard let connection,
              connection.isVideoRotationAngleSupported(requestedVideoRotationAngle)
        else {
            return
        }
        connection.videoRotationAngle = requestedVideoRotationAngle
    }

    private func unlockVideoOrientationAfterRecording() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.isVideoOrientationLocked = false
            self.applyRequestedVideoRotation()
        }
    }

    private func startRecording() {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, self.shouldRunSession, !self.recordingActive, !self.finishingRecording else { return }
            if let previewRecordingSink = self.previewRecordingSink {
                guard !previewRecordingSink.isStabilizedRecording else { return }
                guard let url = self.makeRecordingURL(extension: "mp4") else { self.releaseAudioInput(); return }
                self.isVideoOrientationLocked = true
                self.recordingActive = true
                self.publishStatus {
                    $0.isRecording = true
                    $0.recordingStartedAt = Date()
                }
                previewRecordingSink.startStabilizedRecording(to: url, includeAudio: self.audioDeviceInput != nil) { [weak self] result in
                    guard let self else { return }
                    self.sessionQueue.async {
                        self.recordingActive = false
                        self.finishingRecording = false
                        self.releaseAudioInput()
                        self.publishStatus {
                            $0.isRecording = false
                            $0.isFinishingRecording = false
                            $0.recordingStartedAt = nil
                        }
                        self.unlockVideoOrientationAfterRecording()
                        switch result {
                        case .success(let outputURL): self.saveVideo(at: outputURL)
                        case .failure(let error):
                            self.publishStatus(error: self.recordingErrorMessage(for: error))
                            self.endFinishingBackgroundTask()
                        }
                    }
                }
                return
            }

            guard !self.movieOutput.isRecording else { return }
            guard let url = self.makeRecordingURL(extension: "mov") else { self.releaseAudioInput(); return }
            self.isVideoOrientationLocked = true
            self.recordingActive = true
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
            self.publishStatus {
                $0.isRecording = true
                $0.recordingStartedAt = Date()
            }
        }
    }

    private func makeRecordingURL(extension fileExtension: String) -> URL? {
        do {
            let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("RecordingRecovery", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder.appendingPathComponent("puroo-scope-\(UUID().uuidString)").appendingPathExtension(fileExtension)
        } catch {
            publishStatus(error: "无法创建录像文件：\(error.localizedDescription)")
            return nil
        }
    }

    private func stopRecording() {
        sessionQueue.async { [weak self] in
            self?.stopRecordingOnSessionQueue()
        }
    }

    private func stopRecordingOnSessionQueue() {
        guard recordingActive, !finishingRecording else { return }
        finishingRecording = true
        publishStatus { $0.isFinishingRecording = true }
        if let previewRecordingSink, previewRecordingSink.isStabilizedRecording {
            previewRecordingSink.stopStabilizedRecording()
        } else if movieOutput.isRecording {
            movieOutput.stopRecording()
        }
    }

    private func applySelectedStabilizationMode() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.applyPreviewStabilization(to: self.videoOutput.connection(with: .video))
            self.applyStabilization(to: self.movieOutput.connection(with: .video))
        }
    }

    private func applyStabilization(to connection: AVCaptureConnection?) {
        guard let connection else { return }
        let selected = bestAvailableMode(for: connection, requestedModes: stabilizationPreference.requestedModes)
        apply(selectedStabilizationMode: selected, to: connection, target: .movie)
    }

    private func applyPreviewStabilization(to connection: AVCaptureConnection?) {
        guard let connection else { return }
        let selected = bestAvailableMode(for: connection, requestedModes: stabilizationPreference.requestedPreviewModes)
        apply(selectedStabilizationMode: selected, to: connection, target: .preview)
    }

    private enum StabilizationConnectionTarget {
        case preview
        case movie
    }

    private func apply(
        selectedStabilizationMode selected: AVCaptureVideoStabilizationMode,
        to connection: AVCaptureConnection,
        target: StabilizationConnectionTarget
    ) {
        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = selected
            let activeMode = connection.activeVideoStabilizationMode
            publishStatus { status in
                status.activeStabilizationMode = activeMode
                switch target {
                case .preview:
                    status.activePreviewStabilizationMode = activeMode
                case .movie:
                    status.activeMovieStabilizationMode = activeMode
                }
            }
        } else {
            publishStatus { status in
                switch target {
                case .preview:
                    status.activePreviewStabilizationMode = .off
                case .movie:
                    status.activeMovieStabilizationMode = .off
                }
            }
        }
    }

    private func bestAvailableMode(
        for connection: AVCaptureConnection,
        requestedModes: [AVCaptureVideoStabilizationMode]
    ) -> AVCaptureVideoStabilizationMode {
        guard connection.isVideoStabilizationSupported else { return .off }
        guard let device = videoDeviceInput?.device else { return .auto }

        for mode in requestedModes {
            if mode == .off || mode == .auto || device.activeFormat.isVideoStabilizationModeSupported(mode) {
                return mode
            }
        }
        return .auto
    }

    private func savePhotoData(_ data: Data) {
        mediaQueue.async {
            do {
                let url = try self.pendingDirectory().appendingPathComponent("photo-\(UUID().uuidString).jpg")
                try data.write(to: url, options: .atomic)
                self.savePendingMedia(at: url)
            } catch {
                self.publishStatus(error: "照片暂存失败：\(error.localizedDescription)")
                self.endFinishingBackgroundTask()
            }
        }
    }

    private func saveVideo(at url: URL) {
        mediaQueue.async {
            do {
                let destination = try self.pendingDirectory().appendingPathComponent(url.lastPathComponent)
                if url != destination { try FileManager.default.moveItem(at: url, to: destination) }
                self.savePendingMedia(at: destination)
            } catch {
                self.publishStatus(error: "视频仍保留在本机，暂存失败：\(error.localizedDescription)")
                self.endFinishingBackgroundTask()
            }
        }
    }

    private func pendingDirectory() throws -> URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PendingCaptures", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func pendingURLs() -> [URL] {
        guard let directory = try? pendingDirectory() else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["jpg", "mp4", "mov"].contains($0.pathExtension.lowercased()) }
    }

    func refreshPendingMedia() {
        mediaQueue.async {
            let count = self.pendingURLs().count
            self.publish { $0.pendingMediaCount = count }
        }
    }

    func retryPendingMedia() {
        mediaQueue.async {
            for url in self.pendingURLs() { self.savePendingMedia(at: url) }
        }
    }

    private func savePendingMedia(at url: URL) {
        guard savingURLs.insert(url).inserted else { return }
        publishStatus { $0.isSaving = true }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { authorization in
            guard authorization == .authorized || authorization == .limited else {
                self.completeMediaSave(url: url, success: false, message: "未获得相册权限，素材已保留，可稍后重新保存。")
                return
            }
            let isPhoto = url.pathExtension.lowercased() == "jpg"
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.isFavorite = url.lastPathComponent.hasPrefix("best-")
                request.addResource(with: isPhoto ? .photo : .video, fileURL: url, options: nil)
            } completionHandler: { success, error in
                self.completeMediaSave(url: url, success: success, message: error?.localizedDescription)
            }
        }
    }

    private func completeMediaSave(url: URL, success: Bool, message: String?) {
        mediaQueue.async {
            if success { try? FileManager.default.removeItem(at: url) }
            self.savingURLs.remove(url)
            let count = self.pendingURLs().count
            let saving = !self.savingURLs.isEmpty
            self.publish {
                $0.pendingMediaCount = count
                $0.status.isSaving = saving
                $0.status.lastMessage = success ? "已保存到相册。" : nil
                $0.status.errorMessage = success ? nil : (message ?? "保存失败，素材已保留，请重新保存。")
            }
            if success { self.clearStatusMessage("已保存到相册。") }
            if !saving { self.endFinishingBackgroundTask() }
        }
    }

    private func completePhoto(_ result: Result<Data, Error>) {
        sessionQueue.async {
            switch result {
            case .success(let data):
                if self.burstSequenceActive {
                    self.mediaQueue.async {
                        do {
                            let url = try self.pendingDirectory().appendingPathComponent("burst-\(UUID().uuidString).jpg")
                            try data.write(to: url, options: .atomic)
                            let score = BurstPhotoCoordinator.sharpness(of: data)
                            self.sessionQueue.async {
                                self.burstFiles.append((url, score))
                                self.finishPhotoStep()
                            }
                        } catch {
                            self.sessionQueue.async {
                                self.publishStatus(error: "连拍暂存失败：\(error.localizedDescription)")
                                self.burstRemaining = 0
                                self.finishPhotoStep()
                            }
                        }
                    }
                    return
                }
                self.savePhotoData(data)
            case .failure(let error):
                self.publishStatus(error: error.localizedDescription)
                self.burstRemaining = 0
                if self.burstFiles.isEmpty { self.endFinishingBackgroundTask() }
            }
            self.finishPhotoStep()
        }
    }

    private func finishPhotoStep() {
        photoBusy = false
        publishStatus { $0.isCapturingPhoto = false }
        if burstRemaining > 0 { burstRemaining -= 1 }
        if burstRemaining > 0, shouldRunSession {
            sessionQueue.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self else { return }
                if self.shouldRunSession { self.capturePhotoOnSessionQueue() }
                else { self.burstRemaining = 0; self.finishPhotoStep() }
            }
        } else {
            burstRemaining = 0
            burstSequenceActive = false
            let files = burstFiles
            burstFiles = []
            if !files.isEmpty {
                mediaQueue.async {
                    let best = files.max(by: { $0.score < $1.score })?.url
                    for item in files {
                        var url = item.url
                        if url == best {
                            let selected = url.deletingLastPathComponent().appendingPathComponent("best-" + url.lastPathComponent)
                            if (try? FileManager.default.moveItem(at: url, to: selected)) != nil { url = selected }
                        }
                        self.savePendingMedia(at: url)
                    }
                }
            }
            publishStatus { $0.isCapturingBurst = false }
            applyRequestedVideoRotation()
        }
    }

    private func publish(_ update: @escaping (CameraController) -> Void) {
        DispatchQueue.main.async {
            update(self)
        }
    }

    private func publishStatus(message: String? = nil, error: String? = nil) {
        publishStatus { status in
            status.lastMessage = message
            status.errorMessage = error
        }
        if let message {
            clearStatusMessage(message)
        }
    }

    private func clearStatusMessage(_ expectedMessage: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self, self.status.lastMessage == expectedMessage else { return }
            self.status.lastMessage = nil
        }
    }

    private func publishStatus(_ update: @escaping (inout CaptureStatus) -> Void) {
        DispatchQueue.main.async {
            update(&self.status)
        }
    }

    private func recordingErrorMessage(for error: Error) -> String {
        let nsError = error as NSError
        let detail = detailedRecordingDescription(for: nsError)
        if detail == "The operation could not be completed" || detail == "The operation couldn’t be completed." {
            return "稳定预览录像失败：\(nsError.domain) code \(nsError.code)"
        }
        return "稳定预览录像失败：\(detail) (\(nsError.domain) code \(nsError.code))"
    }

    private func detailedRecordingDescription(for error: NSError) -> String {
        var parts = [error.localizedDescription]
        if let reason = error.localizedFailureReason, !reason.isEmpty {
            parts.append("reason \(reason)")
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying \(underlying.domain) code \(underlying.code)")
            if !underlying.localizedDescription.isEmpty {
                parts.append(underlying.localizedDescription)
            }
        }
        return parts.joined(separator: "; ")
    }

}

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        sessionQueue.async {
            let context = self.photoContexts.removeValue(forKey: photo.resolvedSettings.uniqueID)
            if let error { self.completePhoto(.failure(error)); return }
            guard let data = photo.fileDataRepresentation(), let context,
                  let sink = self.previewPhotoSink else {
                self.completePhoto(.failure(NSError(domain: "PUROO.Photo", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "照片数据或取景信息不可用。"])))
                return
            }
            sink.processPhoto(data, context: context) { [weak self] result in self?.completePhoto(result) }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        guard let error else { return }
        sessionQueue.async {
            if self.photoContexts.removeValue(forKey: resolvedSettings.uniqueID) != nil {
                self.completePhoto(.failure(error))
            }
        }
    }
}

extension CameraController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        sessionQueue.async {
            self.recordingActive = false
            self.finishingRecording = false
            self.releaseAudioInput()
        }
        publishStatus {
            $0.isRecording = false
            $0.isFinishingRecording = false
            $0.recordingStartedAt = nil
        }
        unlockVideoOrientationAfterRecording()

        if let error {
            publishStatus(error: error.localizedDescription)
            return
        }

        saveVideo(at: outputFileURL)
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output === audioOutput {
            frameSink?.receiveAudio(sampleBuffer)
            return
        }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let callbackTime = CACurrentMediaTime()
        if callbackTime - lastExposurePolicyRequest >= 1 {
            lastExposurePolicyRequest = callbackTime
            sessionQueue.async { [weak self] in self?.updateStabilizationExposureOnSessionQueue() }
        }
        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let focalLengths = cameraIntrinsicFocalLengths(
                from: sampleBuffer,
                width: width,
                height: height
            )
            let exposureDuration = videoDeviceInput.map {
                CMTimeGetSeconds($0.device.exposureDuration)
            } ?? 0
            let metadata = CameraFrameMetadata(
                presentationTime: timestamp,
                exposureDuration: exposureDuration.isFinite ? exposureDuration : 0,
                videoRotationAngle: connection.videoRotationAngle,
                focalLengthPixelsX: focalLengths.x,
                focalLengthPixelsY: focalLengths.y,
                frameWidth: width,
                frameHeight: height,
                callbackTime: callbackTime,
                iso: videoDeviceInput?.device.iso ?? 0,
                exposureTargetOffset: videoDeviceInput?.device.exposureTargetOffset ?? 0,
                activeSystemStabilization: connection.activeVideoStabilizationMode.rawValue,
                maximumExposureDuration: videoDeviceInput.map { CMTimeGetSeconds($0.device.activeMaxExposureDuration) } ?? 0
            )
            frameSink?.cameraController(
                self,
                didOutput: pixelBuffer,
                metadata: metadata
            )
        }
    }

    private func cameraIntrinsicFocalLengths(
        from sampleBuffer: CMSampleBuffer,
        width: Int,
        height: Int
    ) -> (x: CGFloat, y: CGFloat) {
        if let attachment = CMGetAttachment(
            sampleBuffer,
            key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
            attachmentModeOut: nil
        ), let data = attachment as? Data,
           data.count >= MemoryLayout<matrix_float3x3>.size {
            var matrix = matrix_identity_float3x3
            _ = withUnsafeMutableBytes(of: &matrix) { destination in
                data.copyBytes(to: destination)
            }
            let focalX = CGFloat(matrix.columns.0.x)
            let focalY = CGFloat(matrix.columns.1.y)
            if focalX.isFinite, focalY.isFinite, focalX > 1, focalY > 1 {
                return (focalX, focalY)
            }
        }

        let fieldOfViewDegrees = videoDeviceInput?.device.activeFormat.videoFieldOfView ?? 60
        let fieldOfViewRadians = CGFloat(fieldOfViewDegrees) * .pi / 180
        let longDimension = CGFloat(max(width, height))
        let hardwareZoom = max(videoDeviceInput?.device.videoZoomFactor ?? 1, 1)
        let focalLength = (longDimension / max(2 * tan(fieldOfViewRadians * 0.5), 0.001)) * hardwareZoom
        return (focalLength, focalLength)
    }
}
