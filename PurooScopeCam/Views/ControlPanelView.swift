import Foundation
import PhotosUI
import SwiftUI

struct ControlPanelView: View {
    private enum Adjustment: Equatable {
        case zoom
        case exposure
    }

    @EnvironmentObject private var camera: CameraController
    @State private var adjustment: Adjustment = .zoom
    @State private var albumSelection: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 10) {
            adjustmentBar
            captureBar
        }
    }

    private var adjustmentBar: some View {
        HStack(spacing: 10) {
            adjustmentButton(
                systemImage: "plus.magnifyingglass",
                label: "调节变焦",
                adjustment: .zoom
            )

            Slider(value: adjustmentValue, in: adjustmentRange)
                .tint(.white)

            Text(adjustmentValueText)
                .font(.caption.monospacedDigit().weight(.semibold))
                .frame(width: 48, alignment: .trailing)

            adjustmentButton(
                systemImage: "sun.max",
                label: "调节曝光",
                adjustment: .exposure
            )
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .foregroundStyle(.white)
        .background(.black.opacity(0.52), in: RoundedRectangle(cornerRadius: 8))
    }

    private var captureBar: some View {
        HStack(spacing: 18) {
            PhotosPicker(
                selection: $albumSelection,
                matching: .any(of: [.images, .videos]),
                photoLibrary: .shared()
            ) {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .foregroundStyle(.white)
                    .background(.black.opacity(0.52), in: Circle())
            }
            .accessibilityLabel("相册")

            Button {
                camera.toggleRecording()
            } label: {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.88), lineWidth: 2)
                    if camera.status.isRecording {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.red)
                            .frame(width: 22, height: 22)
                    } else {
                        Circle()
                            .fill(.red)
                            .frame(width: 34, height: 34)
                    }
                }
                .frame(width: 52, height: 52)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(camera.status.isRecording ? "停止录像" : "开始录像")

            Button {
                camera.capturePhoto()
            } label: {
                ZStack {
                    Circle()
                        .stroke(.white, lineWidth: 4)
                    Circle()
                        .fill(.white)
                        .padding(7)
                }
                .frame(width: 68, height: 68)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("拍照")

            Button {
                camera.captureBurst()
            } label: {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .foregroundStyle(.white)
                    .background(.black.opacity(0.52), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("连拍")
        }
        .frame(maxWidth: .infinity)
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
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 28, height: 28)
                .foregroundStyle(adjustment == nextAdjustment ? .black : .white)
                .background(
                    adjustment == nextAdjustment ? Color.white : Color.white.opacity(0.14),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

#Preview {
    ControlPanelView()
        .environmentObject(CameraController())
        .padding()
        .background(Color.gray)
}
