import SwiftUI

struct ControlPanelView: View {
    @EnvironmentObject private var camera: CameraController

    var body: some View {
        VStack(spacing: 12) {
            stabilizationPicker

            HStack(spacing: 12) {
                metricSlider(
                    title: "Zoom",
                    value: Binding(
                        get: { Double(camera.zoomFactor) },
                        set: { camera.setZoomFactor(CGFloat($0)) }
                    ),
                    range: 1...6,
                    systemImage: "plus.magnifyingglass"
                )

                metricSlider(
                    title: "EV",
                    value: Binding(
                        get: { Double(camera.exposureBias) },
                        set: { camera.setExposureBias(Float($0)) }
                    ),
                    range: -3...3,
                    systemImage: "sun.max"
                )
            }

            HStack(spacing: 12) {
                iconToggle(
                    title: "Focus",
                    systemImage: camera.focusLocked ? "lock.fill" : "viewfinder",
                    isActive: camera.focusLocked
                ) {
                    camera.setFocusLocked(!camera.focusLocked)
                }

                iconToggle(
                    title: "AE",
                    systemImage: camera.exposureLocked ? "lock.fill" : "camera.metering.center.weighted",
                    isActive: camera.exposureLocked
                ) {
                    camera.setExposureLocked(!camera.exposureLocked)
                }

                Button {
                    camera.captureBurst()
                } label: {
                    Label("Burst", systemImage: "square.stack.3d.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(ScopeButtonStyle())

                Button {
                    camera.toggleRecording()
                } label: {
                    Label(camera.status.isRecording ? "Stop" : "Video", systemImage: camera.status.isRecording ? "stop.fill" : "video.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(ScopeButtonStyle(isProminent: camera.status.isRecording))

                Button {
                    camera.capturePhoto()
                } label: {
                    Image(systemName: "camera.circle.fill")
                        .font(.system(size: 42, weight: .semibold))
                        .frame(width: 58, height: 58)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Capture photo")
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(12)
        .background(.black.opacity(0.56), in: RoundedRectangle(cornerRadius: 8))
    }

    private var stabilizationPicker: some View {
        Picker("Stabilization", selection: $camera.stabilizationPreference) {
            ForEach(StabilizationPreference.allCases) { preference in
                Text(preference.title).tag(preference)
            }
        }
        .pickerStyle(.segmented)
    }

    private func metricSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        systemImage: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.86))
            Slider(value: value, in: range)
        }
    }

    private func iconToggle(
        title: String,
        systemImage: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(ScopeButtonStyle(isProminent: isActive))
    }
}

struct ScopeButtonStyle: ButtonStyle {
    var isProminent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .padding(.horizontal, 10)
            .frame(height: 42)
            .background(background(configuration: configuration), in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(.white)
            .opacity(configuration.isPressed ? 0.74 : 1)
    }

    private func background(configuration: Configuration) -> Color {
        if isProminent {
            return configuration.isPressed ? .red.opacity(0.72) : .red.opacity(0.9)
        } else {
            return configuration.isPressed ? .white.opacity(0.22) : .white.opacity(0.14)
        }
    }
}

#Preview {
    ControlPanelView()
        .environmentObject(CameraController())
        .padding()
        .background(Color.gray)
}

