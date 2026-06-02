import AVFoundation
import Combine
import Photos
import UIKit

protocol CameraFrameSink: AnyObject {
    func cameraController(
        _ controller: CameraController,
        didOutput pixelBuffer: CVPixelBuffer,
        at timestamp: CMTime
    )
}

protocol StabilizedRecordingFrameSink: AnyObject {
    var isStabilizedRecording: Bool { get }

    func startStabilizedRecording(
        to outputURL: URL,
        completion: @escaping (Result<URL, Error>) -> Void
    )
    func stopStabilizedRecording()
}

final class CameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published private(set) var authorizationStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var status = CaptureStatus()
    @Published var stabilizationPreference: StabilizationPreference = .balanced {
        didSet {
            videoOutputQueue.async { [weak self] in
                self?.stabilizationEngine.reset()
                self?.publishPreviewStabilizationState(.identity)
            }
            applySelectedStabilizationMode()
        }
    }
    @Published var zoomFactor: CGFloat = 1
    @Published var exposureBias: Float = 0
    @Published private(set) var focusLocked = false
    @Published private(set) var exposureLocked = false
    @Published private(set) var previewStabilizationState: PreviewStabilizationState = .identity

    private let sessionQueue = DispatchQueue(label: "com.puroo.scope.camera.session")
    private let videoOutputQueue = DispatchQueue(label: "com.puroo.scope.camera.videoOutput", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let stabilizationEngine = FrameStabilizationEngine()

    private var videoDeviceInput: AVCaptureDeviceInput?
    private weak var previewFrameSink: CameraFrameSink?
    private weak var previewRecordingSink: StabilizedRecordingFrameSink?
    private var isConfigured = false

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

    func configurePreviewConnection(_ connection: AVCaptureConnection?) {
        sessionQueue.async { [weak self] in
            self?.applyStabilization(to: connection)
        }
    }

    func setPreviewFrameSink(_ sink: CameraFrameSink?) {
        videoOutputQueue.async { [weak self] in
            self?.previewFrameSink = sink
            self?.previewRecordingSink = sink as? StabilizedRecordingFrameSink
        }
    }

    func ingestMotionSample(_ sample: StabilitySample) {
        videoOutputQueue.async { [weak self] in
            self?.stabilizationEngine.ingestMotion(sample)
        }
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

            self.isConfigured = true
            self.startSession()
        }
    }

    private func configureDeviceDefaults(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            configurePreferredVideoFormat(device)
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
            device.unlockForConfiguration()
        } catch {
            publishStatus(error: "无法配置相机默认参数。")
        }
    }

    private func configurePreferredVideoFormat(_ device: AVCaptureDevice) {
        let preferredFrameRates = [60.0, 30.0]
        let preferredSizes = [
            CMVideoDimensions(width: 1920, height: 1080),
            CMVideoDimensions(width: 1280, height: 720)
        ]

        var bestCandidate: (format: AVCaptureDevice.Format, frameRate: Double, score: Int)?

        for format in device.formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width <= 1920, dimensions.height <= 1080 else { continue }

            let supportedFrameRate = preferredFrameRates.first { frameRate in
                format.videoSupportedFrameRateRanges.contains { range in
                    range.minFrameRate <= frameRate && range.maxFrameRate >= frameRate
                }
            }
            guard let frameRate = supportedFrameRate else { continue }

            let sizeRank = preferredSizes.firstIndex { preferred in
                preferred.width == dimensions.width && preferred.height == dimensions.height
            } ?? preferredSizes.count
            let sizeScore = max(0, 300 - sizeRank * 80)
            let frameRateScore = Int(frameRate * 10)
            let stabilizationScore = format.isVideoStabilizationModeSupported(.standard) ? 120 : 0
            let pixelCountPenalty = Int(dimensions.width * dimensions.height / 100_000)
            let score = frameRateScore + sizeScore + stabilizationScore - pixelCountPenalty

            if bestCandidate.map({ score > $0.score }) ?? true {
                bestCandidate = (format: format, frameRate: frameRate, score: score)
            }
        }

        guard let bestCandidate else { return }

        device.activeFormat = bestCandidate.format
        let frameDuration = CMTime(
            value: 1,
            timescale: CMTimeScale(bestCandidate.frameRate.rounded())
        )
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
    }

    private func configureVideoOutput() {
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: videoOutputQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
            configureVideoOutputConnection()
        }
    }

    private func configureVideoOutputConnection() {
        guard let connection = videoOutput.connection(with: .video) else { return }
        if connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        if connection.isVideoMirroringSupported {
            connection.isVideoMirrored = false
        }
        applyPreviewStabilization(to: connection)
    }

    private func configurePhotoOutput() {
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
    }

    private func configureMovieOutput() {
        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }
    }

    private func startRecording() {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured else { return }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("puroo-scope-\(UUID().uuidString)")
                .appendingPathExtension("mov")

            if let previewRecordingSink = self.previewRecordingSink {
                guard !previewRecordingSink.isStabilizedRecording else { return }
                previewRecordingSink.startStabilizedRecording(to: url) { [weak self] result in
                    guard let self else { return }
                    self.publishStatus { $0.isRecording = false }

                    switch result {
                    case .success(let outputURL):
                        self.saveVideo(at: outputURL)
                    case .failure(let error):
                        try? FileManager.default.removeItem(at: url)
                        self.publishStatus(error: error.localizedDescription)
                    }
                }
                self.publishStatus { $0.isRecording = true }
                return
            }

            guard !self.movieOutput.isRecording else { return }
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
        apply(selectedStabilizationMode: selected, to: connection)
    }

    private func applyPreviewStabilization(to connection: AVCaptureConnection?) {
        guard let connection else { return }
        let selected = bestAvailableMode(for: connection, requestedModes: stabilizationPreference.requestedPreviewModes)
        apply(selectedStabilizationMode: selected, to: connection)
    }

    private func apply(selectedStabilizationMode selected: AVCaptureVideoStabilizationMode, to connection: AVCaptureConnection) {
        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = selected
            publishStatus { status in
                status.activeStabilizationMode = connection.activeVideoStabilizationMode
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
    }

    private func publishStatus(_ update: @escaping (inout CaptureStatus) -> Void) {
        DispatchQueue.main.async {
            update(&self.status)
        }
    }

    private func publishPreviewStabilizationState(_ state: PreviewStabilizationState) {
        DispatchQueue.main.async {
            self.previewStabilizationState = state
        }
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
            previewFrameSink?.cameraController(self, didOutput: pixelBuffer, at: timestamp)
        }
    }
}
