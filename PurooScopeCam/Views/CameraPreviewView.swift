import AVFoundation
import SwiftUI
import UIKit

final class PreviewHostView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

struct CameraPreviewView: UIViewRepresentable {
    @ObservedObject var camera: CameraController

    func makeUIView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.backgroundColor = .black
        view.previewLayer.session = camera.session
        view.previewLayer.videoGravity = .resizeAspectFill
        camera.configurePreviewConnection(view.previewLayer.connection)
        return view
    }

    func updateUIView(_ view: PreviewHostView, context: Context) {
        view.previewLayer.session = camera.session
        view.previewLayer.videoGravity = .resizeAspectFill
        camera.configurePreviewConnection(view.previewLayer.connection)
    }
}

