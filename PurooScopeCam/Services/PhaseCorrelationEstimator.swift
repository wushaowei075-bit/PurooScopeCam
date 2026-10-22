import Accelerate
import Foundation

struct PhaseCorrelationEstimate {
    var dx: Double
    var dy: Double
    var peakToSidelobe: Double
    var peakRatio: Double
    var accepted: Bool
}

// Also used as a gated fallback; callers must validate ROI and motion agreement.
final class PhaseCorrelationEstimator {
    private let size = 256
    private let logSize: vDSP_Length = 8
    private let setup = vDSP_create_fftsetup(8, FFTRadix(kFFTRadix2))
    private var cachedWindowGridSize = 0
    private var cachedWindow: [Float] = []

    deinit { if let setup { vDSP_destroy_fftsetup(setup) } }

    func estimate(reference: [Float], current: [Float], gridSize: Int,
                  validMask: [Bool]? = nil) -> PhaseCorrelationEstimate? {
        guard setup != nil, gridSize >= size, reference.count == gridSize * gridSize,
              current.count == reference.count else { return nil }
        guard validMask == nil || validMask?.count == reference.count else { return nil }
        var weights = windowWeights(for: gridSize)
        if let validMask {
            let offset = (gridSize - size) / 2
            var distance = [Int](repeating: size, count: size * size)
            for y in 0..<size {
                for x in 0..<size {
                    let i = y * size + x
                    if !validMask[(y + offset) * gridSize + x + offset] { distance[i] = 0 }
                    else {
                        distance[i] = min(x == 0 ? 1 : distance[i - 1] + 1,
                                          y == 0 ? 1 : distance[i - size] + 1)
                    }
                }
            }
            for y in stride(from: size - 1, through: 0, by: -1) {
                for x in stride(from: size - 1, through: 0, by: -1) {
                    let i = y * size + x
                    distance[i] = min(distance[i], x == size - 1 ? 1 : distance[i + 1] + 1,
                                      y == size - 1 ? 1 : distance[i + size] + 1)
                    let taper = min(max(Double(distance[i] - 2) / 8, 0), 1)
                    weights[i] *= Float(0.5 - 0.5 * cos(.pi * taper))
                }
            }
        }
        guard weights.reduce(0, +) >= 256 else { return nil }
        var ar = windowed(reference, gridSize: gridSize, weights: weights)
        var br = windowed(current, gridSize: gridSize, weights: weights)
        guard ar.reduce(Float(0), { $0 + $1 * $1 }) > 1,
              br.reduce(Float(0), { $0 + $1 * $1 }) > 1 else { return nil }
        var ai = [Float](repeating: 0, count: ar.count)
        var bi = ai
        transform(&ar, &ai, direction: FFTDirection(FFT_FORWARD))
        transform(&br, &bi, direction: FFTDirection(FFT_FORWARD))
        var maximumMagnitude: Float = 0
        for i in ar.indices {
            let real = ar[i] * br[i] + ai[i] * bi[i]
            let imaginary = ar[i] * bi[i] - ai[i] * br[i]
            ar[i] = real
            ai[i] = imaginary
            maximumMagnitude = max(maximumMagnitude, hypot(real, imaginary))
        }
        // Do not amplify empty frequency bins and window leakage to unit energy.
        let spectralFloor = max(maximumMagnitude * 0.0001, 0.000001)
        for i in ar.indices {
            let denominator = max(hypot(ar[i], ai[i]), spectralFloor)
            ar[i] /= denominator
            ai[i] /= denominator
        }
        transform(&ar, &ai, direction: FFTDirection(FFT_INVERSE))
        guard let peakIndex = ar.indices.max(by: { ar[$0] < ar[$1] }) else { return nil }
        let px = peakIndex % size
        let py = peakIndex / size
        func value(_ x: Int, _ y: Int) -> Double {
            Double(ar[((y + size) % size) * size + (x + size) % size])
        }
        func subpixel(_ minus: Double, _ center: Double, _ plus: Double) -> Double {
            let denominator = minus - 2 * center + plus
            guard abs(denominator) > 0.000001 else { return 0 }
            return min(max(0.5 * (minus - plus) / denominator, -0.5), 0.5)
        }
        let peak = Double(ar[peakIndex])
        let dx = Double(px > size / 2 ? px - size : px) + subpixel(value(px - 1, py), peak, value(px + 1, py))
        let dy = Double(py > size / 2 ? py - size : py) + subpixel(value(px, py - 1), peak, value(px, py + 1))
        var sum = 0.0
        var squareSum = 0.0
        var count = 0.0
        var second = 0.0
        for y in 0..<size {
            let distanceY = min(abs(y - py), size - abs(y - py))
            let rowOffset = y * size
            for x in 0..<size {
                let distanceX = min(abs(x - px), size - abs(x - px))
                if distanceX <= 3 && distanceY <= 3 { continue }
                let sample = Double(ar[rowOffset + x])
                sum += sample
                squareSum += sample * sample
                count += 1
                second = max(second, sample)
            }
        }
        let mean = sum / count
        let deviation = sqrt(max(squareSum / count - mean * mean, 0.000001))
        let psr = (peak - mean) / deviation
        let ratio = peak / max(second, 0.000001)
        return PhaseCorrelationEstimate(dx: dx, dy: dy, peakToSidelobe: psr, peakRatio: ratio,
            accepted: psr >= 8 && ratio >= 1.15 && abs(dx) <= 8 && abs(dy) <= 8)
    }

    private func windowWeights(for gridSize: Int) -> [Float] {
        if cachedWindowGridSize == gridSize, cachedWindow.count == size * size {
            return cachedWindow
        }
        let radius = Double(gridSize) * 0.43
        var weights = [Float](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                let distance = hypot(Double(x) - 127.5, Double(y) - 127.5) / radius
                let weight = distance < 1 ? 0.5 * (1 + cos(.pi * distance)) : 0
                weights[y * size + x] = Float(weight)
            }
        }
        cachedWindowGridSize = gridSize
        cachedWindow = weights
        return weights
    }

    private func windowed(_ input: [Float], gridSize: Int, weights: [Float]) -> [Float] {
        let offset = (gridSize - size) / 2
        var weightedSum: Float = 0
        let weightSum = weights.reduce(0, +)
        for y in 0..<size {
            for x in 0..<size { weightedSum += input[(y + offset) * gridSize + x + offset] * weights[y * size + x] }
        }
        let mean = weightedSum / max(weightSum, 0.0001)
        var output = [Float](repeating: 0, count: size * size)
        for y in 0..<size {
            let inputRow = (y + offset) * gridSize + offset
            let outputRow = y * size
            for x in 0..<size {
                output[outputRow + x] = (input[inputRow + x] - mean) * weights[outputRow + x]
            }
        }
        return output
    }

    private func transform(_ real: inout [Float], _ imaginary: inout [Float], direction: FFTDirection) {
        guard let setup else { return }
        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                vDSP_fft2d_zip(setup, &split, 1, 0, logSize, logSize, direction)
            }
        }
    }
}
