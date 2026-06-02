import SwiftUI

struct ControlPanelView: View {
    @EnvironmentObject private var camera: CameraController

    var body: some View {
        VStack(spacing: 12) {
            stabilizationPicker
            qualityPicker

            HStack(spacing: 12) {
                metricSlider(
                    title: "变焦",
                    value: Binding(
                        get: { Double(camera.zoomFactor) },
                        set: { camera.setZoomFactor(CGFloat($0)) }
                    ),
                    range: 1...6,
                    systemImage: "plus.magnifyingglass"
                )

                metricSlider(
                    title: "曝光",
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
                    title: "对焦",
                    systemImage: camera.focusLocked ? "lock.fill" : "viewfinder",
                    isActive: camera.focusLocked
                ) {
                    camera.setFocusLocked(!camera.focusLocked)
                }

                iconToggle(
                    title: "测光",
                    systemImage: camera.exposureLocked ? "lock.fill" : "camera.metering.center.weighted",
                    isActive: camera.exposureLocked
                ) {
                    camera.setExposureLocked(!camera.exposureLocked)
                }

                Button {
                    camera.captureBurst()
                } label: {
                    Label("连拍", systemImage: "square.stack.3d.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(ScopeButtonStyle())

                Button {
                    camera.toggleRecording()
                } label: {
                    Label(camera.status.isRecording ? "停止" : "录像", systemImage: camera.status.isRecording ? "stop.fill" : "video.fill")
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
                .accessibilityLabel("拍照")
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(12)
        .background(.black.opacity(0.56), in: RoundedRectangle(cornerRadius: 8))
    }

    private var stabilizationPicker: some View {
        Picker("防抖", selection: $camera.stabilizationPreference) {
            ForEach(StabilizationPreference.allCases) { preference in
                Text(preference.title).tag(preference)
            }
        }
        .pickerStyle(.segmented)
    }

    private var qualityPicker: some View {
        HStack(spacing: 10) {
            Label("画质", systemImage: "rectangle.badge.checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.86))

            Picker("画质", selection: $camera.captureQualityPreference) {
                ForEach(camera.captureQualityOptions) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.menu)
            .disabled(camera.status.isRecording || camera.captureQualityOptions.count <= 1)

            Spacer(minLength: 0)

            Text(camera.activeCaptureQuality.shortTitle)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
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
