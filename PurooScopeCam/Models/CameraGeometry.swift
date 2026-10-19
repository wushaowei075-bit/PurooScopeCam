import CoreGraphics
import Foundation

struct PreviewRenderTransform: Equatable {
    var scale: CGFloat
    var rotationRadians: CGFloat
    var translationX: CGFloat
    var translationY: CGFloat

    static let identity = PreviewRenderTransform(
        scale: 1, rotationRadians: 0, translationX: 0, translationY: 0
    )
}

enum CameraGeometry {
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
        let a = scale * cos(correction.rotationRadians)
        let b = scale * sin(correction.rotationRadians)
        let c = -b
        let d = a
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

struct CameraLayout {
    let previewSize: CGSize
    let previewOriginY: CGFloat
    let controlsHeight: CGFloat
    let controlsOverlap: CGFloat

    init(size: CGSize, landscape: Bool) {
        controlsHeight = landscape ? 80 : 164
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
