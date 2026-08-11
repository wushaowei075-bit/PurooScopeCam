import AVFoundation
import Combine
import SwiftUI
import UIKit

struct CameraScreen: View {
    @EnvironmentObject private var camera: CameraController
    @EnvironmentObject private var motionMonitor: MotionStabilityMonitor
    @Environment(\.scenePhase) private var scenePhase
    @State private var interfaceOrientation: UIInterfaceOrientation = .portrait
    @State private var isQualityDialogPresented = false
    @State private var isMagnificationDialogPresented = false
    @State private var focusIndicator: FocusIndicatorState?
    @State private var focusDismissToken = UUID()

    var body: some View {
        GeometryReader { proxy in
            let isLandscape = proxy.size.width > proxy.size.height
            let headerHeight: CGFloat = isLandscape ? 34 : 40
            let bottomSafeInset = max(proxy.safeAreaInsets.bottom, isLandscape ? 4 : 8)
            let layout = cameraLayoutMetrics(
                screenSize: proxy.size,
                bottomSafeInset: bottomSafeInset,
                isLandscape: isLandscape
            )

            ZStack {
                Color.black
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    ZStack(alignment: .top) {
                        Color.black

                        cameraViewport(
                            size: layout.previewSize,
                            topControlInset: headerHeight + 8
                        )
                        .frame(width: layout.previewSize.width, height: layout.previewSize.height)
                        .overlay(alignment: .top) {
                            brandHeader
                                .frame(height: headerHeight)
                                .background(
                                    LinearGradient(
                                        colors: [.black.opacity(0.58), .black.opacity(0.08)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        }
                    }
                    .frame(
                        width: layout.previewAreaSize.width,
                        height: layout.previewAreaSize.height
                    )

                    ControlPanelView()
                        .frame(maxWidth: .infinity)
                        .frame(height: layout.controlsContentHeight)
                        .padding(.bottom, bottomSafeInset)
                        .background(Color.black)
                }
                .ignoresSafeArea(edges: .bottom)

                if camera.authorizationStatus != .authorized {
                    Color.black.opacity(0.90)
                        .ignoresSafeArea()
                    permissionPanel
                        .frame(maxWidth: 320)
                        .padding(24)
                }
            }
        }
        .ignoresSafeArea(.container, edges: .horizontal)
        .task {
            camera.requestAccessAndConfigure()
            motionMonitor.start()
            synchronizeOrientationWithScene()
        }
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            updateOrientation(from: UIDevice.current.orientation)
        }
        .onDisappear {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            updateOrientation(from: UIDevice.current.orientation)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                camera.startSession()
                motionMonitor.start()
            case .background:
                camera.stopSession()
                motionMonitor.stop()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .confirmationDialog(
            "分辨率与帧率",
            isPresented: $isQualityDialogPresented,
            titleVisibility: .visible
        ) {
            ForEach(camera.captureQualityOptions) { option in
                Button(option == camera.activeCaptureQuality ? "✓ \(option.title)" : option.title) {
                    camera.captureQualityPreference = option
                }
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(
            "望远镜光学倍率",
            isPresented: $isMagnificationDialogPresented,
            titleVisibility: .visible
        ) {
            ForEach(TelescopeMagnificationOption.presets) { option in
                Button(
                    abs(option.value - camera.telescopeMagnification) < 0.01
                        ? "✓ \(option.title)"
                        : option.title
                ) {
                    camera.setTelescopeMagnification(option.value)
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var brandHeader: some View {
        HStack(spacing: 8) {
            Text("PUROO 普徕")
                .font(.system(size: 18, weight: .light))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .foregroundStyle(PurooBrandStyle.gradient)

            if camera.status.isRecording {
                Circle()
                    .fill(.red)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel("正在录像")
            }

            Spacer(minLength: 12)

            HStack(spacing: 5) {
                Text("稳定")
                    .font(.system(size: 11, weight: .light))
                    .foregroundStyle(.white.opacity(0.82))

                Toggle(
                    "稳定",
                    isOn: Binding(
                        get: { camera.isStabilizationEnabled },
                        set: { camera.setStabilizationEnabled($0) }
                    )
                )
                .labelsHidden()
                .tint(.green)
                .scaleEffect(0.78)
                .frame(width: 43, height: 28)
            }
        }
        .padding(.horizontal, 14)
    }

    private func cameraViewport(size: CGSize, topControlInset: CGFloat) -> some View {
        ZStack {
            CameraPreviewView(
                camera: camera,
                motionMonitor: motionMonitor,
                stabilizationPreference: camera.stabilizationPreference,
                isStabilizationEnabled: camera.isStabilizationEnabled,
                opticalMagnification: camera.telescopeMagnification,
                displayZoomFactor: camera.zoomFactor,
                systemStabilizationModeName: camera.status.activePreviewStabilizationMode.scopeDisplayName
            )

            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture()
                        .onEnded { value in
                            focus(at: value.location, in: size)
                        }
                )

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        isQualityDialogPresented = true
                    } label: {
                        Text(qualityBadgeTitle)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .frame(minWidth: 58, minHeight: 38)
                            .padding(.horizontal, 7)
                            .foregroundStyle(.black)
                            .background(PurooBrandStyle.gradient, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(camera.status.isRecording || camera.captureQualityOptions.count <= 1)
                    .accessibilityLabel("分辨率与帧率")

                    Button {
                        isMagnificationDialogPresented = true
                    } label: {
                        Label(
                            "\(camera.telescopeMagnification, specifier: "%.0f")×",
                            systemImage: "binoculars"
                        )
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .foregroundStyle(.black)
                        .background(
                            LinearGradient(
                                colors: [PurooBrandStyle.yellow, Color(red: 0.78, green: 0.98, blue: 0.34)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("望远镜倍率")

                    Spacer(minLength: 72)
                }

                Spacer(minLength: 0)

                if let message = camera.status.errorMessage ?? camera.status.lastMessage {
                    statusCapsule(text: message, systemImage: "exclamationmark.circle.fill")
                }

                CameraAdjustmentBar()
            }
            .padding(.top, topControlInset)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            if let focusIndicator {
                FocusReticleView()
                    .frame(width: 70, height: 70)
                    .position(focusReticlePosition(for: focusIndicator, in: size))
                    .transition(.scale(scale: 1.18).combined(with: .opacity))
                    .allowsHitTesting(false)

                FocusExposureControl(
                    value: Binding(
                        get: { Double(camera.exposureBias) },
                        set: { camera.setExposureBias(Float($0)) }
                    ),
                    onEditingChanged: handleExposureEditing
                )
                .frame(width: 36, height: 116)
                .position(exposureControlPosition(for: focusIndicator, in: size))
                .transition(.opacity)
            }
        }
        .clipped()
        .animation(.easeOut(duration: 0.18), value: focusIndicator?.id)
    }

    private func statusCapsule(text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 11, weight: .regular))
            .lineLimit(1)
            .padding(.horizontal, 13)
            .frame(height: 30)
            .foregroundStyle(.white)
            .background(.black.opacity(0.62), in: Capsule())
    }

    private var qualityBadgeTitle: String {
        let option = camera.activeCaptureQuality
        guard !option.isAutomatic else { return "自动\n画质" }
        let resolution = option.verticalPixels >= 2160 ? "4K" : "\(option.verticalPixels)p"
        return "\(resolution)\n\(option.frameRate)帧"
    }

    private var permissionPanel: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(PurooBrandStyle.gradient)
            Text("需要相机权限")
                .font(.system(size: 17, weight: .regular))
            Text("请在系统设置中开启相机权限，然后返回应用。")
                .font(.system(size: 14, weight: .light))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func fittedPreviewSize(in containerSize: CGSize, isLandscape: Bool) -> CGSize {
        guard containerSize.width > 0, containerSize.height > 0 else { return .zero }
        let targetAspect: CGFloat = isLandscape ? 16.0 / 9.0 : 9.0 / 16.0
        let containerAspect = containerSize.width / containerSize.height
        if containerAspect > targetAspect {
            return CGSize(
                width: containerSize.height * targetAspect,
                height: containerSize.height
            )
        }
        return CGSize(
            width: containerSize.width,
            height: containerSize.width / targetAspect
        )
    }

    private func cameraLayoutMetrics(
        screenSize: CGSize,
        bottomSafeInset: CGFloat,
        isLandscape: Bool
    ) -> CameraLayoutMetrics {
        let minimumControlsContentHeight: CGFloat = isLandscape ? 82 : 108
        let targetAspect: CGFloat = isLandscape ? 16.0 / 9.0 : 9.0 / 16.0
        let fullWidthPreviewHeight = screenSize.width / targetAspect
        let fullWidthControlsContentHeight = screenSize.height
            - fullWidthPreviewHeight
            - bottomSafeInset

        if !isLandscape {
            let previewSize = CGSize(
                width: screenSize.width,
                height: fullWidthPreviewHeight
            )
            let previewAreaHeight: CGFloat
            let controlsContentHeight: CGFloat
            if fullWidthControlsContentHeight >= minimumControlsContentHeight {
                previewAreaHeight = fullWidthPreviewHeight
                controlsContentHeight = fullWidthControlsContentHeight
            } else {
                previewAreaHeight = max(
                    screenSize.height - minimumControlsContentHeight - bottomSafeInset,
                    1
                )
                controlsContentHeight = minimumControlsContentHeight
            }
            return CameraLayoutMetrics(
                previewSize: previewSize,
                previewAreaSize: CGSize(
                    width: screenSize.width,
                    height: previewAreaHeight
                ),
                controlsContentHeight: controlsContentHeight
            )
        }

        let previewAreaSize = CGSize(
            width: screenSize.width,
            height: max(
                screenSize.height - minimumControlsContentHeight - bottomSafeInset,
                1
            )
        )
        return CameraLayoutMetrics(
            previewSize: fittedPreviewSize(in: previewAreaSize, isLandscape: isLandscape),
            previewAreaSize: previewAreaSize,
            controlsContentHeight: minimumControlsContentHeight
        )
    }

    private func focus(at location: CGPoint, in previewSize: CGSize) {
        guard previewSize.width > 1, previewSize.height > 1 else { return }
        let normalizedPoint = CGPoint(
            x: min(max(location.x / previewSize.width, 0), 1),
            y: min(max(location.y / previewSize.height, 0), 1)
        )
        camera.focus(at: deviceFocusPoint(from: normalizedPoint))

        let nextIndicator = FocusIndicatorState(location: location)
        focusIndicator = nextIndicator
        scheduleFocusDismiss(for: nextIndicator, after: 3.2)
    }

    private func scheduleFocusDismiss(
        for indicator: FocusIndicatorState,
        after delay: TimeInterval
    ) {
        let token = UUID()
        focusDismissToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard focusDismissToken == token,
                  focusIndicator?.id == indicator.id
            else {
                return
            }
            withAnimation(.easeIn(duration: 0.22)) {
                focusIndicator = nil
            }
        }
    }

    private func handleExposureEditing(_ editing: Bool) {
        guard let focusIndicator else { return }
        if editing {
            focusDismissToken = UUID()
        } else {
            scheduleFocusDismiss(for: focusIndicator, after: 2.4)
        }
    }

    private func focusReticlePosition(
        for indicator: FocusIndicatorState,
        in size: CGSize
    ) -> CGPoint {
        CGPoint(
            x: min(max(indicator.location.x, 38), max(size.width - 38, 38)),
            y: min(max(indicator.location.y, 38), max(size.height - 38, 38))
        )
    }

    private func exposureControlPosition(
        for indicator: FocusIndicatorState,
        in size: CGSize
    ) -> CGPoint {
        let reticle = focusReticlePosition(for: indicator, in: size)
        let placeOnRight = reticle.x <= size.width - 92
        return CGPoint(
            x: reticle.x + (placeOnRight ? 54 : -54),
            y: min(max(reticle.y, 64), max(size.height - 64, 64))
        )
    }

    private func deviceFocusPoint(from previewPoint: CGPoint) -> CGPoint {
        switch interfaceOrientation {
        case .portrait:
            return CGPoint(x: previewPoint.y, y: 1 - previewPoint.x)
        case .landscapeLeft:
            return CGPoint(x: 1 - previewPoint.x, y: 1 - previewPoint.y)
        case .portraitUpsideDown:
            return CGPoint(x: 1 - previewPoint.y, y: previewPoint.x)
        default:
            return previewPoint
        }
    }

    private func synchronizeOrientationWithScene() {
        guard let scene = activeWindowScene else { return }
        apply(interfaceOrientation: scene.effectiveGeometry.interfaceOrientation, requestGeometry: false)
    }

    private func updateOrientation(from deviceOrientation: UIDeviceOrientation) {
        guard let nextOrientation = deviceOrientation.interfaceOrientation else { return }
        apply(interfaceOrientation: nextOrientation, requestGeometry: true)
    }

    private func apply(
        interfaceOrientation nextOrientation: UIInterfaceOrientation,
        requestGeometry: Bool
    ) {
        guard nextOrientation != .unknown else { return }
        interfaceOrientation = nextOrientation
        camera.setVideoOrientation(nextOrientation)

        guard requestGeometry, let scene = activeWindowScene else { return }
        let preferences = UIWindowScene.GeometryPreferences.iOS(
            interfaceOrientations: nextOrientation.orientationMask
        )
        scene.requestGeometryUpdate(preferences) { _ in }
    }

    private var activeWindowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }
}

private struct CameraLayoutMetrics {
    let previewSize: CGSize
    let previewAreaSize: CGSize
    let controlsContentHeight: CGFloat
}

private struct FocusIndicatorState: Identifiable {
    let id = UUID()
    let location: CGPoint
}

private struct FocusReticleView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .stroke(PurooBrandStyle.yellow, lineWidth: 1.5)
            .padding(3)
    }
}

private struct FocusExposureControl: View {
    @Binding var value: Double
    let onEditingChanged: (Bool) -> Void
    @State private var isDragging = false
    @State private var dragStartValue = 0.0

    private let range: ClosedRange<Double> = -3...3

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 14, weight: .regular))

            GeometryReader { proxy in
                let trackHeight = max(proxy.size.height, 1)
                let fraction = min(max((value - range.lowerBound) / rangeLength, 0), 1)
                let knobY = trackHeight * CGFloat(1 - fraction)

                ZStack(alignment: .top) {
                    Capsule()
                        .fill(.white.opacity(0.42))
                        .frame(width: 2, height: trackHeight)

                    Circle()
                        .fill(PurooBrandStyle.yellow)
                        .frame(width: isDragging ? 14 : 10, height: isDragging ? 14 : 10)
                        .shadow(color: .black.opacity(0.35), radius: 2)
                        .offset(y: min(max(knobY - (isDragging ? 7 : 5), 0), trackHeight - (isDragging ? 14 : 10)))
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            if !isDragging {
                                isDragging = true
                                dragStartValue = value
                                onEditingChanged(true)
                            }
                            let delta = Double(-gesture.translation.height / 92) * rangeLength
                            value = min(max(dragStartValue + delta, range.lowerBound), range.upperBound)
                        }
                        .onEnded { _ in
                            isDragging = false
                            onEditingChanged(false)
                        }
                )
            }
        }
        .padding(.vertical, 4)
        .frame(width: 34, height: 112)
        .foregroundStyle(PurooBrandStyle.yellow)
        .background(.black.opacity(0.36), in: Capsule())
        .animation(.easeOut(duration: 0.12), value: isDragging)
        .accessibilityLabel("调节曝光")
    }

    private var rangeLength: Double {
        range.upperBound - range.lowerBound
    }
}

private extension UIDeviceOrientation {
    var interfaceOrientation: UIInterfaceOrientation? {
        switch self {
        case .portrait:
            return .portrait
        case .landscapeLeft:
            return .landscapeRight
        case .landscapeRight:
            return .landscapeLeft
        default:
            return nil
        }
    }
}

private extension UIInterfaceOrientation {
    var orientationMask: UIInterfaceOrientationMask {
        switch self {
        case .portrait:
            return .portrait
        case .landscapeLeft:
            return .landscapeLeft
        case .landscapeRight:
            return .landscapeRight
        default:
            return .allButUpsideDown
        }
    }
}

#Preview {
    CameraScreen()
        .environmentObject(CameraController())
        .environmentObject(MotionStabilityMonitor())
}
