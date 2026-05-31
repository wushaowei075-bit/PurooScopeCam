import Combine
import Foundation

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
