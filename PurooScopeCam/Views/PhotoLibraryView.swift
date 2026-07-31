import AVFoundation
import AVKit
import Photos
import SwiftUI
import UIKit

struct PhotoLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @StateObject private var store = PhotoLibraryStore()
    @State private var selectedAssetID: String?

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            if let selectedAssetID,
               store.assets.contains(where: { $0.id == selectedAssetID }) {
                PhotoAssetViewer(
                    assets: store.assets,
                    initialAssetID: selectedAssetID,
                    onBack: { self.selectedAssetID = nil },
                    onCloseLibrary: { dismiss() }
                )
                .transition(.opacity)
            } else {
                libraryNavigation
            }
        }
        .preferredColorScheme(.dark)
        .task {
            store.activate()
        }
    }

    private var libraryNavigation: some View {
        NavigationStack {
            Group {
                switch store.authorizationStatus {
                case .authorized, .limited:
                    assetGrid
                case .notDetermined:
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .denied, .restricted:
                    permissionState
                @unknown default:
                    permissionState
                }
            }
            .background(Color.black)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("所有照片")
                            .font(.system(size: 16, weight: .regular))
                        if store.authorizationStatus == .authorized || store.authorizationStatus == .limited {
                            Text("\(store.assets.count) 项")
                                .font(.system(size: 10, weight: .light))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .regular))
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭相册")
                }
            }
        }
    }

    private var assetGrid: some View {
        ScrollView {
            if store.assets.isEmpty {
                ContentUnavailableView(
                    "没有照片或视频",
                    systemImage: "photo.on.rectangle.angled"
                )
                .font(.system(size: 14, weight: .light))
                .frame(maxWidth: .infinity)
                .padding(.top, 100)
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 4),
                    spacing: 1
                ) {
                    ForEach(store.assets) { item in
                        Button {
                            selectedAssetID = item.id
                        } label: {
                            PhotoAssetThumbnail(item: item)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.asset.mediaType == .video ? "视频" : "照片")
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .refreshable {
            store.reloadAssets()
        }
    }

    private var permissionState: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)

            Text("无法访问照片")
                .font(.system(size: 17, weight: .regular))

            Text("请在系统设置中允许 PUROO普徕 访问照片。")
                .font(.system(size: 13, weight: .light))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("打开设置") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                openURL(url)
            }
            .font(.system(size: 14, weight: .regular))
            .buttonStyle(.bordered)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PhotoLibraryAsset: Identifiable, Hashable {
    let asset: PHAsset

    var id: String {
        asset.localIdentifier
    }

    static func == (lhs: PhotoLibraryAsset, rhs: PhotoLibraryAsset) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

private final class PhotoLibraryStore: ObservableObject {
    @Published private(set) var authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var assets: [PhotoLibraryAsset] = []

    func activate() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch authorizationStatus {
        case .authorized, .limited:
            reloadAssets()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.authorizationStatus = status
                    if status == .authorized || status == .limited {
                        self.reloadAssets()
                    }
                }
            }
        default:
            break
        }
    }

    func reloadAssets() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: options)
        var fetchedAssets: [PhotoLibraryAsset] = []
        fetchedAssets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            fetchedAssets.append(PhotoLibraryAsset(asset: asset))
        }
        assets = fetchedAssets
    }
}

private struct PhotoAssetThumbnail: View {
    let item: PhotoLibraryAsset
    @State private var image: UIImage?
    @State private var requestID = PHInvalidImageRequestID

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                } else {
                    Color.white.opacity(0.06)
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.65))
                }

                if item.asset.mediaType == .video {
                    Label(videoDuration, systemImage: "video.fill")
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.58), in: Capsule())
                        .padding(4)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(Rectangle())
        .onAppear(perform: requestThumbnail)
        .onDisappear(perform: cancelRequest)
    }

    private var videoDuration: String {
        let total = max(Int(item.asset.duration.rounded()), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func requestThumbnail() {
        guard image == nil, requestID == PHInvalidImageRequestID else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        requestID = PHCachingImageManager.default().requestImage(
            for: item.asset,
            targetSize: CGSize(width: 360, height: 360),
            contentMode: .aspectFill,
            options: options
        ) { result, _ in
            guard let result else { return }
            DispatchQueue.main.async {
                image = result
            }
        }
    }

    private func cancelRequest() {
        guard requestID != PHInvalidImageRequestID else { return }
        PHCachingImageManager.default().cancelImageRequest(requestID)
        requestID = PHInvalidImageRequestID
    }
}

private struct PhotoAssetViewer: View {
    let assets: [PhotoLibraryAsset]
    let initialAssetID: String
    let onBack: () -> Void
    let onCloseLibrary: () -> Void

    @State private var currentAssetID: String
    @State private var isPreparingShare = false
    @State private var sharePayload: PhotoSharePayload?
    @State private var shareCleanupURL: URL?
    @State private var errorMessage: String?

    init(
        assets: [PhotoLibraryAsset],
        initialAssetID: String,
        onBack: @escaping () -> Void,
        onCloseLibrary: @escaping () -> Void
    ) {
        self.assets = assets
        self.initialAssetID = initialAssetID
        self.onBack = onBack
        self.onCloseLibrary = onCloseLibrary
        _currentAssetID = State(initialValue: initialAssetID)
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            TabView(selection: $currentAssetID) {
                ForEach(assets) { item in
                    PhotoAssetPage(
                        item: item,
                        isActive: item.id == currentAssetID
                    )
                    .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            viewerHeader
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            viewerFooter
        }
        .sheet(item: $sharePayload, onDismiss: cleanupSharedFile) { payload in
            PhotoActivityView(activityItems: [payload.url])
                .ignoresSafeArea()
        }
        .alert(
            "无法完成操作",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "所选内容暂时不可用。")
        }
    }

    private var viewerHeader: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Label("照片", systemImage: "chevron.left")
                    .font(.system(size: 14, weight: .regular))
                    .frame(minWidth: 64, minHeight: 40, alignment: .leading)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            VStack(spacing: 1) {
                Text(currentDateTitle)
                    .font(.system(size: 13, weight: .regular))
                    .lineLimit(1)
                Text(currentPositionTitle)
                    .font(.system(size: 10, weight: .light, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button(action: onCloseLibrary) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭相册")
        }
        .padding(.horizontal, 10)
        .frame(height: 50)
        .foregroundStyle(.white)
        .background(.black.opacity(0.88))
    }

    private var viewerFooter: some View {
        HStack {
            Button {
                prepareShare()
            } label: {
                if isPreparingShare {
                    ProgressView()
                        .tint(.white)
                        .frame(width: 42, height: 42)
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 19, weight: .regular))
                        .frame(width: 42, height: 42)
                }
            }
            .buttonStyle(.plain)
            .disabled(isPreparingShare)
            .accessibilityLabel("分享")

            Spacer()

            if let asset = currentAsset {
                Image(systemName: asset.asset.mediaType == .video ? "video.fill" : "photo")
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onBack) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 18, weight: .regular))
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回照片网格")
        }
        .padding(.horizontal, 14)
        .frame(height: 54)
        .foregroundStyle(.white)
        .background(.black.opacity(0.88))
    }

    private var currentAsset: PhotoLibraryAsset? {
        assets.first(where: { $0.id == currentAssetID })
    }

    private var currentPositionTitle: String {
        guard let index = assets.firstIndex(where: { $0.id == currentAssetID }) else { return "" }
        return "\(index + 1) / \(assets.count)"
    }

    private var currentDateTitle: String {
        guard let date = currentAsset?.asset.creationDate else { return "照片" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func prepareShare() {
        guard let asset = currentAsset?.asset,
              let resource = preferredResource(for: asset)
        else {
            errorMessage = "无法读取这个项目。"
            return
        }

        isPreparingShare = true
        let sourceExtension = URL(fileURLWithPath: resource.originalFilename).pathExtension
        let fallbackExtension = asset.mediaType == .video ? "mov" : "jpg"
        let fileExtension = sourceExtension.isEmpty ? fallbackExtension : sourceExtension
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("puroo-share-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        PHAssetResourceManager.default().writeData(
            for: resource,
            toFile: destination,
            options: options
        ) { error in
            DispatchQueue.main.async {
                isPreparingShare = false
                if let error {
                    try? FileManager.default.removeItem(at: destination)
                    errorMessage = error.localizedDescription
                } else {
                    shareCleanupURL = destination
                    sharePayload = PhotoSharePayload(url: destination)
                }
            }
        }
    }

    private func preferredResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        if asset.mediaType == .video {
            return resources.first(where: { $0.type == .fullSizeVideo })
                ?? resources.first(where: { $0.type == .video })
                ?? resources.first
        }
        return resources.first(where: { $0.type == .fullSizePhoto })
            ?? resources.first(where: { $0.type == .photo })
            ?? resources.first
    }

    private func cleanupSharedFile() {
        if let shareCleanupURL {
            try? FileManager.default.removeItem(at: shareCleanupURL)
        }
        shareCleanupURL = nil
        sharePayload = nil
    }
}

private struct PhotoAssetPage: View {
    let item: PhotoLibraryAsset
    let isActive: Bool

    var body: some View {
        switch item.asset.mediaType {
        case .image:
            PhotoAssetImagePage(asset: item.asset)
        case .video:
            PhotoAssetVideoPage(asset: item.asset, isActive: isActive)
        default:
            ContentUnavailableView("无法预览", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
    }
}

private struct PhotoAssetImagePage: View {
    let asset: PHAsset
    @State private var image: UIImage?
    @State private var requestID = PHInvalidImageRequestID

    var body: some View {
        ZStack {
            Color.black
            if let image {
                ZoomablePhotoView(image: image)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .onAppear(perform: requestImage)
        .onDisappear(perform: cancelRequest)
    }

    private func requestImage() {
        guard image == nil, requestID == PHInvalidImageRequestID else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        requestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 4096, height: 4096),
            contentMode: .aspectFit,
            options: options
        ) { result, _ in
            guard let result else { return }
            DispatchQueue.main.async {
                image = result
            }
        }
    }

    private func cancelRequest() {
        guard requestID != PHInvalidImageRequestID else { return }
        PHImageManager.default().cancelImageRequest(requestID)
        requestID = PHInvalidImageRequestID
    }
}

private struct PhotoAssetVideoPage: View {
    let asset: PHAsset
    let isActive: Bool
    @State private var player: AVPlayer?
    @State private var requestID = PHInvalidImageRequestID

    var body: some View {
        ZStack {
            Color.black
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .onAppear(perform: requestPlayerItem)
        .onDisappear {
            player?.pause()
            cancelRequest()
        }
        .onChange(of: isActive) { _, active in
            if active {
                player?.play()
            } else {
                player?.pause()
                player?.seek(to: .zero)
            }
        }
    }

    private func requestPlayerItem() {
        guard player == nil, requestID == PHInvalidImageRequestID else { return }
        let options = PHVideoRequestOptions()
        options.deliveryMode = .automatic
        options.isNetworkAccessAllowed = true
        requestID = PHImageManager.default().requestPlayerItem(
            forVideo: asset,
            options: options
        ) { item, _ in
            guard let item else { return }
            DispatchQueue.main.async {
                let newPlayer = AVPlayer(playerItem: item)
                player = newPlayer
                if isActive {
                    newPlayer.play()
                }
            }
        }
    }

    private func cancelRequest() {
        guard requestID != PHInvalidImageRequestID else { return }
        PHImageManager.default().cancelImageRequest(requestID)
        requestID = PHInvalidImageRequestID
    }
}

private struct ZoomablePhotoView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomablePhotoScrollView {
        ZoomablePhotoScrollView(image: image)
    }

    func updateUIView(_ view: ZoomablePhotoScrollView, context: Context) {
        view.setImage(image)
    }
}

private final class ZoomablePhotoScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var displayedImage: UIImage?
    private var previousBoundsSize = CGSize.zero

    init(image: UIImage) {
        super.init(frame: .zero)
        delegate = self
        backgroundColor = .black
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        bounces = true
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
            maximumZoomScale = max(fitScale * 8, 1)
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

        let targetScale = min(minimumZoomScale * 3, maximumZoomScale)
        let location = recognizer.location(in: imageView)
        let zoomSize = CGSize(
            width: bounds.width / targetScale,
            height: bounds.height / targetScale
        )
        zoom(
            to: CGRect(
                x: location.x - zoomSize.width * 0.5,
                y: location.y - zoomSize.height * 0.5,
                width: zoomSize.width,
                height: zoomSize.height
            ),
            animated: true
        )
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

private struct PhotoSharePayload: Identifiable {
    let id = UUID()
    let url: URL
}

private struct PhotoActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
