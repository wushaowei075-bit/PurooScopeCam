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

        return "\(resolutionTitle) \(frameRate)帧"
    }

    var shortTitle: String {
        if isAutomatic {
            return "自动画质"
        }

        return "\(resolutionTitle)/\(frameRate)"
    }

    var verticalPixels: Int32 {
        min(width, height)
    }

    var horizontalPixels: Int32 {
        max(width, height)
    }

    private var resolutionTitle: String {
        verticalPixels >= 2160 ? "4K" : "\(verticalPixels)p"
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

/// 外接望远镜的角放大倍率。
///
/// 相机内参矩阵只描述手机镜头本身，完全感知不到目镜之后的光学系统，
/// 因此陀螺仪角位移换算成画面位移时必须额外乘上这个倍率。
struct TelescopeMagnificationOption: Identifiable, Hashable {
    static let minimum: Double = 1
    static let maximum: Double = 30

    static let presets: [TelescopeMagnificationOption] = [
        TelescopeMagnificationOption(value: 1),
        TelescopeMagnificationOption(value: 8),
        TelescopeMagnificationOption(value: 10),
        TelescopeMagnificationOption(value: 12),
        TelescopeMagnificationOption(value: 15),
        TelescopeMagnificationOption(value: 20),
        TelescopeMagnificationOption(value: 25)
    ]

    let value: Double

    var id: String { String(format: "%.0f", value) }

    var title: String {
        value <= 1.0001 ? "裸机" : "\(Int(value.rounded()))×"
    }
}

struct StabilizationTuning: Equatable {
    static let defaultOpticalMagnification: Double = 10

    var isEnabled: Bool
    var displayZoomFactor: CGFloat
    var motionTimeOffset: TimeInterval
    var opticalMagnification: Double

    init(
        isEnabled: Bool,
        displayZoomFactor: CGFloat = 1,
        motionTimeOffset: TimeInterval = 0,
        opticalMagnification: Double = StabilizationTuning.defaultOpticalMagnification
    ) {
        self.isEnabled = isEnabled
        self.displayZoomFactor = Swift.min(Swift.max(displayZoomFactor, 1), 6)
        self.motionTimeOffset = Swift.min(Swift.max(motionTimeOffset, -0.08), 0.08)
        self.opticalMagnification = Swift.min(
            Swift.max(opticalMagnification, TelescopeMagnificationOption.minimum),
            TelescopeMagnificationOption.maximum
        )
    }

    var usesDigitalStabilization: Bool {
        isEnabled
    }

    /// 1.5 倍裁切在稳定余量和望远镜视场之间取平衡。
    var previewCropScale: CGFloat {
        guard usesDigitalStabilization else { return 1 }
        return 1.50
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

    var highFrequencyCompensationAmount: CGFloat {
        guard usesDigitalStabilization else { return 0 }
        return 1.0
    }

    /// 低频承担 0.5-7 Hz 的轨迹补偿。
    ///
    /// 在修正裁切几何后，全量输出会在静止画面形成约 30% 的反向
    /// 过补偿。6f33b17 成片逐帧拟合的横纵轴最优增益分别为 0.70/0.73，
    /// 取 0.72；7 Hz 以上的细抖仍由高频通道保持全量补偿。
    var lowFrequencyStabilizationAmount: CGFloat {
        guard usesDigitalStabilization else { return 0 }
        return 0.72
    }

    /// 判定为平移后虚拟相机跟随真实路径的带宽。
    ///
    /// 6 Hz（26 ms）等于瞬间贴合真实路径：`desired - lowPath` 立刻趋零，
    /// 补偿量随之归零，稳像在平移期间完全失效。
    ///
    /// 0.9 Hz 对应约 175 ms，实测平移跟手且平滑，停止时也没有回拉。
    var panFollowFrequency: Double {
        0.9
    }

    /// 互补滤波分频点：低于此频率走虚拟相机轨迹，高于此频率走泄漏积分。
    ///
    /// 3 Hz 正好劈开 2-4 Hz 这个手持抖动主带。落到高频通道的那一半会被
    /// 0.30 s 泄漏严重衰减——该频带周期 0.25-0.5 s，与时间常数同量级。
    /// 实测低频分量 RMS 0.0018 反而小于高频 0.0025，能量分配是反的，
    /// 频谱上 2-4 Hz 残留达到参考产品的 1.54 倍，为各频带最差。
    ///
    /// 提到 7 Hz 让整个手抖主带走轨迹控制器，由冻结的 desired 提供完整
    /// 补偿；高频通道只保留 7 Hz 以上，泄漏时间常数对其影响可忽略。
    var complementaryCutoffFrequency: Double {
        7.0
    }

    /// 进入平移状态的画面速度阈值，按光学放大倍率缩放。
    ///
    /// 阈值作用在归一化画面速度上，而望远镜把角速度放大了约 11.5 倍，
    /// 手部漂移在画面上的速度同样被放大。裸机标定出来的固定阈值因此
    /// 在望远镜下形同虚设，轻微手抖就会被判成有意平移。
    var panActivationSpeed: CGFloat {
        0.030 * CGFloat(max(opticalMagnification, 1))
    }

    /// 裁切窗口可以移动的范围，占裁切预留的比例。
    ///
    /// 1.5x 裁切在每侧留出 0.25 的行程，这里用掉其中 92%，剩余部分
    /// 作为软限幅的缓冲以免出现黑边。
    var safeCropOffsetFraction: CGFloat {
        max(0, (previewCropScale - 1) * 0.5 * 0.92)
    }

    var maximumCropOffsetFraction: CGFloat {
        safeCropOffsetFraction
    }

    /// 高频补偿的泄漏时间常数。
    ///
    /// 0.12 s 下快速振荡正负相消、累积不起来，实测高频分量只贡献了
    /// 约 0.002 的裁切量。加长到 0.30 s 让一个抖动周期内的补偿真正成形。
    var highFrequencyMemory: Double {
        0.30
    }

    /// 虚拟相机跟随真实滚转的带宽。
    ///
    /// 比平移的跟随更慢：握持姿势带来的滚转漂移很缓慢，而抖动部分应当
    /// 全部抵消。0.4 Hz 约 400 ms，足以跟上有意的转腕，又不会放过手抖。
    var rollFollowFrequency: Double {
        guard usesDigitalStabilization else { return 0 }
        return 0.4
    }

    /// 旋转补偿的角度上限，取平移未占用的行程。
    ///
    /// 旋转会把裁切窗口的包围盒撑大：1.5 倍裁切下 720x1280 的窗口转 3 度，
    /// 包围盒变成 786x1316。平移未用满时这点富余吃得下，一旦平移逼近
    /// 0.23 的极限，二者叠加就会越过源图边界露出黑边。按剩余行程线性缩放
    /// 是保守但可靠的约束——实测滚转补偿量典型在 1 度以内，不会被限制住。
    func maximumRollRadians(cropUsage: CGFloat) -> CGFloat {
        guard usesDigitalStabilization else { return 0 }
        let ceiling = 2.5 * .pi / 180
        return ceiling * Swift.max(0, 1 - cropUsage)
    }

    /// 触及裁切边界后回收的带宽。
    ///
    /// 补偿加强后会更频繁地压到边界，8 Hz 的回收速度会让画面出现可见的
    /// 拉回。降到 4 Hz 换取平滑，代价是边界附近的余量恢复得慢一些。
    var boundaryFollowFrequency: Double {
        4.0
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
        default:
            return "未知"
        }
    }
}
