import AVFoundation
import CoreGraphics
import Foundation

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
            return 650
        case .strong:
            return 1120
        }
    }

    var previewCropScale: CGFloat {
        switch self {
        case .off, .auto:
            return 1
        case .balanced:
            return 1.28
        case .strong:
            return 1.5
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
            return 1.22
        case .strong:
            return 1.45
        }
    }

    var visualHighPassLeakRate: Double {
        switch self {
        case .off, .auto:
            return 0
        case .balanced:
            return 7.0
        case .strong:
            return 4.2
        }
    }

    var visualHighPassResponseRate: Double {
        switch self {
        case .off, .auto:
            return 0
        case .balanced:
            return 42
        case .strong:
            return 72
        }
    }

    var visualHighPassMaximumOffset: CGFloat {
        switch self {
        case .off, .auto:
            return 0
        case .balanced:
            return 0.08
        case .strong:
            return 0.13
        }
    }

    var visualAnalysisMinimumInterval: TimeInterval {
        switch self {
        case .off, .auto:
            return .infinity
        case .balanced:
            return 1.0 / 40.0
        case .strong:
            return 1.0 / 55.0
        }
    }

    var visualPreviewDelayFrames: Int {
        switch self {
        case .off, .auto:
            return 0
        case .balanced:
            return 3
        case .strong:
            return 4
        }
    }

    var attitudeFollowRate: CGFloat {
        switch self {
        case .off, .auto:
            return 0
        case .balanced:
            return 1.75
        case .strong:
            return 0.92
        }
    }

    var gyroVelocityLeadGain: CGFloat {
        switch self {
        case .off, .auto:
            return 0
        case .balanced:
            return 34
        case .strong:
            return 58
        }
    }

    var gyroVelocityResponseRate: Double {
        switch self {
        case .off, .auto:
            return 0
        case .balanced:
            return 80
        case .strong:
            return 130
        }
    }

    var gyroVelocityNoiseFloor: Double {
        switch self {
        case .off, .auto:
            return .infinity
        case .balanced:
            return 0.018
        case .strong:
            return 0.012
        }
    }

    var rollVelocityLeadGain: CGFloat {
        switch self {
        case .off, .auto:
            return 0
        case .balanced:
            return 0.008
        case .strong:
            return 0.018
        }
    }

    var previewResponseRate: Double {
        switch self {
        case .off, .auto:
            return 0
        case .balanced:
            return 27
        case .strong:
            return 48
        }
    }

    var gyroMicroJitterGain: CGFloat {
        switch self {
        case .off, .auto:
            return 0
        case .balanced:
            return 2800
        case .strong:
            return 5600
        }
    }

    var gyroMicroJitterFollowRate: Double {
        switch self {
        case .off, .auto:
            return 0
        case .balanced:
            return 8.5
        case .strong:
            return 5.2
        }
    }

    var gyroMicroJitterLeakRate: Double {
        switch self {
        case .off, .auto:
            return 0
        case .balanced:
            return 1.4
        case .strong:
            return 0.9
        }
    }

    var gyroMicroJitterNoiseFloor: Double {
        switch self {
        case .off, .auto:
            return .infinity
        case .balanced:
            return 0.006
        case .strong:
            return 0.0025
        }
    }

    var gyroMicroJitterAngleLimit: CGFloat {
        switch self {
        case .off, .auto:
            return 0
        case .balanced:
            return 0.008
        case .strong:
            return 0.014
        }
    }

    var gyroMicroRollGain: CGFloat {
        switch self {
        case .off, .auto:
            return 0
        case .balanced:
            return 0.12
        case .strong:
            return 0.22
        }
    }

    var requestedModes: [AVCaptureVideoStabilizationMode] {
        switch self {
        case .off:
            return [.off]
        case .auto:
            return [.auto]
        case .balanced:
            return [.cinematicExtended, .cinematic, .standard, .auto]
        case .strong:
            if #available(iOS 18.0, *) {
                return [.cinematicExtendedEnhanced, .cinematicExtended, .cinematic, .standard, .auto]
            } else {
                return [.cinematicExtended, .cinematic, .standard, .auto]
            }
        }
    }

    var requestedPreviewModes: [AVCaptureVideoStabilizationMode] {
        switch self {
        case .off:
            return [.off]
        case .auto:
            return [.auto]
        case .balanced:
            return [.cinematic, .standard, .auto]
        case .strong:
            return [.cinematic, .standard, .auto]
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
