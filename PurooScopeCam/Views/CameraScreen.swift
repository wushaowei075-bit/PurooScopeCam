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
            let horizontalPadding: CGFloat = isLandscape ? 88 : 12
            let headerHeight: CGFloat = isLandscape ? 40 : 52
            let controlsHeight: CGFloat = isLandscape ? 80 : 86
            let spacing: CGFloat = isLandscape ? 6 : 10
            let availablePreviewSize = CGSize(
                width: max(proxy.size.width - horizontalPadding * 2, 1),
                height: max(
                    proxy.size.height - headerHeight - controlsHeight - spacing * 2 - 8,
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

                    ControlPanelView()
                        .frame(maxWidth: isLandscape ? 520 : 390)
                        .frame(height: controlsHeight)
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 4)

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
        ZStack {
            Text("PUROO 普徕 · 稳定")
                .font(.system(size: 22, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .foregroundStyle(PurooBrandStyle.gradient)

            HStack {
                Image(systemName: "camera.aperture")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(PurooBrandStyle.gradient)
                    .frame(width: 42, height: 42)
                    .background(.white.opacity(0.07), in: Circle())

                Spacer()

                if camera.status.isRecording {
                    Label("录像", systemImage: "record.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 10)
                        .frame(height: 36)
                        .background(.white.opacity(0.07), in: Capsule())
                } else {
                    Image(systemName: "scope")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(camera.isStabilizationEnabled ? PurooBrandStyle.yellow : .white.opacity(0.45))
                        .frame(width: 42, height: 42)
                        .background(.white.opacity(0.07), in: Circle())
                }
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
                            .font(.caption.monospacedDigit().weight(.bold))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .frame(minWidth: 64, minHeight: 44)
                            .padding(.horizontal, 8)
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
                        .font(.subheadline.monospacedDigit().weight(.bold))
                        .padding(.horizontal, 14)
                        .frame(height: 44)
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

                    Spacer(minLength: 76)
                }

                Spacer(minLength: 0)

                if let message = camera.status.errorMessage ?? camera.status.lastMessage {
                    statusCapsule(text: message, systemImage: "exclamationmark.circle.fill")
                } else if camera.isStabilizationEnabled {
                    statusCapsule(text: "稳定已开启", systemImage: "waveform.path")
                }

                CameraAdjustmentBar()
            }
            .padding(12)

            if let focusIndicator {
                FocusReticleView()
                    .frame(width: 76, height: 76)
                    .position(focusIndicator.location)
                    .transition(.scale(scale: 1.18).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
        .animation(.easeOut(duration: 0.18), value: focusIndicator?.id)
    }

    private func statusCapsule(text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 13)
            .frame(height: 34)
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
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(PurooBrandStyle.gradient)
            Text("需要相机权限")
                .font(.headline)
            Text("请在系统设置中开启相机权限，然后返回应用。")
                .font(.subheadline)
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
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(PurooBrandStyle.gradient)
            Image(systemName: "plus")
                .font(.system(size: 25, weight: .medium))
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
