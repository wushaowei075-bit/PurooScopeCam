import Combine
import Foundation
import UIKit

struct BurstCapturePlan: Equatable {
    var frameCount: Int
    var frameInterval: TimeInterval
    var minimumSharpnessScore: Double

    static let defaultTelescope = BurstCapturePlan(
        frameCount: 16,
        frameInterval: 0.08,
        minimumSharpnessScore: 0.65
    )
}

struct BurstFrameScore: Identifiable, Equatable {
    let id = UUID()
    var index: Int
    var sharpness: Double
    var shakeScore: Double

    var composite: Double {
        sharpness * 0.72 + (1 - shakeScore) * 0.28
    }
}

struct BurstCaptureResult: Equatable {
    var frameScores: [BurstFrameScore]
    var selectedFrameIndexes: [Int]
}

final class BurstPhotoCoordinator: ObservableObject {
    static func sharpness(of data: Data) -> Double {
        guard let image = UIImage(data: data)?.cgImage else { return 0 }
        let side = 160
        var pixels = [UInt8](repeating: 0, count: side * side)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard rendered else { return 0 }
        var energy = 0.0
        for y in 1..<(side - 1) {
            for x in 1..<(side - 1) {
                let i = y * side + x
                let response = 4 * Double(pixels[i]) - Double(pixels[i-1]) - Double(pixels[i+1])
                    - Double(pixels[i-side]) - Double(pixels[i+side])
                energy += response * response
            }
        }
        return energy / Double((side - 2) * (side - 2))
    }
    @Published private(set) var isCapturing = false
    @Published private(set) var lastResult: BurstCaptureResult?

    func begin() {
        isCapturing = true
    }

    func finish(scores: [BurstFrameScore]) {
        let selected = scores
            .sorted { $0.composite > $1.composite }
            .prefix(max(1, min(8, scores.count)))
            .map(\.index)

        lastResult = BurstCaptureResult(
            frameScores: scores,
            selectedFrameIndexes: Array(selected)
        )
        isCapturing = false
    }

    func cancel() {
        isCapturing = false
    }
}
