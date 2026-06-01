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
            return 1500
        case .strong:
            return 3000
        }
    }

    var previewCropScale: CGFloat {
        switch self {
        case .off, .auto:
            return 1
        case .balanced:
            return 1.65
        case .strong:
            return 2.35
        }
    }

    var visualStabilizationGain: CGFloat {
        switch self {
        case .off, .auto:
            return 0
        case .balanced:
            return 0.7
        case .strong:
            return 1.2
        }
    }

    var attitudeFollowRate: CGFloat {
        switch self {
        case .off, .auto:
            return 0
        case .balanced:
            return 0.85
        case .strong:
            return 0.28
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
