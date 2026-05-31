import SwiftUI

struct RootView: View {
    var body: some View {
        CameraScreen()
            .preferredColorScheme(.dark)
    }
}

#Preview {
    RootView()
        .environmentObject(CameraController())
        .environmentObject(MotionStabilityMonitor())
}

