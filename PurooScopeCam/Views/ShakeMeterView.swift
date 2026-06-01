import SwiftUI

struct ShakeMeterView: View {
    let sample: StabilitySample

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                Text(sample.band.title)
                Spacer(minLength: 0)
            }
            .font(.caption2.weight(.bold))

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.18))
                    Capsule()
                        .fill(color)
                        .frame(width: max(6, proxy.size.width * sample.score))
                }
            }
            .frame(height: 6)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .foregroundStyle(.white)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var iconName: String {
        switch sample.band {
        case .stable: "checkmark.circle.fill"
        case .warning: "waveform.path.ecg"
        case .heavy: "exclamationmark.triangle.fill"
        case .unavailable: "gyroscope"
        }
    }

    private var color: Color {
        switch sample.band {
        case .stable: .green
        case .warning: .yellow
        case .heavy: .red
        case .unavailable: .gray
        }
    }
}

#Preview {
    VStack {
        ShakeMeterView(sample: .unavailable)
        ShakeMeterView(sample: StabilitySample(timestamp: 0, angularVelocity: 0.1, rotationX: 0, rotationY: 0, rotationZ: 0, score: 0.16, band: .stable))
        ShakeMeterView(sample: StabilitySample(timestamp: 0, angularVelocity: 0.8, rotationX: 0, rotationY: 0, rotationZ: 0, score: 0.4, band: .warning))
        ShakeMeterView(sample: StabilitySample(timestamp: 0, angularVelocity: 1.8, rotationX: 0, rotationY: 0, rotationZ: 0, score: 0.86, band: .heavy))
    }
    .padding()
    .background(Color.black)
}
