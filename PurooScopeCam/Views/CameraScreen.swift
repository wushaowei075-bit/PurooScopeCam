import AVFoundation
import Combine
import SwiftUI
import UIKit

struct CameraScreen: View {
    @EnvironmentObject private var camera: CameraController
    @EnvironmentObject private var motionMonitor: MotionStabilityMonitor
    @Environment(\.scenePhase) private var scenePhase
    @State private var interfaceOrientation: UIInterfaceOrientation = .portrait

    var body: some View {
        GeometryReader { proxy in
            let isLandscape = proxy.size.width > proxy.size.height

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
                .ignoresSafeArea()

                if camera.authorizationStatus != .authorized {
                    Color.black.opacity(0.86)
                        .ignoresSafeArea()
                }

                CrosshairView()
                    .stroke(.white.opacity(0.62), lineWidth: 1)
                    .frame(width: 84, height: 84)
                    .allowsHitTesting(false)

                VStack(spacing: 0) {
                    topBar
                        .frame(maxWidth: isLandscape ? 620 : .infinity)
                        .padding(.horizontal, isLandscape ? 12 : 16)

                    Spacer()

                    if let message = camera.status.errorMessage ?? camera.status.lastMessage {
                        Text(message)
                            .font(.footnote.weight(.medium))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.black.opacity(0.58), in: Capsule())
                            .padding(.bottom, 8)
                    }

                    ControlPanelView()
                        .frame(maxWidth: isLandscape ? 520 : 480)
                        .padding(.horizontal, isLandscape ? 12 : 16)
                }
                .safeAreaPadding(.top, 8)
                .safeAreaPadding(.bottom, 10)

                if camera.authorizationStatus != .authorized {
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
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                camera.setStabilizationEnabled(!camera.isStabilizationEnabled)
            } label: {
                Image(systemName: camera.isStabilizationEnabled ? "scope" : "scope")
                    .foregroundStyle(camera.isStabilizationEnabled ? .green : .white.opacity(0.72))
            }
            .buttonStyle(CameraToolbarButtonStyle())
            .accessibilityLabel(camera.isStabilizationEnabled ? "关闭稳定" : "开启稳定")

            Menu {
                Picker("画质", selection: $camera.captureQualityPreference) {
                    ForEach(camera.captureQualityOptions) { option in
                        Text(option.title).tag(option)
                    }
                }
            } label: {
                Text(camera.activeCaptureQuality.shortTitle)
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
            .buttonStyle(CameraToolbarButtonStyle())
            .disabled(camera.status.isRecording || camera.captureQualityOptions.count <= 1)

            Menu {
                Picker(
                    "望远镜倍率",
                    selection: Binding(
                        get: { camera.telescopeMagnification },
                        set: { camera.setTelescopeMagnification($0) }
                    )
                ) {
                    ForEach(TelescopeMagnificationOption.presets) { option in
                        Text(option.title).tag(option.value)
                    }
                }
            } label: {
                Label(
                    "\(camera.telescopeMagnification, specifier: "%.0f")×",
                    systemImage: "binoculars"
                )
                .font(.caption.monospacedDigit().weight(.semibold))
            }
            .buttonStyle(CameraToolbarButtonStyle())

            Spacer()

            if camera.status.isRecording {
                Label("录像", systemImage: "record.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .frame(height: 36)
                    .background(.black.opacity(0.52), in: Capsule())
            }
        }
    }

    private var permissionPanel: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill")
                .font(.system(size: 38, weight: .semibold))
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

private struct CameraToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 10)
            .frame(minWidth: 38, minHeight: 36)
            .foregroundStyle(.white)
            .background(.black.opacity(configuration.isPressed ? 0.68 : 0.52), in: Capsule())
    }
}

#Preview {
    CameraScreen()
        .environmentObject(CameraController())
        .environmentObject(MotionStabilityMonitor())
}
