import AVKit
import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
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
    private enum Adjustment: Equatable {
        case zoom
        case exposure
    }

    @EnvironmentObject private var camera: CameraController
    @State private var adjustment: Adjustment = .zoom

    var body: some View {
        HStack(spacing: 10) {
            adjustmentButton(
                systemImage: "plus.magnifyingglass",
                label: "调节变焦",
                adjustment: .zoom
            )

            GradientValueSlider(value: adjustmentValue, range: adjustmentRange)

            Text(adjustmentValueText)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .frame(width: 52, alignment: .trailing)

            adjustmentButton(
                systemImage: "sun.max.fill",
                label: "调节曝光",
                adjustment: .exposure
            )
        }
        .padding(.horizontal, 11)
        .frame(height: 54)
        .foregroundStyle(.white)
        .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 8))
    }

    private var adjustmentValue: Binding<Double> {
        switch adjustment {
        case .zoom:
            return Binding(
                get: { Double(camera.zoomFactor) },
                set: { camera.setDisplayedZoomFactor(CGFloat($0)) }
            )
        case .exposure:
            return Binding(
                get: { Double(camera.exposureBias) },
                set: { camera.setExposureBias(Float($0)) }
            )
        }
    }

    private var adjustmentRange: ClosedRange<Double> {
        switch adjustment {
        case .zoom:
            return 1...6
        case .exposure:
            return -3...3
        }
    }

    private var adjustmentValueText: String {
        switch adjustment {
        case .zoom:
            return String(format: "%.1f×", camera.zoomFactor)
        case .exposure:
            return String(format: "%+.1f", camera.exposureBias)
        }
    }

    private func adjustmentButton(
        systemImage: String,
        label: String,
        adjustment nextAdjustment: Adjustment
    ) -> some View {
        Button {
            adjustment = nextAdjustment
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 38, height: 38)
                .foregroundStyle(adjustment == nextAdjustment ? .black : .white)
                .background(
                    adjustment == nextAdjustment ? Color.white : Color.white.opacity(0.13),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct GradientValueSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let fraction = min(max((value - range.lowerBound) / rangeLength, 0), 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.22))
                    .frame(height: 7)

                Capsule()
                    .fill(PurooBrandStyle.gradient)
                    .frame(width: max(7, width * fraction), height: 7)

                Circle()
                    .fill(.white)
                    .frame(width: 22, height: 22)
                    .shadow(color: .black.opacity(0.30), radius: 2, y: 1)
                    .offset(x: min(max(width * fraction - 11, 0), max(width - 22, 0)))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let nextFraction = min(max(gesture.location.x / width, 0), 1)
                        value = range.lowerBound + nextFraction * rangeLength
                    }
            )
        }
        .frame(height: 34)
    }

    private var rangeLength: Double {
        max(range.upperBound - range.lowerBound, 0.0001)
    }
}

struct ControlPanelView: View {
    @EnvironmentObject private var camera: CameraController
    @State private var albumSelection: PhotosPickerItem?
    @State private var previewMedia: AlbumPreviewMedia?
    @State private var isLoadingAlbumItem = false
    @State private var albumErrorMessage: String?

    var body: some View {
        HStack(spacing: 4) {
            PhotosPicker(
                selection: $albumSelection,
                matching: .any(of: [.images, .videos]),
                photoLibrary: .shared()
            ) {
                utilityLabel(
                    systemImage: "photo.on.rectangle",
                    title: "相册",
                    color: PurooBrandStyle.pink
                )
            }
            .accessibilityLabel("相册")

            Button {
                camera.toggleRecording()
            } label: {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.25), lineWidth: 3)
                    if camera.status.isRecording {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.red)
                            .frame(width: 22, height: 22)
                    } else {
                        Circle()
                            .fill(.red)
                            .frame(width: 28, height: 28)
                    }
                }
                .frame(width: 56, height: 56)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(camera.status.isRecording ? "停止录像" : "开始录像")

            Button {
                camera.capturePhoto()
            } label: {
                ZStack {
                    Circle()
                        .stroke(PurooBrandStyle.gradient, lineWidth: 7)
                    Circle()
                        .fill(.black)
                        .padding(8)
                    Circle()
                        .fill(.white)
                        .padding(11)
                }
                .frame(width: 76, height: 76)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("拍照")

            Button {
                camera.captureBurst()
            } label: {
                utilityLabel(
                    systemImage: "square.stack.3d.up.fill",
                    title: "连拍",
                    color: .white
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("连拍")

            Button {
                camera.setStabilizationEnabled(!camera.isStabilizationEnabled)
            } label: {
                VStack(spacing: 4) {
                    ZStack {
                        Capsule()
                            .fill(
                                camera.isStabilizationEnabled
                                    ? PurooBrandStyle.gradient
                                    : LinearGradient(
                                        colors: [.white.opacity(0.16), .white.opacity(0.08)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                            )
                        Image(systemName: camera.isStabilizationEnabled ? "checkmark" : "xmark")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(camera.isStabilizationEnabled ? .black : .white)
                    }
                    .frame(width: 64, height: 34)

                    Text("稳定")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white)
                }
                .frame(width: 68, height: 58)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(camera.isStabilizationEnabled ? "关闭稳定" : "开启稳定")
        }
        .frame(maxWidth: .infinity)
        .overlay {
            if isLoadingAlbumItem {
                ProgressView()
                    .tint(.white)
                    .padding(10)
                    .background(.black.opacity(0.72), in: Circle())
            }
        }
        .onChange(of: albumSelection) { _, item in
            loadAlbumSelection(item)
        }
        .fullScreenCover(item: $previewMedia) { media in
            AlbumMediaPreview(media: media)
        }
        .alert(
            "无法预览",
            isPresented: Binding(
                get: { albumErrorMessage != nil },
                set: { if !$0 { albumErrorMessage = nil } }
            )
        ) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(albumErrorMessage ?? "所选内容暂时不可用。")
        }
    }

    private func utilityLabel(
        systemImage: String,
        title: String,
        color: Color
    ) -> some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .medium))
                .frame(width: 44, height: 34)
            Text(title)
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(color)
        .frame(width: 50, height: 58)
    }

    private func loadAlbumSelection(_ item: PhotosPickerItem?) {
        guard let item else { return }
        isLoadingAlbumItem = true

        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw AlbumPreviewError.dataUnavailable
                }
                let media: AlbumPreviewMedia
                if item.supportedContentTypes.contains(where: { $0.conforms(to: .image) }),
                   let image = UIImage(data: data) {
                    media = AlbumPreviewMedia(content: .image(image))
                } else if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                    let fileExtension = item.supportedContentTypes
                        .compactMap(\.preferredFilenameExtension)
                        .first ?? "mov"
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("puroo-album-\(UUID().uuidString)")
                        .appendingPathExtension(fileExtension)
                    try data.write(to: url, options: .atomic)
                    media = AlbumPreviewMedia(content: .video(url))
                } else {
                    throw AlbumPreviewError.unsupportedContent
                }

                await MainActor.run {
                    previewMedia = media
                    albumSelection = nil
                    isLoadingAlbumItem = false
                }
            } catch {
                await MainActor.run {
                    albumSelection = nil
                    isLoadingAlbumItem = false
                    albumErrorMessage = error.localizedDescription
                }
            }
        }
    }
}

private struct AlbumPreviewMedia: Identifiable {
    enum Content {
        case image(UIImage)
        case video(URL)
    }

    let id = UUID()
    let content: Content
}

private enum AlbumPreviewError: LocalizedError {
    case dataUnavailable
    case unsupportedContent

    var errorDescription: String? {
        switch self {
        case .dataUnavailable:
            return "无法读取所选照片或视频。"
        case .unsupportedContent:
            return "暂不支持预览这种媒体格式。"
        }
    }
}

private struct AlbumMediaPreview: View {
    @Environment(\.dismiss) private var dismiss
    let media: AlbumPreviewMedia

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
                .ignoresSafeArea()

            switch media.content {
            case .image(let image):
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .video(let url):
                AlbumVideoPreview(url: url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(.white)
                    .background(.black.opacity(0.64), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
            .padding(.trailing, 14)
            .accessibilityLabel("关闭预览")
        }
    }
}

private struct AlbumVideoPreview: View {
    @State private var player: AVPlayer

    init(url: URL) {
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VideoPlayer(player: player)
            .onAppear { player.play() }
            .onDisappear { player.pause() }
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
