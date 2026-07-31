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

    var body: some View {
        GeometryReader { proxy in
            let isLandscape = proxy.size.width > proxy.size.height
            let horizontalPadding: CGFloat = 0
            let headerHeight: CGFloat = isLandscape ? 34 : 40
            let controlsHeight: CGFloat = isLandscape ? 64 : 72
            let spacing: CGFloat = 4
            let availablePreviewSize = CGSize(
                width: max(proxy.size.width - horizontalPadding * 2, 1),
                height: max(
                    proxy.size.height - headerHeight - spacing - 8,
                    1
                )
            )
            let previewSize = fittedPreviewSize(
                in: availablePreviewSize,
                isLandscape: isLandscape
            )

            ZStack {
                Color.black
                    .ignoresSafeArea()

                VStack(spacing: spacing) {
                    brandHeader
                        .frame(height: headerHeight)

                    cameraViewport(size: previewSize)
                        .frame(width: previewSize.width, height: previewSize.height)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 4)

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    ControlPanelView()
                        .frame(maxWidth: isLandscape ? 500 : 390)
                        .frame(height: controlsHeight)
                        .background(.black.opacity(0.88))
                }
                .padding(.bottom, 4)

                if camera.authorizationStatus != .authorized {
                    Color.black.opacity(0.90)
                        .ignoresSafeArea()
                    permissionPanel
                        .frame(maxWidth: 320)
                        .padding(24)
                }
            }
        }
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
        HStack(spacing: 7) {
            Text("PUROO 普徕 · 稳定")
                .font(.system(size: 20, weight: .light))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .foregroundStyle(PurooBrandStyle.gradient)

            if camera.status.isRecording {
                Circle()
                    .fill(.red)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel("正在录像")
            }
        }
    }

    private func cameraViewport(size: CGSize) -> some View {
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
                } else if camera.isStabilizationEnabled {
                    statusCapsule(text: "稳定已开启", systemImage: "waveform.path")
                }

                CameraAdjustmentBar()
            }
            .padding(.top, 10)
            .padding(.horizontal, 12)
            .padding(.bottom, 82)

            if let focusIndicator {
                FocusReticleView()
                    .frame(width: 66, height: 66)
                    .position(focusIndicator.location)
                    .transition(.scale(scale: 1.18).combined(with: .opacity))
                    .allowsHitTesting(false)
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

    private func focus(at location: CGPoint, in previewSize: CGSize) {
        guard previewSize.width > 1, previewSize.height > 1 else { return }
        let normalizedPoint = CGPoint(
            x: min(max(location.x / previewSize.width, 0), 1),
            y: min(max(location.y / previewSize.height, 0), 1)
        )
        camera.focus(at: deviceFocusPoint(from: normalizedPoint))

        let nextIndicator = FocusIndicatorState(location: location)
        focusIndicator = nextIndicator
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) {
            guard focusIndicator?.id == nextIndicator.id else { return }
            withAnimation(.easeIn(duration: 0.22)) {
                focusIndicator = nil
            }
        }
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

private struct FocusIndicatorState: Identifiable {
    let id = UUID()
    let location: CGPoint
}

private struct FocusReticleView: View {
    var body: some View {
        ZStack {
            Image(systemName: "viewfinder")
                .font(.system(size: 62, weight: .ultraLight))
                .foregroundStyle(PurooBrandStyle.gradient)
            Image(systemName: "plus")
                .font(.system(size: 21, weight: .light))
                .foregroundStyle(PurooBrandStyle.gradient)
        }
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
