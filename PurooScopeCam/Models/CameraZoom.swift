import Foundation

struct CameraZoomScale: Equatable {
    static let presets: [CGFloat] = [1, 2, 3, 5]
    let baseline: CGFloat
    let maximumDisplayZoom: CGFloat

    var maximum: CGFloat { max(maximumDisplayZoom / baseline, 1) }

    func relativeZoom(for displayZoom: CGFloat) -> CGFloat {
        clamp(displayZoom / baseline)
    }

    func displayZoom(for relativeZoom: CGFloat) -> CGFloat {
        clamp(relativeZoom) * baseline
    }

    func clamp(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 1 }
        return min(max(value, 1), maximum)
    }

    func fraction(for value: CGFloat) -> CGFloat {
        guard maximum > 1 else { return 0 }
        return log(clamp(value)) / log(maximum)
    }

    func dragging(from value: CGFloat, translation: CGFloat) -> CGFloat {
        guard translation.isFinite else { return clamp(value) }
        // Fixed physical travel, independent of the animated presentation width.
        return clamp(clamp(value) * pow(maximum, min(max(translation / 240, -1), 1)))
    }
}

struct CameraZoomDrag {
    private(set) var startZoom: CGFloat?
    private var activationTranslation: CGFloat?
    var isExpanded: Bool { activationTranslation != nil }

    mutating func begin(at zoom: CGFloat) {
        startZoom = zoom
        activationTranslation = nil
    }

    mutating func update(translation: CGFloat, scale: CameraZoomScale) -> CGFloat? {
        guard let startZoom, translation.isFinite else { return nil }
        if activationTranslation == nil {
            guard translation >= 6 else { return nil }
            activationTranslation = translation
        }
        return scale.dragging(from: startZoom, translation: translation - (activationTranslation ?? 0))
    }

    mutating func end() {
        startZoom = nil
        activationTranslation = nil
    }
}

/// One queued consumer, with newer touch samples replacing obsolete requests.
final class CameraZoomRequests {
    struct Request {
        let revision: UInt64
        let zoom: CGFloat
    }
    private let lock = NSLock()
    private var pending: Request?
    private var revision: UInt64 = 0
    private var scheduled = false

    func submit(_ zoom: CGFloat) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        revision &+= 1
        pending = Request(revision: revision, zoom: zoom)
        guard !scheduled else { return false }
        scheduled = true
        return true
    }

    func take() -> Request? {
        lock.lock()
        defer { lock.unlock() }
        guard let request = pending else {
            scheduled = false
            return nil
        }
        pending = nil
        return request
    }

    func canPublishControlValue(for appliedRevision: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return revision == appliedRevision && pending == nil
    }
}
