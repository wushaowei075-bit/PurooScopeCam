import Foundation
import SwiftUI
import UIKit

enum PurooBrandStyle {
    static let colors: [Color] = [
        Color(red: 1.00, green: 0.22, blue: 0.76),
        Color(red: 1.00, green: 0.48, blue: 0.44),
        Color(red: 1.00, green: 0.91, blue: 0.24),
        Color(red: 0.55, green: 0.94, blue: 0.31),
        Color(red: 0.24, green: 0.86, blue: 0.95)
    ]

    static var gradient: LinearGradient {
        LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }

    static let pink = Color(red: 1.00, green: 0.35, blue: 0.72)
    static let yellow = Color(red: 1.00, green: 0.90, blue: 0.24)
}

struct CameraAdjustmentBar: View {
    @EnvironmentObject private var camera: CameraController
    @State private var isDragging = false
    @State private var dragStartZoom: CGFloat = 1.5
    @State private var lastHapticPreset: CGFloat?

    private var minZoom: CGFloat {
        camera.isStabilizationEnabled ? 1.5 : 1.0
    }

    private var maxZoom: CGFloat {
        StabilizationTuning.maximumDisplayZoom
    }

    private var quickZoomPresets: [CGFloat] {
        camera.isStabilizationEnabled ? [1.5, 3.0, 6.0, 10.0] : [1.0, 3.0, 6.0, 10.0]
    }

    private var zoomFraction: CGFloat {
        let span = max(maxZoom - minZoom, 0.001)
        return min(max((camera.zoomFactor - minZoom) / span, 0), 1)
    }

    private var isAtPreset: Bool {
        quickZoomPresets.contains { abs(camera.zoomFactor - $0) < 0.12 }
    }

    var body: some View {
        GeometryReader { proxy in
            let barWidth = max(proxy.size.width, 1)
            ZStack(alignment: .bottomLeading) {
                // Subtle optical scale ticks integrated along bottom edge
                HStack(spacing: 0) {
                    ForEach(0..<25, id: \.self) { tick in
                        let tickFrac = CGFloat(tick) / 24.0
                        let passed = tickFrac <= zoomFraction + 0.01
                        Rectangle()
                            .fill(passed ? PurooBrandStyle.yellow.opacity(0.75) : Color.white.opacity(0.16))
                            .frame(width: 1, height: tick % 6 == 0 ? 5.5 : 3.0)
                        if tick < 24 {
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 3)

                // Continuous progress track fused along bottom
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [PurooBrandStyle.yellow.opacity(0.55), PurooBrandStyle.yellow],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(
                        width: max(12, (barWidth - 24) * zoomFraction),
                        height: isDragging ? 3.5 : 2.2
                    )
                    .padding(.leading, 12)
                    .padding(.bottom, 1.5)

                // Fused preset nodes + live readout in a single unified track
                HStack(spacing: 5) {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(isDragging ? PurooBrandStyle.yellow : .white.opacity(0.72))
                        .padding(.leading, 4)

                    ForEach(quickZoomPresets, id: \.self) { preset in
                        let isSelected = abs(camera.zoomFactor - preset) < 0.12
                        Button {
                            triggerSelectionHaptic()
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                                camera.setDisplayedZoomFactor(preset)
                            }
                        } label: {
                            Text(preset == floor(preset) ? String(format: "%.0f×", preset) : String(format: "%.1f×", preset))
                                .font(.system(size: 11, weight: isSelected ? .bold : .medium, design: .monospaced))
                                .foregroundStyle(isSelected ? .black : .white.opacity(0.90))
                                .frame(maxWidth: .infinity)
                                .frame(height: 25)
                                .background(
                                    isSelected
                                        ? PurooBrandStyle.yellow
                                        : Color.white.opacity(0.08),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    Divider()
                        .frame(height: 14)
                        .overlay(Color.white.opacity(0.20))
                        .padding(.horizontal, 1)

                    Text(String(format: "%.1f×", camera.zoomFactor))
                        .font(.system(size: 11.5, weight: (!isAtPreset || isDragging) ? .bold : .semibold, design: .monospaced))
                        .foregroundStyle((!isAtPreset || isDragging) ? .black : PurooBrandStyle.yellow)
                        .frame(width: 46, height: 25)
                        .background(
                            (!isAtPreset || isDragging)
                                ? PurooBrandStyle.yellow
                                : Color.white.opacity(0.06),
                            in: Capsule()
                        )
                }
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .contentShape(Capsule())
            .simultaneousGesture(
                DragGesture(minimumDistance: 7)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            dragStartZoom = camera.zoomFactor
                            lastHapticPreset = nil
                        }
                        let span = maxZoom - minZoom
                        let delta = (gesture.translation.width / max(barWidth - 30, 140)) * span
                        let nextZoom = min(max(dragStartZoom + delta, minZoom), maxZoom)
                        if let hitPreset = quickZoomPresets.first(where: { abs(nextZoom - $0) < 0.09 }) {
                            if lastHapticPreset != hitPreset {
                                lastHapticPreset = hitPreset
                                triggerSelectionHaptic()
                            }
                        } else {
                            lastHapticPreset = nil
                        }
                        camera.setDisplayedZoomFactor(nextZoom)
                    }
                    .onEnded { _ in
                        withAnimation(.easeOut(duration: 0.16)) {
                            isDragging = false
                        }
                    }
            )
        }
        .frame(maxWidth: isDragging ? 316 : 292)
        .frame(height: isDragging ? 40 : 36)
        .background(.black.opacity(0.72), in: Capsule())
        .overlay {
            Capsule()
                .stroke(
                    isDragging ? PurooBrandStyle.yellow.opacity(0.65) : Color.white.opacity(0.16),
                    lineWidth: isDragging ? 1.1 : 0.8
                )
        }
        .animation(.easeOut(duration: 0.16), value: isDragging)
        .accessibilityLabel("快捷档位与无级变焦条")
    }

    private func triggerSelectionHaptic() {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }
}

struct ControlPanelView: View {
    private enum CaptureMode: String, CaseIterable {
        case video = "视频"
        case photo = "照片"
    }

    @EnvironmentObject private var camera: CameraController
    @EnvironmentObject private var motionMonitor: MotionStabilityMonitor
    @State private var isPhotoLibraryPresented = false
    @State private var captureMode: CaptureMode = .photo
    @Namespace private var captureModeAnimation

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width > 520, proxy.size.height < 120 {
                compactLayout
            } else {
                portraitLayout
            }
        }
        .frame(maxWidth: .infinity)
        .fullScreenCover(isPresented: $isPhotoLibraryPresented) {
            PhotoLibraryView()
        }
        .onChange(of: camera.status.isRecording) { _, isRecording in
            if isRecording {
                withAnimation(modeTransitionAnimation) {
                    captureMode = .video
                }
            }
        }
    }

    private var portraitLayout: some View {
        VStack(spacing: 4) {
            recordingStatus.frame(height: 12)
            ZStack {
                captureButton(size: 72)

                if camera.status.isRecording {
                    recordingSnapButton(size: 48)
                        .offset(x: 82)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity)
            .animation(modeTransitionAnimation, value: camera.status.isRecording)

            Spacer(minLength: 4)
            HStack(spacing: 0) {
                libraryButton

                Spacer(minLength: 12)

                modeSelector

                Spacer(minLength: 12)

                burstButton
            }
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Color.black)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var compactLayout: some View {
        HStack(spacing: 16) {
            libraryButton
            modeSelector

            VStack(spacing: 2) {
                captureButton(size: 58)
                recordingStatus
                    .frame(height: 12)
            }

            burstButton
        }
        .frame(maxWidth: 410, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
        .background(Color.black)
    }

    private var shutterRingColor: Color {
        guard camera.isStabilizationEnabled else { return .white.opacity(captureMode == .photo ? 1 : 0.38) }
        switch motionMonitor.displaySample.band {
        case .stable:
            return Color(red: 0.12, green: 0.92, blue: 0.44)
        case .warning:
            return PurooBrandStyle.yellow
        case .heavy:
            return Color.orange
        case .unavailable:
            return .white.opacity(captureMode == .photo ? 1 : 0.38)
        }
    }

    private func captureButton(size: CGFloat) -> some View {
        let isPhoto = captureMode == .photo
        let isRecording = camera.status.isRecording
        let innerSize = isPhoto ? size - 14 : size * (isRecording ? 0.34 : 0.43)
        let innerCornerRadius = isPhoto || !isRecording ? innerSize / 2 : 5

        return Button {
            switch captureMode {
            case .photo:
                camera.capturePhoto()
            case .video:
                camera.toggleRecording()
            }
        } label: {
            ZStack {
                Circle()
                    .stroke(shutterRingColor, lineWidth: 3)

                RoundedRectangle(cornerRadius: innerCornerRadius, style: .continuous)
                    .fill(isPhoto ? Color.white : Color.red)
                    .frame(width: innerSize, height: innerSize)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .animation(modeTransitionAnimation, value: captureMode)
            .animation(modeTransitionAnimation, value: isRecording)
        }
        .buttonStyle(.plain)
        .disabled(camera.status.isFinishingRecording || camera.status.isCapturingPhoto || camera.status.isCapturingBurst || !camera.status.isSessionRunning)
        .accessibilityLabel(captureButtonAccessibilityLabel)
    }

    private var modeSelector: some View {
        HStack(spacing: 0) {
            ForEach(CaptureMode.allCases, id: \.self) { mode in
                Button {
                    guard !camera.status.isRecording, !camera.status.isCapturingPhoto, !camera.status.isCapturingBurst else { return }
                    withAnimation(modeTransitionAnimation) {
                        captureMode = mode
                    }
                } label: {
                    ZStack {
                        if captureMode == mode {
                            Capsule()
                                .fill(Color.white.opacity(0.12))
                                .matchedGeometryEffect(
                                    id: "capture-mode-selection",
                                    in: captureModeAnimation
                                )
                        }

                        Text(mode.rawValue)
                            .font(.system(size: 15, weight: .light))
                            .foregroundStyle(
                                captureMode == mode ? PurooBrandStyle.yellow : .white
                            )
                    }
                    .frame(width: 66, height: 34)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(camera.status.isRecording && captureMode != mode)
            }
        }
        .padding(3)
        .background(.white.opacity(0.07), in: Capsule())
        .overlay {
            Capsule()
                .stroke(.white.opacity(0.10), lineWidth: 0.8)
        }
    }

    private var libraryButton: some View {
        Button {
            isPhotoLibraryPresented = true
        } label: {
            ZStack {
                if let thumb = camera.latestThumbnailImage {
                    Image(uiImage: thumb)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())
                        .overlay {
                            Circle()
                                .stroke(PurooBrandStyle.yellow.opacity(0.85), lineWidth: 1.5)
                        }
                } else {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(.white.opacity(0.10), in: Circle())
                }
            }
            .frame(width: 46, height: 46)
        }
        .buttonStyle(.plain)
        .disabled(camera.status.isRecording || camera.status.isFinishingRecording || camera.status.isCapturingPhoto || camera.status.isCapturingBurst)
        .accessibilityLabel("打开相册")
    }

    private func recordingSnapButton(size: CGFloat) -> some View {
        Button {
            camera.captureStillWhileRecording()
        } label: {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.88), lineWidth: 2.2)

                Circle()
                    .fill(Color.white)
                    .frame(width: size - 9, height: size - 9)

                Image(systemName: "camera.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.85))
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
        .disabled(camera.status.isFinishingRecording)
        .accessibilityLabel("录像中无损抓拍")
    }

    private var burstButton: some View {
        Button {
            if camera.status.isRecording {
                camera.captureStillWhileRecording()
            } else {
                camera.captureBurst()
            }
        } label: {
            ZStack {
                if let progress = camera.burstProgressText {
                    Text(progress)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(PurooBrandStyle.yellow)
                } else if camera.status.isRecording {
                    VStack(spacing: 1) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text("抓拍")
                            .font(.system(size: 9.5, weight: .bold))
                    }
                    .foregroundStyle(.black)
                } else {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 46, height: 46)
            .background(
                camera.status.isRecording ? Color.white : Color.white.opacity(0.10),
                in: Circle()
            )
            .overlay {
                if camera.status.isRecording {
                    Circle().stroke(PurooBrandStyle.yellow, lineWidth: 1.5)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(camera.status.isFinishingRecording || camera.status.isCapturingPhoto || camera.status.isCapturingBurst || !camera.status.isSessionRunning)
        .accessibilityLabel(camera.status.isRecording ? "录像中抓拍照片" : "连拍")
    }

    @ViewBuilder
    private var recordingStatus: some View {
        if let burstProgress = camera.burstProgressText {
            Text("智能连拍优选 \(burstProgress)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(PurooBrandStyle.yellow)
                .lineLimit(1)
        } else if camera.status.isRecording,
           let startedAt = camera.status.recordingStartedAt {
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text(recordingTitle(at: context.date, startedAt: startedAt))
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        } else {
            Color.clear
        }
    }

    private var captureButtonAccessibilityLabel: String {
        switch captureMode {
        case .photo:
            return "拍照"
        case .video:
            return camera.status.isRecording ? "停止录像" : "开始录像"
        }
    }

    private func recordingTitle(at date: Date, startedAt: Date) -> String {
        let elapsed = max(Int(date.timeIntervalSince(startedAt)), 0)
        return String(format: "录制中 %02d:%02d", elapsed / 60, elapsed % 60)
    }

    private var modeTransitionAnimation: Animation {
        .spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.12)
    }
}

#Preview {
    VStack {
        CameraAdjustmentBar()
        ControlPanelView()
    }
    .environmentObject(CameraController())
    .environmentObject(MotionStabilityMonitor())
    .padding()
    .background(Color.black)
}
