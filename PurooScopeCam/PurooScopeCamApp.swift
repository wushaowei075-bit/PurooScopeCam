import SwiftUI
import UIKit

final class PurooScopeAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        .allButUpsideDown
    }
}

@main
struct PurooScopeCamApp: App {
    @UIApplicationDelegateAdaptor(PurooScopeAppDelegate.self) private var appDelegate
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
