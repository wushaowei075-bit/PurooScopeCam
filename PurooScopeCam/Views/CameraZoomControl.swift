import SwiftUI
import UIKit

struct CameraAdjustmentBar: View {
    @EnvironmentObject private var camera: CameraController
    @State private var isExpanded = false

    private var scale: CameraZoomScale {
        CameraZoomScale(
            baseline: camera.isStabilizationEnabled ? 1.5 : 1,
            maximumDisplayZoom: camera.maximumZoomControlFactor
        )
    }

    private var zoom: CGFloat { scale.relativeZoom(for: camera.zoomControlFactor) }

    var body: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
                ForEach(CameraZoomScale.presets, id: \.self) { preset in
                    let selected = selectedPreset == preset
                    Text(selected ? zoomTitle : String(format: "%.0f", preset))
                        .font(.system(size: selected ? 14 : 15, weight: .regular))
                        .monospacedDigit()
                        .foregroundStyle(selected ? PurooBrandStyle.yellow : .white)
                        .frame(width: selected ? 40 : 32, height: selected ? 40 : 32)
                        .background(.black.opacity(selected ? 0.72 : 0.46), in: Circle())
                        .frame(width: 54, height: 48)
                }
            }
            .opacity(isExpanded ? 0 : 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            // This touch surface never changes size or identity during a gesture.
            CameraZoomTouchSurface(
                zoom: zoom, scale: scale,
                onZoom: { camera.setDisplayedZoomFactor(scale.displayZoom(for: $0)) },
                onExpansion: { expanded in
                    DispatchQueue.main.async { isExpanded = expanded }
                }
            )
        }
        .frame(width: 288, height: 70)
        .overlay(alignment: .bottom) {
            if isExpanded {
                continuousScale
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .animation(.easeOut(duration: 0.16), value: isExpanded)
    }

    private var selectedPreset: CGFloat {
        CameraZoomScale.presets.min { abs(log(zoom / $0)) < abs(log(zoom / $1)) } ?? 1
    }

    private var zoomTitle: String {
        abs(zoom - zoom.rounded()) < 0.025
            ? String(format: "%.0f×", zoom)
            : String(format: "%.1f×", zoom)
    }

    private var continuousScale: some View {
        VStack(spacing: 5) {
            Text(zoomTitle)
                .font(.system(size: 17, weight: .regular))
                .monospacedDigit()
                .foregroundStyle(PurooBrandStyle.yellow)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    HStack(alignment: .center, spacing: 0) {
                        ForEach(0..<41, id: \.self) { tick in
                            Rectangle()
                                .fill(Color.white.opacity(tick % 5 == 0 ? 0.8 : 0.35))
                                .frame(width: 1, height: tick % 5 == 0 ? 15 : 8)
                            if tick < 40 { Spacer(minLength: 0) }
                        }
                    }
                    Capsule()
                        .fill(PurooBrandStyle.yellow)
                        .frame(width: 3, height: 22)
                        .offset(x: (proxy.size.width - 3) * scale.fraction(for: zoom))
                }
                .frame(height: 22)
            }
            .frame(height: 22)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(width: 288, height: 70)
        .background(.black.opacity(0.78), in: Capsule())
    }
}

private struct CameraZoomTouchSurface: UIViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    let zoom: CGFloat
    let scale: CameraZoomScale
    let onZoom: (CGFloat) -> Void
    let onExpansion: (Bool) -> Void

    func makeUIView(context: Context) -> ZoomTouchView { ZoomTouchView() }

    func updateUIView(_ view: ZoomTouchView, context: Context) {
        view.configure(zoom: zoom, scale: scale, enabled: isEnabled, onZoom: onZoom, onExpansion: onExpansion)
    }

    static func dismantleUIView(_ view: ZoomTouchView, coordinator: ()) {
        view.finishInteraction()
    }
}

private final class ZoomTouchView: UIView {
    private var zoom: CGFloat = 1
    private var scale = CameraZoomScale(baseline: 1.5, maximumDisplayZoom: 30)
    private var visibility = CameraZoomVisibility()
    private var dismissal: DispatchWorkItem?
    private var onZoom: (CGFloat) -> Void = { _ in }
    private var onExpansion: (Bool) -> Void = { _ in }
    private var drag = CameraZoomDrag()
    private var originX: CGFloat = 0
    private var buttons: [UIButton] = []
    private var lastHapticPreset: CGFloat?
    private let haptic = UISelectionFeedbackGenerator()
    private lazy var hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        for (index, preset) in CameraZoomScale.presets.enumerated() {
            let button = UIButton(type: .custom)
            button.tag = index
            button.accessibilityLabel = String(format: "变焦 %.0f 倍", preset)
            button.accessibilityHint = "点按切换；按住展开连续变焦"
            button.addTarget(self, action: #selector(selectPreset(_:)), for: .touchUpInside)
            addSubview(button)
            buttons.append(button)
        }
        hold.minimumPressDuration = 0.22
        hold.allowableMovement = 14
        // Once the hold begins, UIButton receives cancellation, never a trailing tap.
        hold.cancelsTouchesInView = true
        addGestureRecognizer(hold)
        NotificationCenter.default.addObserver(self, selector: #selector(interruptInteraction),
                                               name: UIApplication.willResignActiveNotification, object: nil)
    }

    deinit {
        dismissal?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width: CGFloat = 54
        let left = (bounds.width - width * CGFloat(buttons.count)) / 2
        for (index, button) in buttons.enumerated() {
            button.frame = CGRect(x: left + CGFloat(index) * width, y: bounds.height - 48, width: width, height: 48)
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let target = visibility.isExpanded ? bounds
            : CGRect(x: (bounds.width - 216) / 2, y: bounds.height - 48, width: 216, height: 48)
        return target.contains(point)
    }

    func configure(zoom: CGFloat, scale: CameraZoomScale, enabled: Bool,
                   onZoom: @escaping (CGFloat) -> Void, onExpansion: @escaping (Bool) -> Void) {
        self.onZoom = onZoom
        self.onExpansion = onExpansion
        if self.scale != scale || !enabled {
            let wasActive = drag.startZoom != nil
            finishInteraction()
            if wasActive {
                hold.isEnabled = false
                hold.isEnabled = enabled
            }
        }
        self.zoom = zoom
        self.scale = scale
        hold.isEnabled = enabled
        isUserInteractionEnabled = enabled
        updateAccessibility()
    }

    private func updateAccessibility() {
        isAccessibilityElement = visibility.isExpanded
        accessibilityLabel = "连续变焦"
        accessibilityValue = String(format: "%.1f 倍", zoom)
        accessibilityTraits = .adjustable
        for (index, button) in buttons.enumerated() {
            let preset = CameraZoomScale.presets[index]
            button.isEnabled = isUserInteractionEnabled && preset <= scale.maximum
            button.accessibilityElementsHidden = visibility.isExpanded
            button.accessibilityTraits = abs(zoom - preset) < 0.025 ? [.button, .selected] : .button
            button.accessibilityValue = String(format: "当前 %.1f 倍", zoom)
        }
    }

    @objc private func selectPreset(_ button: UIButton) {
        guard drag.startZoom == nil, !visibility.isExpanded else { return }
        haptic.selectionChanged()
        onZoom(CameraZoomScale.presets[button.tag])
    }

    @objc private func handleHold(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            dismissal?.cancel()
            visibility.begin()
            originX = gesture.location(in: self).x
            drag.begin(at: zoom)
            lastHapticPreset = nil
            haptic.prepare()
            haptic.selectionChanged()
            updateAccessibility()
            onExpansion(true)
        case .changed:
            guard let next = drag.update(translation: gesture.location(in: self).x - originX, scale: scale) else { return }
            let preset = CameraZoomScale.presets.first { abs(next - $0) < 0.035 }
            if let preset, preset != lastHapticPreset { haptic.selectionChanged() }
            lastHapticPreset = preset
            onZoom(next)
        case .ended:
            releaseInteraction()
        case .cancelled, .failed:
            guard drag.startZoom != nil else { return }
            finishInteraction()
        default:
            break
        }
    }

    private func releaseInteraction() {
        drag.end()
        lastHapticPreset = nil
        visibility.release(at: ProcessInfo.processInfo.systemUptime)
        // While the scale lingers, a new touch resumes it immediately, without selecting a hidden preset.
        hold.minimumPressDuration = 0
        scheduleDismissal()
    }

    private func scheduleDismissal() {
        dismissal?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self,
                  self.visibility.hideIfExpired(at: ProcessInfo.processInfo.systemUptime) else { return }
            self.hold.minimumPressDuration = 0.22
            self.updateAccessibility()
            self.onExpansion(false)
        }
        dismissal = task
        DispatchQueue.main.asyncAfter(deadline: .now() + CameraZoomVisibility.lingerDuration, execute: task)
    }

    override func accessibilityIncrement() { adjustAccessibleZoom(multiplier: 1.1) }
    override func accessibilityDecrement() { adjustAccessibleZoom(multiplier: 1 / 1.1) }

    private func adjustAccessibleZoom(multiplier: CGFloat) {
        onZoom(scale.clamp(zoom * multiplier))
        visibility.begin()
        releaseInteraction()
    }

    @objc private func interruptInteraction() {
        finishInteraction()
        hold.isEnabled = false
        hold.isEnabled = isUserInteractionEnabled
    }

    func finishInteraction() {
        let wasExpanded = visibility.isExpanded
        dismissal?.cancel()
        drag.end()
        visibility.cancel()
        lastHapticPreset = nil
        hold.minimumPressDuration = 0.22
        updateAccessibility()
        if wasExpanded { onExpansion(false) }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { finishInteraction() }
    }
}
