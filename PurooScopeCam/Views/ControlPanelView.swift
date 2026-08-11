import Foundation
import SwiftUI

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
    @State private var isEditing = false

    var body: some View {
        HStack(spacing: isEditing ? 10 : 7) {
            Image(systemName: "plus.magnifyingglass")
                .font(.system(size: isEditing ? 15 : 12, weight: .regular))
                .frame(width: isEditing ? 24 : 18)

            CompactZoomSlider(
                value: Binding(
                    get: { Double(camera.zoomFactor) },
                    set: { camera.setDisplayedZoomFactor(CGFloat($0)) }
                ),
                range: 1...6,
                isExpanded: isEditing,
                onEditingChanged: { editing in
                    withAnimation(.easeOut(duration: 0.18)) {
                        isEditing = editing
                    }
                }
            )

            Text(String(format: "%.1f×", camera.zoomFactor))
                .font(.system(size: isEditing ? 12 : 10, weight: .regular, design: .monospaced))
                .lineLimit(1)
                .frame(width: isEditing ? 46 : 38, alignment: .trailing)
        }
        .padding(.horizontal, isEditing ? 12 : 9)
        .frame(width: isEditing ? 310 : 210)
        .frame(height: isEditing ? 44 : 30)
        .foregroundStyle(.white)
        .background(.black.opacity(0.68), in: Capsule())
        .overlay {
            Capsule()
                .stroke(.white.opacity(isEditing ? 0.20 : 0.08), lineWidth: 0.8)
        }
        .animation(.easeOut(duration: 0.18), value: isEditing)
        .accessibilityLabel("调节变焦")
    }
}

private struct CompactZoomSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let isExpanded: Bool
    let onEditingChanged: (Bool) -> Void
    @State private var isDragging = false
    @State private var dragStartValue = 1.0

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let fraction = min(max((value - range.lowerBound) / rangeLength, 0), 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.24))
                    .frame(height: isExpanded ? 5 : 3)

                Capsule()
                    .fill(PurooBrandStyle.yellow)
                    .frame(
                        width: max(isExpanded ? 5 : 3, width * fraction),
                        height: isExpanded ? 5 : 3
                    )

                Circle()
                    .fill(.white)
                    .frame(width: isExpanded ? 20 : 14, height: isExpanded ? 20 : 14)
                    .shadow(color: .black.opacity(0.30), radius: 2, y: 1)
                    .offset(
                        x: min(
                            max(width * fraction - (isExpanded ? 10 : 7), 0),
                            max(width - (isExpanded ? 20 : 14), 0)
                        )
                    )
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            dragStartValue = value
                            onEditingChanged(true)
                        }
                        let delta = Double(gesture.translation.width / 220) * rangeLength
                        value = min(max(dragStartValue + delta, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: isExpanded ? 30 : 20)
    }

    private var rangeLength: Double {
        max(range.upperBound - range.lowerBound, 0.0001)
    }
}

struct ControlPanelView: View {
    private enum CaptureMode: String, CaseIterable {
        case video = "视频"
        case photo = "照片"
    }

    @EnvironmentObject private var camera: CameraController
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
        .background(Color.black)
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
        VStack(spacing: 1) {
            captureButton(size: 56)

            recordingStatus
                .frame(height: 10)

            HStack(spacing: 0) {
                libraryButton

                Spacer(minLength: 12)

                modeSelector

                Spacer(minLength: 12)

                burstButton
            }
            .padding(.horizontal, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .offset(y: 6)
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
                    .stroke(.white.opacity(isPhoto ? 1 : 0.38), lineWidth: 3)

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
        .accessibilityLabel(captureButtonAccessibilityLabel)
    }

    private var modeSelector: some View {
        HStack(spacing: 0) {
            ForEach(CaptureMode.allCases, id: \.self) { mode in
                Button {
                    guard !camera.status.isRecording else { return }
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
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.white.opacity(0.10), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开相册")
    }

    private var burstButton: some View {
        Button {
            camera.captureBurst()
        } label: {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.white.opacity(0.10), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(camera.status.isRecording)
        .opacity(camera.status.isRecording ? 0.42 : 1)
        .accessibilityLabel("连拍")
    }

    @ViewBuilder
    private var recordingStatus: some View {
        if camera.status.isRecording,
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
    .padding()
    .background(Color.black)
}
