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
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .lineLimit(1)
                .frame(width: 48, alignment: .trailing)

            adjustmentButton(
                systemImage: "sun.max.fill",
                label: "调节曝光",
                adjustment: .exposure
            )
        }
        .padding(.horizontal, 11)
        .frame(height: 48)
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
                .font(.system(size: 15, weight: .regular))
                .frame(width: 32, height: 32)
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
                    .frame(height: 6)

                Capsule()
                    .fill(PurooBrandStyle.gradient)
                    .frame(width: max(6, width * fraction), height: 6)

                Circle()
                    .fill(.white)
                    .frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.30), radius: 2, y: 1)
                    .offset(x: min(max(width * fraction - 9, 0), max(width - 18, 0)))
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
        .frame(height: 30)
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
        HStack(spacing: 0) {
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
            .frame(maxWidth: .infinity)

            Button {
                camera.toggleRecording()
            } label: {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.25), lineWidth: 3)
                    if camera.status.isRecording {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.red)
                            .frame(width: 19, height: 19)
                    } else {
                        Circle()
                            .fill(.red)
                            .frame(width: 25, height: 25)
                    }
                }
                .frame(width: 50, height: 50)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(camera.status.isRecording ? "停止录像" : "开始录像")
            .frame(maxWidth: .infinity)

            Button {
                camera.capturePhoto()
            } label: {
                ZStack {
                    Circle()
                        .stroke(PurooBrandStyle.gradient, lineWidth: 5)
                    Circle()
                        .fill(.black)
                        .padding(8)
                    Circle()
                        .fill(.white)
                        .padding(11)
                }
                .frame(width: 66, height: 66)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("拍照")
            .frame(maxWidth: .infinity)

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
            .frame(maxWidth: .infinity)

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
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(camera.isStabilizationEnabled ? .black : .white)
                    }
                    .frame(width: 58, height: 30)

                    Text("稳定")
                        .font(.system(size: 11, weight: .light))
                        .foregroundStyle(.white)
                }
                .frame(width: 60, height: 54)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(camera.isStabilizationEnabled ? "关闭稳定" : "开启稳定")
            .frame(maxWidth: .infinity)
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
                .font(.system(size: 20, weight: .regular))
                .frame(width: 40, height: 30)
            Text(title)
                .font(.system(size: 11, weight: .light))
        }
        .foregroundStyle(color)
        .frame(width: 48, height: 54)
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
        ZStack {
            Color.black
                .ignoresSafeArea()

            switch media.content {
            case .image(let image):
                ZoomableAlbumImageView(image: image)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .video(let url):
                AlbumVideoPreview(url: url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .regular))
                        .frame(width: 42, height: 42)
                        .foregroundStyle(.white)
                        .background(.black.opacity(0.62), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭预览")
            }
            .padding(.horizontal, 10)
            .frame(height: 48)
            .background(.black.opacity(0.42))
        }
        .onDisappear {
            if case .video(let url) = media.content {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

private struct ZoomableAlbumImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomableImageScrollView {
        ZoomableImageScrollView(image: image)
    }

    func updateUIView(_ view: ZoomableImageScrollView, context: Context) {
        view.setImage(image)
    }
}

private final class ZoomableImageScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var displayedImage: UIImage?
    private var previousBoundsSize = CGSize.zero

    init(image: UIImage) {
        super.init(frame: .zero)
        delegate = self
        backgroundColor = .black
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        bouncesZoom = true
        decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        setImage(image)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setImage(_ image: UIImage) {
        guard displayedImage !== image else { return }
        displayedImage = image
        imageView.image = image
        imageView.frame = CGRect(origin: .zero, size: image.size)
        contentSize = image.size
        previousBoundsSize = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 1, bounds.height > 1,
              let image = displayedImage,
              image.size.width > 0, image.size.height > 0
        else {
            return
        }

        if bounds.size != previousBoundsSize {
            let oldMinimum = minimumZoomScale
            let wasAtMinimum = previousBoundsSize == .zero || abs(zoomScale - oldMinimum) < 0.01
            let fitScale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            minimumZoomScale = fitScale
            maximumZoomScale = max(fitScale * 6, 1)
            if wasAtMinimum {
                zoomScale = fitScale
            } else {
                zoomScale = min(max(zoomScale, fitScale), maximumZoomScale)
            }
            previousBoundsSize = bounds.size
        }
        centerImage()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale * 1.05 {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }

        let targetScale = min(max(minimumZoomScale * 2.5, minimumZoomScale), maximumZoomScale)
        let location = recognizer.location(in: imageView)
        let zoomSize = CGSize(
            width: bounds.width / targetScale,
            height: bounds.height / targetScale
        )
        let zoomRect = CGRect(
            x: location.x - zoomSize.width * 0.5,
            y: location.y - zoomSize.height * 0.5,
            width: zoomSize.width,
            height: zoomSize.height
        )
        zoom(to: zoomRect, animated: true)
    }

    private func centerImage() {
        let horizontalInset = max((bounds.width - contentSize.width) * 0.5, 0)
        let verticalInset = max((bounds.height - contentSize.height) * 0.5, 0)
        imageView.center = CGPoint(
            x: contentSize.width * 0.5 + horizontalInset,
            y: contentSize.height * 0.5 + verticalInset
        )
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
