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
}

protocol CameraFrameSink: AnyObject {
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
        completion: @escaping (Result<URL, Error>) -> Void
    )
    func stopStabilizedRecording()
}

protocol StabilizedPhotoFrameSink: AnyObject {
    func captureStabilizedPhoto(
        completion: @escaping (Result<Data, Error>) -> Void
    )
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
    @Published var captureQualityPreference: CaptureQualityOption = .automatic {
        didSet {
            guard captureQualityPreference != oldValue else { return }
            applySelectedCaptureQuality()
        }
    }
    @Published private(set) var captureQualityOptions: [CaptureQualityOption] = [.automatic]
    @Published private(set) var activeCaptureQuality: CaptureQualityOption = .automatic
    @Published private(set) var focusLocked = false
    @Published private(set) var exposureLocked = false

    private let sessionQueue = DispatchQueue(label: "com.puroo.scope.camera.session")
    private let videoOutputQueue = DispatchQueue(label: "com.puroo.scope.camera.videoOutput", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()

    private var videoDeviceInput: AVCaptureDeviceInput?
    private weak var previewFrameSink: CameraFrameSink?
    private weak var previewRecordingSink: StabilizedRecordingFrameSink?
    private weak var previewPhotoSink: StabilizedPhotoFrameSink?
    private var isConfigured = false
    private var targetFrameRate = 60
    private var requestedZoomFactor: CGFloat = 1
    private var requestedVideoRotationAngle: CGFloat = 90
    private var isVideoOrientationLocked = false

    private struct CaptureQualityApplication {
        var options: [CaptureQualityOption]
        var selected: CaptureQualityOption
    }

    func requestAccessAndConfigure() {
        let currentStatus = AVCaptureDevice.authorizationStatus(for: .video)
        publish { $0.authorizationStatus = currentStatus }

        switch currentStatus {
        case .authorized:
            configureIfNeeded()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                self?.publish { $0.authorizationStatus = granted ? .authorized : .denied }
                if granted {
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
            guard let self, self.isConfigured, !self.session.isRunning else { return }
            self.session.startRunning()
            self.publishStatus { $0.isSessionRunning = true }
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            self.publishStatus { $0.isSessionRunning = false }
        }
    }

    func setPreviewFrameSink(_ sink: CameraFrameSink?) {
        videoOutputQueue.async { [weak self] in
            guard let self else { return }
            self.previewFrameSink = sink
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
            guard !self.isVideoOrientationLocked else { return }
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
            self?.applyZoomFactorOnSessionQueue(desiredZoomFactor)
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
        let clamped = min(max(value, 1), 6)
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDeviceInput?.device else { return }
            do {
                try device.lockForConfiguration()
                let deviceMax = min(device.activeFormat.videoMaxZoomFactor, 6)
                device.videoZoomFactor = min(clamped, deviceMax)
                device.unlockForConfiguration()
                self.publish { $0.zoomFactor = min(clamped, deviceMax) }
            } catch {
                self.publishStatus(error: "无法设置变焦。")
            }
        }
    }

    func setDisplayedZoomFactor(_ value: CGFloat) {
        let clamped = min(max(value, 1), 6)
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

            let tuning = StabilizationTuning(isEnabled: isStabilizationEnabled)
            let cropScale = tuning.usesDigitalStabilization ? tuning.previewCropScale : 1
            let deviceMax = min(device.activeFormat.videoMaxZoomFactor, 6)
            let compensatedDeviceZoom = desiredDisplayZoom / max(cropScale, 1)
            let deviceZoom = min(max(compensatedDeviceZoom, 1), deviceMax)
            device.videoZoomFactor = deviceZoom

            let actualDisplayZoom = min(max(deviceZoom * max(cropScale, 1), 1), 6)
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
                    if device.isFocusModeSupported(.autoFocus) {
                        device.focusMode = .autoFocus
                    } else if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    }
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    if device.isExposureModeSupported(.autoExpose) {
                        device.exposureMode = .autoExpose
                    } else if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                }
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
                device.unlockForConfiguration()
                self.publish { $0.exposureLocked = locked }
            } catch {
                self.publishStatus(error: "无法切换测光模式。")
            }
        }
    }

    func capturePhoto() {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured else { return }
            CameraFeedbackSound.playShutter()
            if let previewPhotoSink = self.previewPhotoSink {
                self.publishStatus(message: "正在拍照...")
                previewPhotoSink.captureStabilizedPhoto { [weak self] result in
                    switch result {
                    case .success(let data):
                        self?.savePhotoData(data)
                    case .failure(let error):
                        self?.publishStatus(error: error.localizedDescription)
                    }
                }
                return
            }

            let settings = AVCapturePhotoSettings()
            settings.flashMode = .off
            self.photoOutput.capturePhoto(with: settings, delegate: self)
            self.publishStatus(message: "正在拍照...")
        }
    }

    func captureBurst(plan: BurstCapturePlan = .defaultTelescope) {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured else { return }
            self.publishStatus(message: "正在连拍...")

            for index in 0..<plan.frameCount {
                self.sessionQueue.asyncAfter(deadline: .now() + plan.frameInterval * Double(index)) { [weak self] in
                    self?.capturePhoto()
                }
            }
        }
    }

    func toggleRecording() {
        status.isRecording ? stopRecording() : startRecording()
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
            self.applySelectedStabilizationMode()
            self.applyZoomFactorOnSessionQueue(self.requestedZoomFactor)

            self.isConfigured = true
            self.startSession()
        }
    }

    private func configureDeviceDefaults(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            let qualityApplication = configureCaptureQuality(device)
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
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
            $0.width == 1920 && $0.height == 1080 && $0.frameRate == 60
        }) ?? explicitOptions.first else {
            return .automatic
        }

        if captureQualityPreference.isAutomatic {
            return automaticSelection
        }

        return explicitOptions.first { $0 == captureQualityPreference } ?? automaticSelection
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
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDeviceInput?.device else { return }
            guard !self.status.isRecording else {
                self.publishStatus(error: "录制中不能切换画质。")
                return
            }

            do {
                try device.lockForConfiguration()
                let qualityApplication = self.configureCaptureQuality(device)
                device.unlockForConfiguration()
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
            self.previewFrameSink?.cameraController(self, didUpdateTargetFrameRate: frameRate)
        }
    }

    private func configureVideoOutput() {
        videoOutput.alwaysDiscardsLateVideoFrames = true
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
            applyVideoRotation(to: photoOutput.connection(with: .video))
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
            guard let self, self.isConfigured else { return }
            if let previewRecordingSink = self.previewRecordingSink {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("puroo-scope-\(UUID().uuidString)")
                    .appendingPathExtension("mp4")
                guard !previewRecordingSink.isStabilizedRecording else { return }
                self.isVideoOrientationLocked = true
                previewRecordingSink.startStabilizedRecording(to: url) { [weak self] result in
                    guard let self else { return }
                    self.publishStatus { $0.isRecording = false }
                    self.unlockVideoOrientationAfterRecording()

                    switch result {
                    case .success(let outputURL):
                        self.saveVideo(at: outputURL)
                    case .failure(let error):
                        try? FileManager.default.removeItem(at: url)
                        self.publishStatus(error: self.recordingErrorMessage(for: error))
                    }
                }
                self.publishStatus { $0.isRecording = true }
                return
            }

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("puroo-scope-\(UUID().uuidString)")
                .appendingPathExtension("mov")
            guard !self.movieOutput.isRecording else { return }
            self.isVideoOrientationLocked = true
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
            self.publishStatus { $0.isRecording = true }
        }
    }

    private func stopRecording() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if let previewRecordingSink = self.previewRecordingSink,
               previewRecordingSink.isStabilizedRecording {
                previewRecordingSink.stopStabilizedRecording()
                return
            }

            guard self.movieOutput.isRecording else { return }
            self.movieOutput.stopRecording()
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
        publishStatus { $0.isSaving = true }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] authorization in
            guard authorization == .authorized || authorization == .limited else {
                self?.publishStatus { status in
                    status.isSaving = false
                    status.errorMessage = "未获得照片保存权限。"
                }
                return
            }

            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            } completionHandler: { success, error in
                self?.publishStatus { status in
                    status.isSaving = false
                    status.lastMessage = success ? "照片已保存。" : nil
                    status.errorMessage = error?.localizedDescription
                }
                if success {
                    self?.clearStatusMessage("照片已保存。")
                }
            }
        }
    }

    private func saveVideo(at url: URL) {
        publishStatus { $0.isSaving = true }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] authorization in
            guard authorization == .authorized || authorization == .limited else {
                self?.publishStatus { status in
                    status.isSaving = false
                    status.errorMessage = "未获得照片保存权限。"
                }
                return
            }

            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: url, options: nil)
            } completionHandler: { success, error in
                try? FileManager.default.removeItem(at: url)
                self?.publishStatus { status in
                    status.isSaving = false
                    status.lastMessage = success ? "视频已保存。" : nil
                    status.errorMessage = error?.localizedDescription
                }
                if success {
                    self?.clearStatusMessage("视频已保存。")
                }
            }
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
        if let error {
            publishStatus(error: error.localizedDescription)
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            publishStatus(error: "照片数据不可用。")
            return
        }

        savePhotoData(data)
    }
}

extension CameraController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        publishStatus { $0.isRecording = false }
        unlockVideoOrientationAfterRecording()

        if let error {
            publishStatus(error: error.localizedDescription)
            return
        }

        saveVideo(at: outputFileURL)
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
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
                frameHeight: height
            )
            previewFrameSink?.cameraController(
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
        let focalLength = longDimension / max(2 * tan(fieldOfViewRadians * 0.5), 0.001)
        return (focalLength, focalLength)
    }
}
