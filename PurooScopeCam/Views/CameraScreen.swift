import AVFoundation
import SwiftUI

struct CameraScreen: View {
    @EnvironmentObject private var camera: CameraController
    @EnvironmentObject private var motionMonitor: MotionStabilityMonitor
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            CameraPreviewView(
                camera: camera,
                motionMonitor: motionMonitor,
                stabilizationPreference: camera.stabilizationPreference,
                visualState: camera.previewStabilizationState
            )
                .ignoresSafeArea()

            if camera.authorizationStatus != .authorized {
                Color.black.opacity(0.86)
                    .ignoresSafeArea()
            }

            CrosshairView()
                .stroke(.white.opacity(0.72), lineWidth: 1)
                .frame(width: 110, height: 110)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                Spacer()

                if let message = camera.status.errorMessage ?? camera.status.lastMessage {
                    Text(message)
                        .font(.footnote.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.54), in: Capsule())
                        .padding(.bottom, 10)
                }

                ControlPanelView()
                    .padding(.horizontal, 14)
                    .padding(.bottom, 16)
            }

            if camera.authorizationStatus != .authorized {
                permissionPanel
                    .padding(24)
            }
        }
        .task {
            camera.requestAccessAndConfigure()
            motionMonitor.start()
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
        .onChange(of: motionMonitor.displaySample) { _, sample in
            camera.ingestMotionSample(sample)
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            statusPill(
                title: "预\(camera.status.activePreviewStabilizationMode.scopeDisplayName)",
                systemImage: "dot.scope"
            )

            statusPill(
                title: camera.status.isRecording ? "录制" : "就绪",
                systemImage: camera.status.isRecording ? "record.circle.fill" : "camera.viewfinder"
            )
            .foregroundStyle(camera.status.isRecording ? .red : .white)

            if camera.stabilizationPreference == .auto {
                statusPill(
                    title: "轨迹快",
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
            } else if camera.stabilizationPreference == .balanced {
                statusPill(
                    title: "轨迹稳",
                    systemImage: "point.3.filled.connected.trianglepath.dotted"
                )
            } else if camera.stabilizationPreference == .strong {
                statusPill(
                    title: "轨迹强",
                    systemImage: "scope"
                )
            }

            Spacer()

            ShakeMeterView(sample: motionMonitor.displaySample)
                .frame(width: 132)
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

    private func statusPill(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.black.opacity(0.5), in: Capsule())
    }
}

#Preview {
    CameraScreen()
        .environmentObject(CameraController())
        .environmentObject(MotionStabilityMonitor())
}
