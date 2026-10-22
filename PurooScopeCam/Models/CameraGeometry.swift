import CoreGraphics
import Foundation

struct PreviewRenderTransform: Equatable {
    var scale: CGFloat
    var rotationRadians: CGFloat
    var translationX: CGFloat
    var translationY: CGFloat
    var rollingShearX: CGFloat = 0
    var rollingStretchY: CGFloat = 0

    static let identity = PreviewRenderTransform(
        scale: 1, rotationRadians: 0, translationX: 0, translationY: 0
    )
}

enum CameraGeometry {
    static func centeredSourceRect(_ source: CGRect, matching videoSize: CGSize) -> CGRect {
        let ratio = videoSize.width / max(videoSize.height, 1)
        let width = min(source.width, source.height * ratio)
        let height = min(source.height, source.width / max(ratio, 0.0001))
        return CGRect(x: source.midX - width / 2, y: source.midY - height / 2, width: width, height: height)
    }

    static func outputSize(for source: CGSize) -> CGSize {
        let portrait = source.height > source.width
        let long = max(source.width, source.height)
        let short = min(source.width, source.height)
        // Both dimensions are even, without changing the 16:9 aspect ratio.
        let units = max(2, Int(min(long / 16, short / 9)) / 2 * 2)
        return portrait
            ? CGSize(width: units * 9, height: units * 16)
            : CGSize(width: units * 16, height: units * 9)
    }

    static func transform(
        source: CGRect, output: CGSize, viewport: CGSize,
        correction: PreviewRenderTransform, cropScale: CGFloat
    ) -> CGAffineTransform {
        let scale = max(output.width / max(source.width, 1), output.height / max(source.height, 1))
            * max(correction.scale, cropScale)
        let shear = min(max(correction.rollingShearX, -0.025), 0.025)
        let stretch = min(max(correction.rollingStretchY, -0.025), 0.025)
        let a = scale * cos(correction.rotationRadians)
        let b = scale * sin(correction.rotationRadians)
        // shear is a horizontal displacement fraction across the full image height.
        let c = -b + scale * shear * source.width / max(source.height, 1)
        let d = a * (1 + stretch)
        let x = output.width * (0.5 + correction.translationX / max(viewport.width, 1))
        let y = output.height * (0.5 - correction.translationY / max(viewport.height, 1))
        return CGAffineTransform(
            a: a, b: b, c: c, d: d,
            tx: x - a * source.midX - c * source.midY,
            ty: y - b * source.midX - d * source.midY
        )
    }

    static func sourcePoint(
        from point: CGPoint, source: CGSize, viewport: CGSize,
        correction: PreviewRenderTransform, cropScale: CGFloat
    ) -> CGPoint {
        let matrix = transform(
            source: CGRect(origin: .zero, size: source), output: viewport,
            viewport: viewport, correction: correction, cropScale: cropScale
        )
        let pixel = CGPoint(x: point.x, y: viewport.height - point.y).applying(matrix.inverted())
        return CGPoint(
            x: min(max(pixel.x / max(source.width, 1), 0), 1),
            y: min(max(1 - pixel.y / max(source.height, 1), 0), 1)
        )
    }
}

// Capture and stabilization stay in portrait coordinates. Only controls and
// exported media follow the physical orientation; preview buffers never switch axes.
struct CameraPresentation {
    static let captureRotationAngle: CGFloat = 90
    let videoRotationAngle: CGFloat

    private var quarterTurns: Int {
        ((Int(videoRotationAngle.rounded()) / 90) % 4 + 4) % 4
    }

    var controlDegrees: Double {
        switch quarterTurns {
        case 0: return 90
        case 2: return -90
        case 3: return 180
        default: return 0
        }
    }

    func cameraSize(for displaySize: CGSize) -> CGSize {
        quarterTurns.isMultiple(of: 2)
            ? CGSize(width: displaySize.height, height: displaySize.width)
            : displaySize
    }

    // Core Image has an upward Y axis, unlike the touch/UI coordinate system.
    func displayTransform(cameraSize size: CGSize) -> CGAffineTransform {
        switch quarterTurns {
        case 0: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: size.width)
        case 2: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0)
        case 3: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: size.width, ty: size.height)
        default: return .identity
        }
    }

    func outputTransform(portraitSize: CGSize) -> CGAffineTransform {
        displayTransform(cameraSize: cameraSize(for: portraitSize)).inverted()
    }

    func cameraPoint(fromDisplay point: CGPoint) -> CGPoint {
        switch quarterTurns {
        case 0: return CGPoint(x: point.y, y: 1 - point.x)
        case 2: return CGPoint(x: 1 - point.y, y: point.x)
        case 3: return CGPoint(x: 1 - point.x, y: 1 - point.y)
        default: return point
        }
    }
}

struct CameraLayout {
    let previewSize: CGSize
    let previewOriginY: CGFloat
    let controlsHeight: CGFloat
    let controlsOverlap: CGFloat

    init(size: CGSize, landscape: Bool) {
        controlsHeight = landscape ? 80 : 176
        let availableHeight = max(size.height, 1)
        if landscape {
            let height = max(min(availableHeight - controlsHeight, size.width * 9 / 16), 1)
            previewSize = CGSize(width: height * 16 / 9, height: height)
        } else {
            // Short screens keep the full-width frame; controls overlay its lower edge.
            previewSize = CGSize(width: size.width, height: size.width * 16 / 9)
        }
        previewOriginY = min(0, availableHeight - previewSize.height)
        controlsOverlap = max(0, previewOriginY + previewSize.height - (availableHeight - controlsHeight))
    }
}
