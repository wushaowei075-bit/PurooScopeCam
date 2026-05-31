import AVFoundation
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
            return "Off"
        case .auto:
            return "Auto"
        case .balanced:
            return "Balanced"
        case .strong:
            return "Strong"
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
            return "Stable"
        case .warning:
            return "Shake"
        case .heavy:
            return "Heavy"
        case .unavailable:
            return "No Motion"
        }
    }
}

struct StabilitySample: Equatable {
    var timestamp: TimeInterval
    var angularVelocity: Double
    var score: Double
    var band: StabilityBand

    static let unavailable = StabilitySample(
        timestamp: 0,
        angularVelocity: 0,
        score: 0,
        band: .unavailable
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
            return "Enhanced"
        }

        switch self {
        case .off:
            return "Off"
        case .standard:
            return "Standard"
        case .cinematic:
            return "Cinematic"
        case .cinematicExtended:
            return "Extended"
        case .auto:
            return "Auto"
        @unknown default:
            return "Unknown"
        }
    }
}
