import Foundation
import SwiftUI

struct ControlPanelView: View {
    private enum Adjustment: Equatable {
        case zoom
        case exposure
    }

    @EnvironmentObject private var camera: CameraController
    @State private var adjustment: Adjustment = .zoom

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
        HStack(spacing: 24) {
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

            Menu {
                Button {
                    camera.captureBurst()
                } label: {
                    Label("连拍", systemImage: "square.stack.3d.up")
                }

                Button {
                    camera.setFocusLocked(!camera.focusLocked)
                } label: {
                    Label(
                        camera.focusLocked ? "解除对焦锁定" : "锁定对焦",
                        systemImage: camera.focusLocked ? "lock.open" : "viewfinder"
                    )
                }

                Button {
                    camera.setExposureLocked(!camera.exposureLocked)
                } label: {
                    Label(
                        camera.exposureLocked ? "解除测光锁定" : "锁定测光",
                        systemImage: camera.exposureLocked ? "lock.open" : "camera.metering.center.weighted"
                    )
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 21, weight: .semibold))
                    .frame(width: 52, height: 52)
                    .foregroundStyle(.white)
                    .background(.black.opacity(0.52), in: Circle())
            }
            .accessibilityLabel("更多拍摄功能")
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
