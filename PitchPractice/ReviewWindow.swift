import Foundation

/// Absolute recording times for a zoomable viewport. Sections retain their size
/// at the end of a take; the final section may have a shorter visible duration.
struct ReviewWindow: Equatable, Sendable {
    static let defaultDuration: Double = 10
    static let minimumDuration: Double = 1

    let duration: Double
    private(set) var start: Double
    private(set) var windowDuration: Double

    var end: Double { min(duration, start + windowDuration) }
    var visibleDuration: Double { end - start }
    var canMovePrevious: Bool { start > 0 }
    var canMoveNext: Bool { end < duration }
    var canZoomIn: Bool { visibleDuration > min(Self.minimumDuration, duration) }
    var canZoomOut: Bool { visibleDuration < duration }

    init(duration: Double, windowDuration: Double = Self.defaultDuration, start: Double = 0) {
        self.duration = duration.isFinite ? max(0, duration) : 0
        let requested = windowDuration.isFinite ? windowDuration : Self.defaultDuration
        self.windowDuration = min(self.duration, max(Self.minimumDuration, requested))
        self.start = min(max(0, start.isFinite ? start : 0), max(0, self.duration - self.windowDuration))
    }

    func time(atFraction fraction: Double) -> Double {
        start + min(1, max(0, fraction.isFinite ? fraction : 0)) * visibleDuration
    }

    func fraction(at time: Double) -> Double {
        guard visibleDuration > 0 else { return 0 }
        return min(1, max(0, (time - start) / visibleDuration))
    }

    mutating func moveSection(by direction: Int) {
        guard windowDuration > 0, direction != 0 else { return }
        if direction > 0, canMoveNext {
            start = end
        } else if direction < 0 {
            start = max(0, start - windowDuration)
        }
    }

    /// Factors greater than one magnify; the anchor keeps its absolute time and
    /// relative position unless a recording boundary prevents that placement.
    mutating func zoom(by factor: Double, anchorFraction: Double = 0.5) {
        guard factor.isFinite, factor > 0, duration > 0 else { return }
        let fraction = min(1, max(0, anchorFraction.isFinite ? anchorFraction : 0.5))
        let anchor = time(atFraction: fraction)
        windowDuration = min(duration, max(min(Self.minimumDuration, duration), visibleDuration / factor))
        start = min(max(0, anchor - fraction * windowDuration), max(0, duration - windowDuration))
    }

    mutating func reset(around time: Double) {
        windowDuration = min(Self.defaultDuration, duration)
        start = 0
        follow(time)
    }

    mutating func showFullTake() {
        start = 0
        windowDuration = duration
    }

    /// Called only when the UI is not manipulating the viewport. A time on the
    /// right edge advances to the next section, except at the recording's end.
    mutating func follow(_ time: Double) {
        guard time.isFinite, duration > 0, windowDuration > 0 else { return }
        let time = min(duration, max(0, time))
        if time >= start, time < end || (time == duration && end == duration) { return }
        let sectionOffset = floor((time - start) / windowDuration)
        start = min(duration, max(0, start + sectionOffset * windowDuration))
        if start == duration { start = max(0, duration - windowDuration) }
    }
}

/// Fits only frames overlapping the visible section. The scale does not depend
/// on the playhead, so scrubbing and playback cannot move the note rows.
struct ReviewPitchSection {
    let frameRange: Range<Int>
    let lowerMIDI: Int
    let upperMIDI: Int
    let labels: [Int]
    let hasPitch: Bool

    init(frames: [PitchFrame], window: ReviewWindow) {
        var lower = 0
        var upper = frames.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if frames[middle].time + frames[middle].duration <= window.start {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let first = lower
        upper = frames.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if frames[middle].time < window.end { lower = middle + 1 } else { upper = middle }
        }
        frameRange = first..<lower

        var lowest = Double.infinity
        var highest = -Double.infinity
        for index in frameRange {
            if let midi = frames[index].midi {
                lowest = min(lowest, midi)
                highest = max(highest, midi)
            }
        }
        hasPitch = lowest.isFinite
        if !hasPitch {
            lowest = 60
            highest = lowest
        }
        let paddedLower = Int(floor(lowest)) - 1
        let paddedUpper = Int(ceil(highest)) + 1
        // At least six semitones, with room above and below the actual trace.
        lowerMIDI = min(paddedLower, Int(floor(Double(paddedLower + paddedUpper - 6) / 2)))
        upperMIDI = max(paddedUpper, lowerMIDI + 6)
        let labelStep = max(1, Int(ceil(Double(upperMIDI - lowerMIDI) / 12)))
        labels = Array(stride(from: lowerMIDI, through: upperMIDI, by: labelStep))
    }

    func verticalFraction(for midi: Double) -> Double {
        1 - (midi - Double(lowerMIDI)) / Double(upperMIDI - lowerMIDI)
    }
}
