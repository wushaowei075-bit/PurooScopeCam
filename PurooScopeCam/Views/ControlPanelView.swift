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
    @EnvironmentObject private var camera: CameraController
    @State private var isPhotoLibraryPresented = false

    var body: some View {
        GeometryReader { proxy in
            let rowWidth = min(proxy.size.width, 360)
            let fixedItemWidth: CGFloat = 264
            let itemSpacing = max(14, min(24, (rowWidth - fixedItemWidth) / 3))

            HStack(spacing: itemSpacing) {
                Button {
                    isPhotoLibraryPresented = true
                } label: {
                    utilityLabel(
                        systemImage: "photo.on.rectangle",
                        title: "相册"
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开相册")

                recordingButton

                photoButton

                Button {
                    camera.captureBurst()
                } label: {
                    utilityLabel(
                        systemImage: "square.stack.3d.up",
                        title: "连拍"
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("连拍")
            }
            .frame(width: rowWidth, height: proxy.size.height, alignment: .center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .fullScreenCover(isPresented: $isPhotoLibraryPresented) {
            PhotoLibraryView()
        }
    }

    private var recordingButton: some View {
        Button {
            camera.toggleRecording()
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.42), lineWidth: 2)
                    if camera.status.isRecording {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.red)
                            .frame(width: 18, height: 18)
                    } else {
                        Circle()
                            .fill(.red)
                            .frame(width: 24, height: 24)
                    }
                }
                .frame(width: 46, height: 46)

                recordingCaption
                    .font(.system(size: 9.5, weight: .light, design: .monospaced))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .frame(width: 86, height: 72)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(camera.status.isRecording ? "停止录像" : "开始录像")
    }

    @ViewBuilder
    private var recordingCaption: some View {
        if camera.status.isRecording,
           let startedAt = camera.status.recordingStartedAt {
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text(recordingTitle(at: context.date, startedAt: startedAt))
                    .foregroundStyle(.red)
            }
        } else {
            Text("录像")
                .foregroundStyle(.white)
        }
    }

    private var photoButton: some View {
        Button {
            camera.capturePhoto()
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .stroke(.white, lineWidth: 3)
                    Circle()
                        .fill(.white)
                        .padding(6)
                }
                .frame(width: 58, height: 58)

                Text("拍照")
                    .font(.system(size: 10, weight: .light))
                    .foregroundStyle(.white)
            }
            .frame(width: 70, height: 76)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("拍照")
    }

    private func utilityLabel(systemImage: String, title: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 21, weight: .light))
                .frame(width: 36, height: 34)
            Text(title)
                .font(.system(size: 10, weight: .light))
        }
        .foregroundStyle(.white)
        .frame(width: 54, height: 66)
    }

    private func recordingTitle(at date: Date, startedAt: Date) -> String {
        let elapsed = max(Int(date.timeIntervalSince(startedAt)), 0)
        return String(format: "录制中 %02d:%02d", elapsed / 60, elapsed % 60)
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
