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

private struct CameraControlRotationKey: EnvironmentKey {
    static let defaultValue: Double = 0
}

extension EnvironmentValues {
    var cameraControlDegrees: Double {
        get { self[CameraControlRotationKey.self] }
        set { self[CameraControlRotationKey.self] = newValue }
    }
}

private struct CameraControlRotation: ViewModifier {
    @Environment(\.cameraControlDegrees) private var degrees

    func body(content: Content) -> some View {
        content.rotationEffect(.degrees(degrees))
            .animation(.easeInOut(duration: 0.22), value: degrees)
    }
}

extension View {
    func cameraControlRotation() -> some View { modifier(CameraControlRotation()) }
}


struct ControlPanelView: View {
    private enum CaptureMode: String, CaseIterable {
        case video = "视频"
        case photo = "照片"
    }

    @EnvironmentObject private var camera: CameraController
    @EnvironmentObject private var motionMonitor: MotionStabilityMonitor
    @Environment(\.cameraControlDegrees) private var controlDegrees
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
            recordingStatus.cameraControlRotation().frame(height: 24)
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

    private var shutterRingColor: Color { .white.opacity(captureMode == .photo ? 1 : 0.55) }

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
                            .cameraControlRotation()
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
                } else {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(.white.opacity(0.10), in: Circle())
                }
            }
            .cameraControlRotation()
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
                    .cameraControlRotation()
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
        .disabled(camera.status.isFinishingRecording)
        .accessibilityLabel("录像中抓拍防抖照片")
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
            .cameraControlRotation()
            .frame(width: 46, height: 46)
            .background(
                camera.status.isRecording ? Color.white : Color.white.opacity(0.10),
                in: Circle()
            )
        }
        .buttonStyle(.plain)
        .disabled(camera.status.isFinishingRecording || camera.status.isCapturingPhoto || camera.status.isCapturingBurst || !camera.status.isSessionRunning)
        .accessibilityLabel(camera.status.isRecording ? "录像中抓拍照片" : "连拍")
    }

    @ViewBuilder
    private var recordingStatus: some View {
        if let burstProgress = camera.burstProgressText {
            Text(controlDegrees == 0 ? "智能连拍优选 \(burstProgress)" : burstProgress)
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
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
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
        return String(format: controlDegrees == 0 ? "录制中 %02d:%02d" : "录制中\n%02d:%02d", elapsed / 60, elapsed % 60)
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
