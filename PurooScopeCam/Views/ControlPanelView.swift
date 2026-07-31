import SwiftUI

enum PurooBrandStyle {
    static let colors: [Color] = [
        Color(red: 1.00, green: 0.22, blue: 0.76),
        Color(red: 1.00, green: 0.48, blue: 0.44),
        Color(red: 1.00, green: 0.91, blue: 0.24),
        Color(red: 0.55, green: 0.94, blue: 0.31),
        Color(red: 0.24, green: 0.86, blue: 0.95)
    ]

    static var gradient: LinearGradient {
        LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }

    static let pink = Color(red: 1.00, green: 0.35, blue: 0.72)
    static let yellow = Color(red: 1.00, green: 0.90, blue: 0.24)
}

struct CameraAdjustmentBar: View {
    private enum Adjustment: Equatable {
        case zoom
        case exposure
    }

    @EnvironmentObject private var camera: CameraController
    @State private var adjustment: Adjustment = .zoom

    var body: some View {
        HStack(spacing: 10) {
            adjustmentButton(
                systemImage: "plus.magnifyingglass",
                label: "调节变焦",
                adjustment: .zoom
            )

            GradientValueSlider(value: adjustmentValue, range: adjustmentRange)

            Text(adjustmentValueText)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .lineLimit(1)
                .frame(width: 48, alignment: .trailing)

            adjustmentButton(
                systemImage: "sun.max.fill",
                label: "调节曝光",
                adjustment: .exposure
            )
        }
        .padding(.horizontal, 11)
        .frame(height: 48)
        .foregroundStyle(.white)
        .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 8))
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
                .font(.system(size: 15, weight: .regular))
                .frame(width: 32, height: 32)
                .foregroundStyle(adjustment == nextAdjustment ? .black : .white)
                .background(
                    adjustment == nextAdjustment ? Color.white : Color.white.opacity(0.13),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct GradientValueSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let fraction = min(max((value - range.lowerBound) / rangeLength, 0), 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.22))
                    .frame(height: 6)

                Capsule()
                    .fill(PurooBrandStyle.gradient)
                    .frame(width: max(6, width * fraction), height: 6)

                Circle()
                    .fill(.white)
                    .frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.30), radius: 2, y: 1)
                    .offset(x: min(max(width * fraction - 9, 0), max(width - 18, 0)))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let nextFraction = min(max(gesture.location.x / width, 0), 1)
                        value = range.lowerBound + nextFraction * rangeLength
                    }
            )
        }
        .frame(height: 30)
    }

    private var rangeLength: Double {
        max(range.upperBound - range.lowerBound, 0.0001)
    }
}

struct ControlPanelView: View {
    @EnvironmentObject private var camera: CameraController
    @State private var isPhotoLibraryPresented = false

    var body: some View {
        GeometryReader { proxy in
            let rowWidth = min(proxy.size.width, 420)
            let itemWidth: CGFloat = 48
            let shutterWidth: CGFloat = 64
            let availableSpacing = (rowWidth - itemWidth * 4 - shutterWidth) / 4
            let itemSpacing = max(10, min(22, availableSpacing))

            HStack(spacing: itemSpacing) {
                Button {
                    isPhotoLibraryPresented = true
                } label: {
                utilityLabel(
                    systemImage: "photo.on.rectangle",
                    title: "相册",
                    color: PurooBrandStyle.pink
                )
            }
                .buttonStyle(.plain)
                .accessibilityLabel("打开相册")
                .frame(width: itemWidth)

            Button {
                camera.toggleRecording()
            } label: {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.25), lineWidth: 3)
                    if camera.status.isRecording {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.red)
                            .frame(width: 19, height: 19)
                    } else {
                        Circle()
                            .fill(.red)
                            .frame(width: 25, height: 25)
                    }
                }
                .frame(width: 50, height: 50)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(camera.status.isRecording ? "停止录像" : "开始录像")
            .frame(width: itemWidth)

            Button {
                camera.capturePhoto()
            } label: {
                ZStack {
                    Circle()
                        .stroke(PurooBrandStyle.gradient, lineWidth: 5)
                    Circle()
                        .fill(.black)
                        .padding(8)
                    Circle()
                        .fill(.white)
                        .padding(11)
                }
                .frame(width: shutterWidth, height: shutterWidth)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("拍照")

            Button {
                camera.captureBurst()
            } label: {
                utilityLabel(
                    systemImage: "square.stack.3d.up.fill",
                    title: "连拍",
                    color: .white
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("连拍")
            .frame(width: itemWidth)

            Button {
                camera.setStabilizationEnabled(!camera.isStabilizationEnabled)
            } label: {
                VStack(spacing: 4) {
                    ZStack {
                        Capsule()
                            .fill(
                                camera.isStabilizationEnabled
                                    ? PurooBrandStyle.gradient
                                    : LinearGradient(
                                        colors: [.white.opacity(0.16), .white.opacity(0.08)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                            )
                        Image(systemName: camera.isStabilizationEnabled ? "checkmark" : "xmark")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(camera.isStabilizationEnabled ? .black : .white)
                    }
                    .frame(width: 48, height: 27)

                    Text("稳定")
                        .font(.system(size: 11, weight: .light))
                        .foregroundStyle(.white)
                }
                .frame(width: itemWidth, height: 54)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(camera.isStabilizationEnabled ? "关闭稳定" : "开启稳定")
            .frame(width: itemWidth)
        }
            .frame(width: rowWidth, height: proxy.size.height, alignment: .center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .fullScreenCover(isPresented: $isPhotoLibraryPresented) {
            PhotoLibraryView()
        }
    }

    private func utilityLabel(
        systemImage: String,
        title: String,
        color: Color
    ) -> some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .regular))
                .frame(width: 40, height: 30)
            Text(title)
                .font(.system(size: 11, weight: .light))
        }
        .foregroundStyle(color)
        .frame(width: 48, height: 54)
    }

}

#Preview {
    VStack {
        CameraAdjustmentBar()
        ControlPanelView()
    }
    .environmentObject(CameraController())
    .padding()
    .background(Color.black)
}
