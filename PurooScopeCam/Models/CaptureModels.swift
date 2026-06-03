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
            return "自动"
        case .balanced:
            return "均衡"
        case .strong:
            return "强力"
        }
    }

    var usesElectronicPreviewStabilization: Bool {
        switch self {
        case .off, .auto, .balanced, .strong:
            return false
        }
    }

    var usesCropWindowStabilization: Bool {
        switch self {
        case .off, .auto:
            return false
        case .balanced, .strong:
            return true
        }
    }

    var previewStabilizationGain: CGFloat {
        switch self {
        case .off, .auto:
            return 0
        case .balanced:
            return 600
        case .strong:
            return 760
        }
    }

    var previewCropScale: CGFloat {
        switch self {
        case .off, .auto:
            return 1
        case .balanced:
            return 1.12
        case .strong:
            return 1.18
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
        case .off, .auto:
            return 0
        case .balanced:
            return 0.50
        case .strong:
            return 0.56
        }
    }

    var visualHighPassLeakRate: Double {
        switch self {
        case .off, .auto:
            return 0
        case .balanced:
            return 6.0
        case .strong:
            return 6.5
        }
    }

    var visualHighPassResponseRate: Double {
        switch self {
        case .off, .auto:
            return 0
        case .balanced:
            return 22
        case .strong:
            return 24
        }
    }

    var visualHighPassMaximumOffset: CGFloat {
        switch self {
        case .off, .auto:
            return 0
        case .balanced:
            return 0.038
        case .strong:
            return 0.052
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
        case .off, .auto:
            return .infinity
        case .balanced:
            return 0.42
        case .strong:
            return 0.38
        }
    }

    var visualCorrectionMaximumStep: CGFloat {
        switch self {
        case .off, .auto:
            return 0
        case .balanced:
            return 0.0012
        case .strong:
            return 0.0015
        }
    }

    var visualAnalysisMinimumInterval: TimeInterval {
        switch self {
        case .off, .auto:
            return .infinity
        case .balanced:
            return 1.0 / 50.0
        case .strong:
            return 1.0 / 60.0
        }
    }

    var visualCorrectionSign: CGFloat {
        switch self {
        case .off, .auto:
            return 0
        case .balanced, .strong:
            return 1
        }
    }

    var visualPreviewDelayFrames: Int {
        switch self {
        case .off, .auto, .balanced, .strong:
            return 0
        }
    }

    var attitudeFollowRate: CGFloat {
        switch self {
        case .off, .auto:
            return 0
        case .balanced:
            return 1.95
        case .strong:
            return 1.35
        }
    }

    var gyroVelocityLeadGain: CGFloat {
        switch self {
        case .off, .auto:
            return 0
        case .balanced:
            return 20
        case .strong:
            return 24
        }
    }

    var gyroVelocityResponseRate: Double {
        switch self {
        case .off, .auto:
            return 0
        case .balanced:
            return 48
        case .strong:
            return 56
        }
    }

    var gyroVelocityNoiseFloor: Double {
        switch self {
        case .off, .auto:
            return .infinity
        case .balanced:
            return 0.026
        case .strong:
            return 0.024
        }
    }

    var rollVelocityLeadGain: CGFloat {
        switch self {
        case .off, .auto:
            return 0
        case .balanced:
            return 0.004
        case .strong:
            return 0.006
        }
    }

    var previewResponseRate: Double {
        switch self {
        case .off, .auto:
            return 0
        case .balanced:
            return 20
        case .strong:
            return 24
        }
    }

    var gyroMicroJitterGain: CGFloat {
        switch self {
        case .off, .auto:
            return 0
        case .balanced:
            return 1180
        case .strong:
            return 1480
        }
    }

    var gyroMicroJitterFollowRate: Double {
        switch self {
        case .off, .auto:
            return 0
        case .balanced:
            return 18
        case .strong:
            return 16
        }
    }

    var gyroMicroJitterLeakRate: Double {
        switch self {
        case .off, .auto:
            return 0
        case .balanced:
            return 3.5
        case .strong:
            return 3.0
        }
    }

    var gyroMicroJitterNoiseFloor: Double {
        switch self {
        case .off, .auto:
            return .infinity
        case .balanced:
            return 0.012
        case .strong:
            return 0.010
        }
    }

    var gyroMicroJitterAngleLimit: CGFloat {
        switch self {
        case .off, .auto:
            return 0
        case .balanced:
            return 0.0045
        case .strong:
            return 0.0062
        }
    }

    var gyroMicroRollGain: CGFloat {
        switch self {
        case .off, .auto:
            return 0
        case .balanced:
            return 0.055
        case .strong:
            return 0.075
        }
    }

    var requestedModes: [AVCaptureVideoStabilizationMode] {
        switch self {
        case .off:
            return [.off]
        case .auto:
            return [.auto]
        case .balanced:
            return [.standard, .auto]
        case .strong:
            return [.standard, .auto]
        }
    }

    var requestedPreviewModes: [AVCaptureVideoStabilizationMode] {
        switch self {
        case .off:
            return [.off]
        case .auto:
            return [.standard, .auto, .off]
        case .balanced:
            return [.standard, .auto, .off]
        case .strong:
            return [.standard, .auto, .off]
        }
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
