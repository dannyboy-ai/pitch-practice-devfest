import Accelerate
import Foundation

enum PitchNote {
    static let supportedRange: ClosedRange<Double> = 36...84
    private static let names = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "G♯", "A", "B♭", "B"]

    static func name(_ midi: Int) -> String {
        let pitchClass = ((midi % 12) + 12) % 12
        return names[pitchClass]
    }

    static func frequency(_ midi: Double) -> Double {
        440 * pow(2, (midi - 69) / 12)
    }

    static func midi(_ frequency: Double) -> Double {
        69 + 12 * log2(frequency / 440)
    }
}

struct PitchTuning: Sendable {
    enum Direction: Sendable {
        case flat, centered, sharp
    }

    let cents: Double
    let direction: Direction

    init(midi: Double) {
        cents = (midi - midi.rounded()) * 100
        // Ignore floating-point noise at the ten-cent boundary.
        direction = abs(cents) <= 10 + 1e-8 ? .centered : (cents < 0 ? .flat : .sharp)
    }
}

struct PitchEstimate: Sendable {
    let midi: Double?
    let confidence: Double
}

/// A single-stream detector. Call serially; scratch memory is retained between frames.
final class PitchAnalyzer {
    private let sampleRate: Double
    private let capacity: Int
    private let differences: UnsafeMutablePointer<Float>
    private let normalized: UnsafeMutablePointer<Float>
    private let delta: UnsafeMutablePointer<Float>

    init(sampleRate: Double, maximumFrameCount: Int = 4096) {
        self.sampleRate = sampleRate
        capacity = max(1, maximumFrameCount)
        differences = .allocate(capacity: capacity + 1)
        normalized = .allocate(capacity: capacity + 1)
        delta = .allocate(capacity: capacity)
    }

    deinit {
        differences.deallocate()
        normalized.deallocate()
        delta.deallocate()
    }

    func analyze(_ samples: UnsafePointer<Float>, count: Int) -> PitchEstimate {
        let silence = PitchEstimate(midi: nil, confidence: 0)
        guard sampleRate.isFinite, sampleRate > 0, count >= 32, count <= capacity else { return silence }

        var mean: Float = 0
        var meanSquare: Float = 0
        vDSP_meanv(samples, 1, &mean, vDSP_Length(count))
        vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(count))
        let variance = meanSquare - mean * mean
        guard variance.isFinite, variance > 0.002 * 0.002 else { return silence }

        let shortestPeriod = sampleRate / PitchNote.frequency(PitchNote.supportedRange.upperBound)
        let longestPeriod = sampleRate / PitchNote.frequency(PitchNote.supportedRange.lowerBound)
        // Guard conversion as well as unsupported sample rates before forming integer lags.
        guard shortestPeriod >= 2, longestPeriod < Double(Int.max - 2) else { return silence }
        let minimumLag = max(2, Int(floor(shortestPeriod)) - 1)
        let maximumLag = min(count / 2, Int(ceil(longestPeriod)) + 2)
        guard maximumLag > minimumLag + 1 else { return silence }

        // Every lag uses the same window length. In particular, lags below the
        // vocal search range MUST contribute to YIN's cumulative normalization.
        let window = vDSP_Length(count - maximumLag)
        differences[0] = 0
        normalized[0] = 1
        var sum: Double = 0
        for lag in 1...maximumLag {
            vDSP_vsub(samples, 1, samples.advanced(by: lag), 1, delta, 1, window)
            vDSP_svesq(delta, 1, differences.advanced(by: lag), window)
            sum += Double(differences[lag])
            normalized[lag] = sum > 0 ? Float(Double(differences[lag]) * Double(lag) / sum) : 1
        }

        var candidate: Int?
        var lag = minimumLag
        while lag < maximumLag {
            if normalized[lag] < 0.15 {
                while lag < maximumLag && normalized[lag + 1] < normalized[lag] { lag += 1 }
                candidate = lag
                break
            }
            lag += 1
        }
        if candidate == nil {
            var best = minimumLag
            for index in (minimumLag + 1)...maximumLag where normalized[index] < normalized[best] {
                best = index
            }
            if normalized[best] < 0.22 { candidate = best }
        }
        guard var period = candidate, period < maximumLag else { return silence }

        // A dominant second harmonic can produce an early, shallow minimum.
        // Prefer its octave-lower period only with substantially stronger evidence;
        // never choose later multiples of an already near-perfect periodic tone.
        if normalized[period] > 0.015, period * 2 + 2 < maximumLag {
            let lower = max(period + 1, period * 2 - 2)
            let upper = min(maximumLag - 1, period * 2 + 2)
            var doubled = lower
            for index in lower...upper where normalized[index] < normalized[doubled] { doubled = index }
            if normalized[doubled] < normalized[period] * 0.2 { period = doubled }
        }

        let left = Double(normalized[period - 1])
        let center = Double(normalized[period])
        let right = Double(normalized[period + 1])
        let curvature = left - 2 * center + right
        let offset = curvature > 0.000_000_1 ? 0.5 * (left - right) / curvature : 0
        let refined = Double(period) + min(0.5, max(-0.5, offset))
        let midi = PitchNote.midi(sampleRate / refined)
        let confidence = max(0, min(1, 1 - center))
        // Small tolerance retains genuinely boundary notes despite interpolation
        // error, without rounding away the raw cents of an accepted estimate.
        guard midi.isFinite,
              midi >= PitchNote.supportedRange.lowerBound - 0.05,
              midi <= PitchNote.supportedRange.upperBound + 0.05 else {
            return PitchEstimate(midi: nil, confidence: confidence)
        }
        return PitchEstimate(midi: midi, confidence: confidence)
    }
}

struct PitchFrame: Codable, Sendable {
    let time: Double
    let duration: Double
    let midi: Double?
    let confidence: Double
}

struct TakeAnalysis: Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    var title: String
    let createdAt: Date
    let duration: Double
    let frames: [PitchFrame]

    init(title: String, createdAt: Date, duration: Double, frames: [PitchFrame]) {
        version = Self.currentVersion
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.frames = frames
    }

    func frame(at time: Double) -> PitchFrame? {
        guard time.isFinite, time >= 0, time < duration else { return nil }
        var lower = 0
        var upper = frames.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if frames[middle].time <= time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower > 0 else { return nil }
        let frame = frames[lower - 1]
        return time < frame.time + frame.duration ? frame : nil
    }
}
