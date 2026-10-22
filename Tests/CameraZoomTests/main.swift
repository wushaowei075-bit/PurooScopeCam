import Foundation

var checks = 0
func check(_ passed: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    guard passed() else { fatalError("FAIL: \(name)") }
}
func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.000001 }

for baseline in [CGFloat(1), CGFloat(1.5)] {
    let scale = CameraZoomScale(baseline: baseline, maximumDisplayZoom: baseline * 20)
    check(close(scale.maximum, 20), "twenty relative zoom with stabilization both on and off")
    check(close(scale.displayZoom(for: 1), baseline), "one is the baseline, including EIS reserve")
    check(close(scale.relativeZoom(for: baseline), 1), "baseline round trip")
    check(close(scale.displayZoom(for: 5), baseline * 5), "five times baseline")
    check(close(scale.displayZoom(for: 100), baseline * 20), "effective maximum includes baseline crop")
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
    check(close(drag.update(translation: 0, scale: scale)!, 2), "hold does not change zoom")
    check(drag.update(translation: -20, scale: scale)! < 2, "left works immediately after hold")
    check(drag.update(translation: 3, scale: scale)! > 2, "no rightward activation threshold")
    check(drag.update(translation: 48, scale: scale)! > 2, "increase after expansion")
    check(drag.update(translation: -32, scale: scale)! < 2, "reverse after expansion")
    check(close(drag.update(translation: 0, scale: scale)!, 2), "return to origin without accumulated error")
    drag.end()
    check(drag.startZoom == nil, "release/cancel cleans interaction")
    check(drag.update(translation: 100, scale: scale) == nil, "no late movement after cancellation")
    drag.begin(at: 3)
    check(close(drag.update(translation: 0, scale: scale)!, 3), "next hold uses fresh start")
    drag.end()
}

var visibility = CameraZoomVisibility()
check(!visibility.isExpanded, "scale initially hidden")
visibility.begin()
check(visibility.isExpanded, "hold expands before any movement")
check(!visibility.hideIfExpired(at: 1000), "held scale never times out")
visibility.release(at: 10)
check(visibility.isExpanded, "release keeps scale visible")
check(!visibility.hideIfExpired(at: 11.19), "linger is at least 1.2 seconds")
check(visibility.hideIfExpired(at: 11.21), "hide after linger")
visibility.begin()
visibility.release(at: 20)
visibility.begin()
check(!visibility.hideIfExpired(at: 21.5), "retouch cancels old hide deadline")
visibility.release(at: 22)
check(!visibility.hideIfExpired(at: 22.5), "new release gets fresh linger")
check(visibility.hideIfExpired(at: 23.21), "second release hides normally")
visibility.begin()
visibility.cancel()
check(!visibility.isExpanded, "capture/background/rotation cancellation hides immediately")
check(!visibility.hideIfExpired(at: 1000), "old timers cannot revive cancelled controls")

let crop: (CGFloat) -> CGFloat = { 1.5 + min(max(($0 - 3) / 7, 0), 1) * 0.9 }
check(close(CameraZoomScale.supportedDisplayZoom(requested: 30, baseline: 1.5, deviceMaximum: 15, cropScale: crop), 30),
      "capable camera reaches twenty relative zoom")
check(close(CameraZoomScale.supportedDisplayZoom(requested: 30, baseline: 1.5, deviceMaximum: 10, cropScale: crop), 24),
      "device limit is truthful and uses the same crop as rendering")
check(close(CameraZoomScale.supportedDisplayZoom(requested: 20, baseline: 1, deviceMaximum: 7, cropScale: { _ in 1 }), 7),
      "device limit without stabilization")
for device in stride(from: CGFloat(1), through: 15, by: 0.1) {
    let actual = CameraZoomScale.supportedDisplayZoom(requested: 30, baseline: 1.5, deviceMaximum: device, cropScale: crop)
    check(actual >= 1.5 && actual <= 30, "supported effective range")
    check(actual / crop(actual) <= device + 0.000001, "crop and hardware remain self-consistent")
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
