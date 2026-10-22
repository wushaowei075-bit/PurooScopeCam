import CoreGraphics
import Foundation

var checks = 0
func check(_ value: Bool, _ message: String) {
    checks += 1
    precondition(value, message)
}
func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.000001 }

for size in [CGSize(width: 1920, height: 1080), CGSize(width: 3840, height: 2160),
             CGSize(width: 1280, height: 720), CGSize(width: 1080, height: 1920),
             CGSize(width: 2160, height: 3840)] {
    check(CameraGeometry.outputSize(for: size) == size, "Standard video size must not be rounded to 1072")
}
for size in [CGSize(width: 4032, height: 3024), CGSize(width: 3024, height: 4032),
             CGSize(width: 4096, height: 2160)] {
    let output = CameraGeometry.outputSize(for: size)
    check(near(max(output.width, output.height) / min(output.width, output.height), 16 / 9), "Photo crop aspect")
    check(Int(output.width) % 2 == 0 && Int(output.height) % 2 == 0, "Codec requires even dimensions")
    check(output.width <= size.width && output.height <= size.height, "Do not upscale source dimensions")
}

// Invert the actual render matrix, including rotation, translation and digital crop.
for source in [CGSize(width: 1080, height: 1920), CGSize(width: 1920, height: 1080)] {
    let viewport = CGSize(width: source.width / 3, height: source.height / 3)
    for crop in [CGFloat(1), 1.5, 2.2] {
        for angle in [CGFloat(0), -0.07, 0.12] {
            let correction = PreviewRenderTransform(scale: crop, rotationRadians: angle, translationX: 14, translationY: -19)
            let matrix = CameraGeometry.transform(source: CGRect(origin: .zero, size: source), output: viewport,
                viewport: viewport, correction: correction, cropScale: crop)
            for x in [CGFloat(0.35), 0.5, 0.65] {
                for y in [CGFloat(0.35), 0.5, 0.65] {
                    let pixel = CGPoint(x: x * source.width, y: (1 - y) * source.height).applying(matrix)
                    let touch = CGPoint(x: pixel.x, y: viewport.height - pixel.y)
                    let restored = CameraGeometry.sourcePoint(from: touch, source: source, viewport: viewport,
                        correction: correction, cropScale: crop)
                    check(near(restored.x, x) && near(restored.y, y), "Focus must target the displayed source point")
                }
            }
            let output = CameraGeometry.outputSize(for: source)
            let outputMatrix = CameraGeometry.transform(source: CGRect(origin: .zero, size: source), output: output,
                viewport: viewport, correction: correction, cropScale: crop)
            let p = CGPoint(x: source.width * 0.4, y: source.height * 0.6)
            let displayed = p.applying(matrix)
            let recorded = p.applying(outputMatrix)
            check(near(displayed.x / viewport.width, recorded.x / output.width)
                && near(displayed.y / viewport.height, recorded.y / output.height), "Preview and recording crop must agree")

            let rsCorrection = PreviewRenderTransform(
                scale: crop, rotationRadians: angle, translationX: 14, translationY: -19,
                rollingShearX: 0.008, rollingStretchY: -0.006
            )
            let rsMatrix = CameraGeometry.transform(source: CGRect(origin: .zero, size: source), output: viewport,
                viewport: viewport, correction: rsCorrection, cropScale: crop)
            let rsPixel = CGPoint(x: 0.45 * source.width, y: 0.55 * source.height).applying(rsMatrix)
            let rsTouch = CGPoint(x: rsPixel.x, y: viewport.height - rsPixel.y)
            let rsRestored = CameraGeometry.sourcePoint(from: rsTouch, source: source, viewport: viewport,
                correction: rsCorrection, cropScale: crop)
            check(near(rsRestored.x, 0.45) && near(rsRestored.y, 0.45), "Rolling shutter warp focus inversion must remain exact")
        }
    }
}

for size in [CGSize(width: 320, height: 548), CGSize(width: 375, height: 647),
             CGSize(width: 393, height: 759), CGSize(width: 430, height: 839),
             CGSize(width: 852, height: 350), CGSize(width: 667, height: 354),
             CGSize(width: 1024, height: 720)] {
    let landscape = size.width > size.height
    let layout = CameraLayout(size: size, landscape: landscape)
    let aspect: CGFloat = landscape ? 16 / 9 : 9 / 16
    check(near(layout.previewSize.width / layout.previewSize.height, aspect), "Preview aspect across devices")
    check(layout.controlsHeight >= (landscape ? 80 : 158), "Control hit areas must fit inside their parent")
    check(size.height - layout.controlsHeight >= 0, "Controls remain on screen")
    check(layout.previewSize.width <= size.width + 0.01, "No horizontal overflow")
    check(near(layout.controlsOverlap, max(0, layout.previewOriginY + layout.previewSize.height - size.height + layout.controlsHeight)), "Zoom bar clears shutter area")
    if !landscape { check(near(layout.previewSize.width, size.width), "Portrait remains edge-to-edge") }
}
for size in [CGSize(width: 2160, height: 3840), CGSize(width: 3840, height: 2160)] {
    let rect = CGRect(origin: .zero, size: size)
    let correction = PreviewRenderTransform(scale: 1, rotationRadians: 0, translationX: 0, translationY: 0, rollingShearX: 0.008)
    let matrix = CameraGeometry.transform(source: rect, output: size, viewport: size, correction: correction, cropScale: 1)
    let top = CGPoint(x: size.width / 2, y: 0).applying(matrix)
    let bottom = CGPoint(x: size.width / 2, y: size.height).applying(matrix)
    check(near(bottom.x - top.x, size.width * 0.008), "Shear unit is a fraction of width in both orientations")
    let sensor = CGRect(x: 0, y: 0, width: size.width > size.height ? 4032 : 3024, height: size.width > size.height ? 3024 : 4032)
    let cropped = CameraGeometry.centeredSourceRect(sensor, matching: size)
    check(near(cropped.width / cropped.height, size.width / size.height), "Photo source matches video field aspect before applying transform")
    check(near(cropped.midX, sensor.midX) && near(cropped.midY, sensor.midY), "Photo source crop remains centered")
}
// Presentation rotation must not introduce a second crop or change saved media.
for width in [CGFloat(320), 393, 430] {
    let display = CGSize(width: width, height: width * 16 / 9)
    for angle in [CGFloat(90), 0, 180, 270] {
        let presentation = CameraPresentation(videoRotationAngle: angle)
        let viewport = presentation.cameraSize(for: display)
        let rotation = presentation.displayTransform(cameraSize: viewport)
        let transformed = CGRect(origin: .zero, size: viewport).applying(rotation)
        check(near(transformed.minX, 0) && near(transformed.minY, 0), "Rotated preview starts at origin")
        check(near(transformed.width, display.width) && near(transformed.height, display.height), "All orientations fill the same preview")
        let source = CGSize(width: viewport.width * 4, height: viewport.height * 4)
        for crop in [CGFloat(1), 1.5, 2.4] {
            let correction = PreviewRenderTransform(scale: crop, rotationRadians: 0.03,
                                                    translationX: 9, translationY: -11)
            let stabilize = CameraGeometry.transform(source: CGRect(origin: .zero, size: source), output: viewport,
                viewport: viewport, correction: correction, cropScale: crop)
            for x in [CGFloat(0.4), 0.5, 0.6] {
                for y in [CGFloat(0.4), 0.5, 0.6] {
                    let original = CGPoint(x: source.width * x, y: source.height * (1 - y))
                    let shown = original.applying(stabilize).applying(rotation)
                    let touch = CGPoint(x: shown.x / display.width, y: 1 - shown.y / display.height)
                    let cameraTouch = presentation.cameraPoint(fromDisplay: touch)
                    let restored = CameraGeometry.sourcePoint(
                        from: CGPoint(x: cameraTouch.x * viewport.width, y: cameraTouch.y * viewport.height),
                        source: source, viewport: viewport, correction: correction, cropScale: crop)
                    check(near(restored.x, x) && near(restored.y, y), "Focus inverts display rotation and stabilization")
                    let output = CameraGeometry.outputSize(for: source)
                    let saved = original.applying(CameraGeometry.transform(
                        source: CGRect(origin: .zero, size: source), output: output,
                        viewport: viewport, correction: correction, cropScale: crop))
                    check(near(saved.x / output.width, cameraTouch.x)
                        && near(1 - saved.y / output.height, cameraTouch.y), "Saved media matches visible field in every orientation")
                }
            }
        }
    }
}
check(CameraPresentation(videoRotationAngle: 90).controlDegrees == 0, "Portrait labels upright")
check(CameraPresentation(videoRotationAngle: 0).controlDegrees == 90, "Landscape right labels clockwise")
check(CameraPresentation(videoRotationAngle: 180).controlDegrees == -90, "Landscape left labels counterclockwise")
check(CameraPresentation.captureRotationAngle == 90, "Capture coordinates do not depend on device orientation")
for angle in [CGFloat(90), 0, 180, 270] {
    let portrait = CGSize(width: 1080, height: 1920)
    let presentation = CameraPresentation(videoRotationAngle: angle)
    let transform = presentation.outputTransform(portraitSize: portrait)
    let exported = CGRect(origin: .zero, size: portrait).applying(transform)
    let size = presentation.cameraSize(for: portrait)
    check(near(exported.minX, 0) && near(exported.minY, 0)
        && near(exported.width, size.width) && near(exported.height, size.height),
        "Rotated media has exact bounds without adding black margins")
    for crop in [CGFloat(1), 1.5, 2.4] {
        let correction = PreviewRenderTransform(scale: crop, rotationRadians: 0.06, translationX: 14, translationY: -11)
        let viewport = CGSize(width: 360, height: 640)
        let render = CameraGeometry.transform(source: CGRect(origin: .zero, size: portrait), output: portrait,
            viewport: viewport, correction: correction, cropScale: crop)
        let sourcePoint = CGPoint(x: 450, y: 900)
        let previewPixel = sourcePoint.applying(render)
        let exportedPixel = previewPixel.applying(transform)
        let back = exportedPixel.applying(presentation.displayTransform(cameraSize: size))
        check(near(back.x, previewPixel.x) && near(back.y, previewPixel.y),
              "Fixed preview and physically oriented export preserve the same crop and correction")
    }
}
print("PASS: \(checks) camera geometry, focus, output and layout checks")
