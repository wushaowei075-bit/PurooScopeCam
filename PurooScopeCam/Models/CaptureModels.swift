import AVFoundation
import CoreGraphics
import Foundation

struct CaptureQualityOption: Identifiable, Hashable {
    static let automatic = CaptureQualityOption(
        id: "auto",
        width: 0,
        height: 0,
        frameRate: 0,
        isAutomatic: true
    )

    let id: String
    let width: Int32
    let height: Int32
    let frameRate: Int
    let isAutomatic: Bool

    init(width: Int32, height: Int32, frameRate: Int) {
        self.id = "\(width)x\(height)@\(frameRate)"
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.isAutomatic = false
    }

    private init(
        id: String,
        width: Int32,
        height: Int32,
        frameRate: Int,
        isAutomatic: Bool
    ) {
        self.id = id
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.isAutomatic = isAutomatic
    }

    var title: String {
        if isAutomatic {
            return "自动"
        }

        return "\(verticalPixels)p \(frameRate)fps"
    }

    var shortTitle: String {
        if isAutomatic {
            return "自动画质"
        }

        return "\(verticalPixels)p/\(frameRate)"
    }

    var verticalPixels: Int32 {
        max(width, height)
    }

    var horizontalPixels: Int32 {
        min(width, height)
    }
}

enum StabilizationPreference: String, CaseIterable, Identifiable {
    case off
    case auto
    case balanced
    case strong

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:
            return "关闭"
        case .auto:
            return "轨迹增强"
        case .balanced:
            return "高频稳"
        case .strong:
            return "高频强"
        }
    }

    var usesElectronicPreviewStabilization: Bool {
        switch self {
        case .off:
            return false
        case .auto, .balanced, .strong:
            return true
        }
    }

    var usesCropWindowStabilization: Bool {
        switch self {
        case .off:
            return false
        case .auto, .balanced, .strong:
            return true
        }
    }

    var previewStabilizationGain: CGFloat {
        switch self {
        case .off:
            return 0
        case .auto:
            return 12000
        case .balanced:
            return 12000
        case .strong:
            return 15000
        }
    }

    var previewCropScale: CGFloat {
        switch self {
        case .off:
            return 1
        case .auto:
            return 1.55
        case .balanced:
            return 1.65
        case .strong:
            return 1.75
        }
    }

    var previewCropTravelFactor: CGFloat {
        switch self {
        case .off:
            return 0
        case .auto:
            return 0.82
        case .balanced:
            return 0.86
        case .strong:
            return 0.90
        }
    }

    var previewTranslationStepLimitFraction: CGFloat {
        switch self {
        case .off:
            return 0
        case .auto:
            return 0.050
        case .balanced, .strong:
            return 0
        }
    }

    var visualStabilizationGain: CGFloat {
        switch self {
        case .off, .auto, .balanced, .strong:
            return 0
        }
    }

    var visualHighPassCorrectionGain: CGFloat {
        switch self {
        case .off, .auto, .balanced, .strong:
            return 0
        }
    }

    var visualHighPassLeakRate: Double {
        switch self {
        case .off, .auto, .balanced, .strong:
            return 0
        }
    }

    var visualHighPassResponseRate: Double {
        switch self {
        case .off, .auto, .balanced, .strong:
            return 0
        }
    }

    var visualHighPassMaximumOffset: CGFloat {
        switch self {
        case .off, .auto, .balanced, .strong:
            return 0
        }
    }

    var visualMicroJitterCorrectionGain: CGFloat {
        return 0
    }

    var visualMicroJitterMaximumOffset: CGFloat {
        return 0
    }

    var visualShiftDeadZone: CGFloat {
        switch self {
        case .off:
            return .infinity
        case .auto, .balanced, .strong:
            return .greatestFiniteMagnitude
        }
    }

    var visualCorrectionMaximumStep: CGFloat {
        switch self {
        case .off, .auto, .balanced, .strong:
            return 0
        }
    }

    var visualAnalysisMinimumInterval: TimeInterval {
        switch self {
        case .off, .auto, .balanced, .strong:
            return .infinity
        }
    }

    var visualCorrectionSign: CGFloat {
        switch self {
        case .off, .auto, .balanced, .strong:
            return 0
        }
    }

    var visualPreviewDelayFrames: Int {
        switch self {
        case .off:
            return 0
        case .auto:
            return 0
        case .balanced:
            return 0
        case .strong:
            return 0
        }
    }

    var trajectorySmoothingAlpha: Double {
        switch self {
        case .off:
            return 0
        case .auto:
            return 0.985
        case .balanced:
            return 0.990
        case .strong:
            return 0.992
        }
    }

    var trajectoryRollGain: CGFloat {
        switch self {
        case .off:
            return 0
        case .auto:
            return 0.60
        case .balanced:
            return 0.75
        case .strong:
            return 0.90
        }
    }

    var attitudeFollowRate: CGFloat {
        switch self {
        case .off:
            return 0
        case .auto:
            return 34
        case .balanced, .strong:
            return 18
        }
    }

    var gyroVelocityLeadGain: CGFloat {
        switch self {
        case .off:
            return 0
        case .auto:
            return 150
        case .balanced, .strong:
            return 260
        }
    }

    var gyroVelocityResponseRate: Double {
        switch self {
        case .off:
            return 0
        case .auto:
            return 55
        case .balanced, .strong:
            return 96
        }
    }

    var gyroVelocityNoiseFloor: Double {
        switch self {
        case .off:
            return .infinity
        case .auto:
            return 0.004
        case .balanced, .strong:
            return 0.0015
        }
    }

    var rollVelocityLeadGain: CGFloat {
        switch self {
        case .off:
            return 0
        case .auto:
            return 0.018
        case .balanced:
            return 0.028
        case .strong:
            return -0.028
        }
    }

    var previewResponseRate: Double {
        switch self {
        case .off:
            return 0
        case .auto:
            return 48
        case .balanced, .strong:
            return 96
        }
    }

    var gyroMicroJitterGain: CGFloat {
        switch self {
        case .off:
            return 0
        case .auto:
            return 1700
        case .balanced, .strong:
            return 3200
        }
    }

    var gyroMicroJitterFollowRate: Double {
        switch self {
        case .off:
            return 0
        case .auto:
            return 8
        case .balanced, .strong:
            return 8
        }
    }

    var gyroMicroJitterLeakRate: Double {
        switch self {
        case .off:
            return 0
        case .auto:
            return 3.2
        case .balanced, .strong:
            return 3.0
        }
    }

    var gyroMicroJitterNoiseFloor: Double {
        switch self {
        case .off:
            return .infinity
        case .auto:
            return 0.0025
        case .balanced, .strong:
            return 0.0012
        }
    }

    var gyroMicroJitterAngleLimit: CGFloat {
        switch self {
        case .off:
            return 0
        case .auto:
            return 0.014
        case .balanced, .strong:
            return 0.018
        }
    }

    var gyroMicroRollGain: CGFloat {
        switch self {
        case .off:
            return 0
        case .auto:
            return 0.18
        case .balanced:
            return 0.28
        case .strong:
            return -0.28
        }
    }

    var requestedModes: [AVCaptureVideoStabilizationMode] {
        Self.lowLatencySystemStabilizationModes
    }

    var requestedPreviewModes: [AVCaptureVideoStabilizationMode] {
        Self.lowLatencySystemStabilizationModes
    }

    private static var lowLatencySystemStabilizationModes: [AVCaptureVideoStabilizationMode] {
        [.standard, .auto]
    }
}

struct StabilizationTuning: Equatable {
    var strength: Double

    init(strength: Double) {
        self.strength = Swift.min(Swift.max(strength, 0), 1)
    }

    var percentText: String {
        "\(Int((strength * 100).rounded()))%"
    }

    var usesDigitalStabilization: Bool {
        strength > 0.01
    }

    var previewCropScale: CGFloat {
        guard usesDigitalStabilization else { return 1 }
        let value = CGFloat(strength)
        return 1.18 + value * 0.52
    }

    var previewCropTravelFactor: CGFloat {
        let value = CGFloat(strength)
        return 0.68 + value * 0.18
    }

    var sampleWindowDuration: TimeInterval {
        0.06 + strength * 0.06
    }

    var trajectoryGain: CGFloat {
        let value = CGFloat(strength)
        return 2500 + value * 9000
    }

    var trajectorySmoothingAlpha: Double {
        0.86 + strength * 0.10
    }

    var trajectoryRollGain: CGFloat {
        let value = CGFloat(strength)
        return 0.18 + value * 0.42
    }

    var directSampleCount: Int {
        Int((4 + strength * 6).rounded())
    }

    var directNoiseFloor: Double {
        0.014 - strength * 0.006
    }

    var directGain: CGFloat {
        let value = CGFloat(strength)
        return 80 + value * 900
    }

    var directRollGain: CGFloat {
        let value = CGFloat(strength)
        return 0.001 + value * 0.006
    }

    var directResponseRate: Double {
        20 + strength * 40
    }

    var directLimitFraction: CGFloat {
        let value = CGFloat(strength)
        return 0.020 + value * 0.11
    }

    var directMaximumStepFraction: CGFloat {
        let value = CGFloat(strength)
        return 1.80 + value * 3.00
    }

    var rollLimit: CGFloat {
        let denominator = 78 - CGFloat(strength) * 28
        return .pi / denominator
    }
}

enum StabilityBand: Equatable {
    case stable
    case warning
    case heavy
    case unavailable

    var title: String {
        switch self {
        case .stable:
            return "稳定"
        case .warning:
            return "抖动"
        case .heavy:
            return "剧烈"
        case .unavailable:
            return "无传感器"
        }
    }
}

struct StabilitySample: Equatable {
    var timestamp: TimeInterval
    var angularVelocity: Double
    var rotationX: Double
    var rotationY: Double
    var rotationZ: Double
    var pitch: Double
    var roll: Double
    var yaw: Double
    var score: Double
    var band: StabilityBand

    static let unavailable = StabilitySample(
        timestamp: 0,
        angularVelocity: 0,
        rotationX: 0,
        rotationY: 0,
        rotationZ: 0,
        pitch: 0,
        roll: 0,
        yaw: 0,
        score: 0,
        band: .unavailable
    )
}

struct PreviewStabilizationState: Equatable {
    var normalizedX: CGFloat
    var normalizedY: CGFloat
    var confidence: CGFloat
    var timestamp: TimeInterval

    static let identity = PreviewStabilizationState(
        normalizedX: 0,
        normalizedY: 0,
        confidence: 0,
        timestamp: 0
    )
}

struct PreviewRenderTransform: Equatable {
    var scale: CGFloat
    var rotationRadians: CGFloat
    var translationX: CGFloat
    var translationY: CGFloat

    static let identity = PreviewRenderTransform(
        scale: 1,
        rotationRadians: 0,
        translationX: 0,
        translationY: 0
    )
}

struct CaptureStatus: Equatable {
    var activeStabilizationMode: AVCaptureVideoStabilizationMode = .off
    var activePreviewStabilizationMode: AVCaptureVideoStabilizationMode = .off
    var activeMovieStabilizationMode: AVCaptureVideoStabilizationMode = .off
    var isSessionRunning = false
    var isRecording = false
    var isSaving = false
    var lastMessage: String?
    var errorMessage: String?
}

extension AVCaptureVideoStabilizationMode {
    var scopeDisplayName: String {
        if #available(iOS 18.0, *), self == .cinematicExtendedEnhanced {
            return "增强"
        }

        switch self {
        case .off:
            return "关闭"
        case .standard:
            return "标准"
        case .cinematic:
            return "电影"
        case .cinematicExtended:
            return "扩展"
        case .auto:
            return "自动"
        @unknown default:
            return "未知"
        }
    }
}
