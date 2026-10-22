import Foundation

var checks = 0
func check(_ passed: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    guard passed() else { fatalError("FAIL: \(name)") }
}
func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.000001 }

for baseline in [CGFloat(1), CGFloat(1.5)] {
    let scale = CameraZoomScale(baseline: baseline, maximumDisplayZoom: 10)
    check(close(scale.displayZoom(for: 1), baseline), "one is the baseline, including EIS reserve")
    check(close(scale.relativeZoom(for: baseline), 1), "baseline round trip")
    check(close(scale.displayZoom(for: 5), baseline * 5), "five times baseline")
    check(close(scale.displayZoom(for: 100), 10), "preserve engine maximum")
    check(close(scale.displayZoom(for: -2), baseline), "preserve engine minimum")
    check(close(scale.fraction(for: 1), 0), "start of logarithmic scale")
    check(close(scale.fraction(for: scale.maximum), 1), "end of logarithmic scale")
    check(close(scale.clamp(.nan), 1), "nonfinite input")
    for value in stride(from: CGFloat(1), through: scale.maximum, by: 0.01) {
        check(close(scale.relativeZoom(for: scale.displayZoom(for: value)), value), "zoom mapping round trip")
        check(scale.dragging(from: value, translation: 20) >= value, "right increases")
        check(scale.dragging(from: value, translation: -20) <= value, "left decreases")
    }
    check(close(scale.dragging(from: 2, translation: 10000), scale.maximum), "right clamp")
    check(close(scale.dragging(from: 2, translation: -10000), 1), "left clamp")

    var drag = CameraZoomDrag()
    check(drag.update(translation: 30, scale: scale) == nil, "movement without holding does nothing")
    drag.begin(at: 2)
    for movement in [CGFloat(-30), 0, 3, 5.9] {
        check(drag.update(translation: movement, scale: scale) == nil, "right-only activation")
        check(!drag.isExpanded, "no unsolicited scale")
    }
    check(close(drag.update(translation: 8, scale: scale)!, 2), "expand without jump")
    check(drag.isExpanded, "expanded after held right drag")
    check(drag.update(translation: 48, scale: scale)! > 2, "increase after expansion")
    check(drag.update(translation: -32, scale: scale)! < 2, "reverse after expansion")
    check(close(drag.update(translation: 8, scale: scale)!, 2), "return to origin without accumulated error")
    drag.end()
    check(!drag.isExpanded && drag.startZoom == nil, "release/cancel cleans interaction")
    check(drag.update(translation: 100, scale: scale) == nil, "no late movement after cancellation")
    drag.begin(at: 3)
    check(close(drag.update(translation: 6, scale: scale)!, 3), "next hold uses fresh start")
    drag.end()
}

let requests = CameraZoomRequests()
check(requests.submit(1.5), "first request schedules consumer")
for zoom in 2...1000 {
    check(!requests.submit(CGFloat(zoom)), "rapid movement does not schedule stale camera operations")
}
let latest = requests.take()!
check(latest.zoom == 1000 && latest.revision == 1000, "latest request wins")
check(requests.canPublishControlValue(for: latest.revision), "actual result can correct optimistic UI")
check(!requests.submit(3), "consumer remains scheduled while applying")
check(!requests.canPublishControlValue(for: latest.revision), "old completion cannot pull control backward")
let next = requests.take()!
check(next.zoom == 3, "last finger position is preserved")
check(requests.take() == nil, "drain yields then stops")
check(requests.submit(5), "new gesture reactivates idle consumer")
check(requests.take()?.zoom == 5, "subsequent interaction survives")
check(requests.take() == nil, "consumer idle again")

// Exercise producers racing with one serial camera consumer, including idle transitions.
let concurrent = CameraZoomRequests()
let group = DispatchGroup()
let consumer = DispatchQueue(label: "zoom.tests.consumer")
func drain() {
    while concurrent.take() != nil {}
    group.leave()
}
DispatchQueue.concurrentPerform(iterations: 4000) { index in
    if concurrent.submit(CGFloat(index)) {
        group.enter()
        consumer.async { drain() }
    }
}
group.wait()
check(concurrent.submit(7.5), "racing requests cannot strand the queue")
check(concurrent.take()?.zoom == 7.5, "known final value after racing requests")
check(concurrent.take() == nil, "no stale command after final value")

print("PASS: \(checks) zoom mapping, gesture and request queue checks")
