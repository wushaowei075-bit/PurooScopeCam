import SwiftUI

@main
struct PurooScopeCamApp: App {
    @StateObject private var camera = CameraController()
    @StateObject private var motionMonitor = MotionStabilityMonitor()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(camera)
                .environmentObject(motionMonitor)
        }
    }
}

