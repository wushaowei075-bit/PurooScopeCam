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

    var previewCropScale: CGFloat {
        switch self {
        case .off:
            return 1
        case .auto, .balanced, .strong:
            return 1.50
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

enum GyroAxisMapping: String, CaseIterable, Identifiable, Equatable {
    case xPositive
    case xNegative
    case yPositive
    case yNegative

    var id: String { rawValue }

    var title: String {
        switch self {
        case .xPositive:
            return "X正"
        case .xNegative:
            return "X反"
        case .yPositive:
            return "YX正"
        case .yNegative:
            return "YX反"
        }
    }

    var debugTitle: String {
        switch self {
        case .xPositive:
            return "X→横 -Y→竖"
        case .xNegative:
            return "-X→横 Y→竖"
        case .yPositive:
            return "Y→横 -X→竖"
        case .yNegative:
            return "-Y→横 X→竖"
        }
    }

    func map(x: Double, y: Double) -> (horizontal: Double, vertical: Double) {
        switch self {
        case .xPositive:
            return (x, -y)
        case .xNegative:
            return (-x, y)
        case .yPositive:
            return (y, -x)
        case .yNegative:
            return (-y, x)
        }
    }
}

struct StabilizationTuning: Equatable {
    var strength: Double
    var displayZoomFactor: CGFloat
    var motionTimeOffset: TimeInterval
    var gyroAxisMapping: GyroAxisMapping

    init(
        strength: Double,
        displayZoomFactor: CGFloat = 1,
        motionTimeOffset: TimeInterval = 0,
        gyroAxisMapping: GyroAxisMapping = .xPositive
    ) {
        self.strength = Swift.min(Swift.max(strength, 0), 1)
        self.displayZoomFactor = Swift.min(Swift.max(displayZoomFactor, 1), 6)
        self.motionTimeOffset = Swift.min(Swift.max(motionTimeOffset, -0.08), 0.08)
        self.gyroAxisMapping = gyroAxisMapping
    }

    var percentText: String {
        "\(Int((strength * 100).rounded()))%"
    }

    var usesDigitalStabilization: Bool {
        strength > 0.01
    }

    var previewCropScale: CGFloat {
        guard usesDigitalStabilization else { return 1 }
        return 1.50
    }

    var motionTimeOffsetMilliseconds: Double {
        motionTimeOffset * 1000
    }

    var previewCropTravelFactor: CGFloat {
        maximumCropOffsetFraction / max((previewCropScale - 1) * 0.5, 0.0001)
    }

    var previewDelayFrames: Int {
        usesDigitalStabilization ? 1 : 0
    }

    var motionSampleLookback: TimeInterval {
        0.14
    }

    var motionSampleLookahead: TimeInterval {
        0.055
    }

    var stabilizationAmount: CGFloat {
        guard usesDigitalStabilization else { return 0 }
        return min(1, 0.18 + CGFloat(effectiveStrength) * 0.82)
    }

    var staticFollowFrequency: Double {
        4.8 - effectiveStrength * 4.2
    }

    var panFollowFrequency: Double {
        12.0 - effectiveStrength * 3.0
    }

    var complementaryCutoffFrequency: Double {
        3.0
    }

    var panActivationSpeed: CGFloat {
        0.026 + CGFloat(effectiveStrength) * 0.012
    }

    var safeCropOffsetFraction: CGFloat {
        max(0, (previewCropScale - 1) * 0.5 * 0.80)
    }

    var maximumCropOffsetFraction: CGFloat {
        safeCropOffsetFraction * (0.72 + CGFloat(effectiveStrength) * 0.28)
    }

    var maximumTrajectoryVelocity: CGFloat {
        1.4
    }

    var maximumTrajectoryAcceleration: CGFloat {
        10
    }

    var maximumTrajectoryJerk: CGFloat {
        120
    }

    private var effectiveStrength: Double {
        guard strength > 0 else { return 0 }
        return Swift.min(1, pow(strength, 0.55))
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
    var quaternionX: Double
    var quaternionY: Double
    var quaternionZ: Double
    var quaternionW: Double
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
        quaternionX: 0,
        quaternionY: 0,
        quaternionZ: 0,
        quaternionW: 1,
        score: 0,
        band: .unavailable
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
