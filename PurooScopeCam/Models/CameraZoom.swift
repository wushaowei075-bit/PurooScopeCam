import Foundation

struct CameraZoomScale: Equatable {
    static let presets: [CGFloat] = [1, 2, 3, 5]
    static let maximumRelativeZoom: CGFloat = 20
    let baseline: CGFloat
    let maximumDisplayZoom: CGFloat

    var maximum: CGFloat { min(max(maximumDisplayZoom / baseline, 1), Self.maximumRelativeZoom) }

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

    // cropScale is monotonic under the production policy; solve in display space
    // so a device limit never leaves the preview using a different crop than the hardware.
    static func supportedDisplayZoom(requested: CGFloat, baseline: CGFloat,
                                     deviceMaximum: CGFloat, cropScale: (CGFloat) -> CGFloat) -> CGFloat {
        let maximum = max(deviceMaximum, 1)
        let target = max(requested, baseline)
        guard target / max(cropScale(target), 1) > maximum else { return target }
        var low = baseline
        var high = target
        for _ in 0..<40 {
            let middle = (low + high) / 2
            if middle / max(cropScale(middle), 1) <= maximum {
                low = middle
            } else {
                high = middle
            }
        }
        return low
    }
}

struct CameraZoomDrag {
    private(set) var startZoom: CGFloat?

    mutating func begin(at zoom: CGFloat) {
        startZoom = zoom
    }

    mutating func update(translation: CGFloat, scale: CameraZoomScale) -> CGFloat? {
        guard let startZoom, translation.isFinite else { return nil }
        return scale.dragging(from: startZoom, translation: translation)
    }

    mutating func end() {
        startZoom = nil
    }
}

struct CameraZoomVisibility {
    static let lingerDuration: TimeInterval = 1.2
    private(set) var isExpanded = false
    private var hideAt: TimeInterval?

    mutating func begin() {
        isExpanded = true
        hideAt = nil
    }

    mutating func release(at time: TimeInterval) {
        guard isExpanded else { return }
        hideAt = time + Self.lingerDuration
    }

    @discardableResult
    mutating func hideIfExpired(at time: TimeInterval) -> Bool {
        guard let hideAt, time >= hideAt else { return false }
        cancel()
        return true
    }

    mutating func cancel() {
        isExpanded = false
        hideAt = nil
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
