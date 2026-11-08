import Foundation

/// Source-file seconds only: playback rate never participates in this geometry.
final class WordTimeline {
    static let plotLeftInset: Double = 38
    static let minimumHitWidth: Double = 44

    // Committed words are immutable and append-only. A reset/reanalysis creates
    // new IDs, so this observes updates without comparing every word on each tick.
    struct Revision: Equatable {
        let count: Int
        let firstID: UUID?
        let lastID: UUID?

        init(_ words: [TranscriptWord]) {
            count = words.count
            firstID = words.first?.id
            lastID = words.last?.id
        }
    }

    struct Span: Identifiable {
        let word: TranscriptWord
        let startX: Double
        let endX: Double
        let hitStartX: Double
        let hitEndX: Double

        var id: UUID { word.id }
        var width: Double { endX - startX }
        var isPoint: Bool { word.start == word.end }
    }

    final class Layout {
        let rows: [[Span]]

        init(rows: [[Span]]) { self.rows = rows }
    }

    private let words: [TranscriptWord]
    private let maximumEnds: [Double]
    private var cachedWindow: ReviewWindow?
    private var cachedWidth: Double?
    private var cachedLayout: Layout?

    init(words: [TranscriptWord]) {
        self.words = words.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.id.uuidString < $1.id.uuidString
        }
        var maximumEnd = -Double.infinity
        maximumEnds = self.words.map {
            maximumEnd = max(maximumEnd, $0.end)
            return maximumEnd
        }
    }

    static func plotWidth(viewWidth: Double) -> Double {
        max(1, viewWidth - plotLeftInset)
    }

    static func x(at time: Double, in window: ReviewWindow, viewWidth: Double) -> Double {
        plotLeftInset + window.fraction(at: time) * plotWidth(viewWidth: viewWidth)
    }

    /// Half-open intervals leave real gaps empty. A point event is current only
    /// at its exact timestamp, including a saved point at EOF.
    func activeWord(at time: Double) -> TranscriptWord? {
        guard time.isFinite else { return nil }
        var low = 0
        var high = words.count
        while low < high {
            let middle = (low + high) / 2
            if words[middle].start <= time { low = middle + 1 } else { high = middle }
        }
        var index = low
        while index > 0 {
            index -= 1
            guard maximumEnds[index] >= time else { break }
            let word = words[index]
            if time < word.end || (word.start == time && word.end == time) { return word }
        }
        return nil
    }

    /// Static layout is reused while the playhead moves within a viewport.
    /// Touch areas are separate from duration geometry and never overlap in a row.
    func layout(in window: ReviewWindow, viewWidth: Double) -> Layout {
        if cachedWindow == window, cachedWidth == viewWidth, let cachedLayout { return cachedLayout }
        var rows: [[Span]] = []
        var rowEnds: [Double] = []
        let plotWidth = Self.plotWidth(viewWidth: viewWidth)
        let rightEdge = Self.plotLeftInset + plotWidth
        var low = 0
        var high = words.count
        while low < high {
            let middle = (low + high) / 2
            if maximumEnds[middle] < window.start { low = middle + 1 } else { high = middle }
        }
        if window.visibleDuration > 0 {
            for word in words[low...] {
                if word.start > window.end { break }
                let isPoint = word.start == word.end
                if isPoint {
                    guard word.start >= window.start, word.start <= window.end else { continue }
                } else {
                    guard word.end > window.start, word.start < window.end else { continue }
                }
                let startX = Self.x(at: max(window.start, word.start), in: window, viewWidth: viewWidth)
                let endX = Self.x(at: min(window.end, word.end), in: window, viewWidth: viewWidth)
                let hitWidth = min(plotWidth, max(Self.minimumHitWidth, endX - startX))
                let hitStartX = min(rightEdge - hitWidth,
                                    max(Self.plotLeftInset, (startX + endX - hitWidth) / 2))
                let span = Span(word: word, startX: startX, endX: endX,
                                hitStartX: hitStartX, hitEndX: hitStartX + hitWidth)
                if let row = rowEnds.firstIndex(where: { $0 + 4 <= hitStartX }) {
                    rows[row].append(span)
                    rowEnds[row] = span.hitEndX
                } else {
                    rows.append([span])
                    rowEnds.append(span.hitEndX)
                }
            }
        }
        let result = Layout(rows: rows)
        cachedWindow = window
        cachedWidth = viewWidth
        cachedLayout = result
        return result
    }
}
