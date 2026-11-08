import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw NSError(domain: "WordTimelineTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private func near(_ lhs: Double, _ rhs: Double) -> Bool { abs(lhs - rhs) < 0.000001 }

@main
struct WordTimelineTests {
    static func main() throws {
        try heldWordsAndSourceClock()
        try clippingAndSeeking()
        try gapsAndActiveWords()
        try denseAndOverlappingWords()
        try pointEventsAndEOF()
        print("PASS: word duration scale, clipping/seek identity, gaps, overlap/targets, zero-duration/EOF")
    }

    private static func word(_ text: String, _ start: Double, _ end: Double) -> TranscriptWord {
        TranscriptWord(id: UUID(), start: start, end: end, text: text)
    }

    private static func heldWordsAndSourceClock() throws {
        let held = word("cross", 2, 5)
        let timeline = WordTimeline(words: [held])
        let window = ReviewWindow(duration: 10)
        let width = 338.0
        let span = timeline.layout(in: window, viewWidth: width).rows[0][0]
        try require(near(span.startX, 98) && near(span.endX, 188), "A held three-second word uses its exact start and end")
        try require(near(span.width / WordTimeline.plotWidth(viewWidth: width), 0.3),
                    "Three seconds occupies 30% of a ten-second plot, excluding the shared axis gutter")
        let labelVariant = WordTimeline(words: [word("a much longer label", 2, 5)])
            .layout(in: window, viewWidth: width).rows[0][0]
        try require(near(span.width, labelVariant.width), "Label length never changes duration geometry")
    }

    private static func clippingAndSeeking() throws {
        let before = word("before", 0, 10)
        let crossingStart = word("held", 8, 13)
        let crossingEnd = word("end", 18, 23)
        let after = word("after", 20, 24)
        let window = ReviewWindow(duration: 30, windowDuration: 10, start: 10)
        let spans = WordTimeline(words: [before, crossingStart, crossingEnd, after])
            .layout(in: window, viewWidth: 438).rows.flatMap { $0 }
        try require(spans.count == 2, "Words merely touching a viewport edge do not fabricate a visible interval")
        let leading = spans.first { $0.id == crossingStart.id }!
        let trailing = spans.first { $0.id == crossingEnd.id }!
        try require(near(leading.startX, 38) && near(leading.endX, 158), "A held word clips at the viewport's left edge")
        try require(near(trailing.startX, 358) && near(trailing.endX, 438), "A word clips at the exact right edge")
        try require(leading.word.start == 8 && leading.word.end == 13 && leading.id == crossingStart.id,
                    "The tap action retains the original source start and stable word identity, not the clipped start")
        var followingWindow = window
        followingWindow.follow(leading.word.start)
        try require(followingWindow.start <= leading.word.start && followingWindow.end > leading.word.start,
                    "Seeking a clipped word can follow its original start into the preceding viewport")
    }

    private static func gapsAndActiveWords() throws {
        let first = word("one", 1, 2)
        let second = word("two", 5, 6)
        let adjacent = word("three", 6, 7)
        let timeline = WordTimeline(words: [first, second, adjacent])
        let spans = timeline.layout(in: ReviewWindow(duration: 10), viewWidth: 1038).rows.flatMap { $0 }
        let firstSpan = spans.first { $0.id == first.id }!
        let secondSpan = spans.first { $0.id == second.id }!
        try require(near(secondSpan.startX - firstSpan.endX, 300), "Three-second gaps remain empty on the duration lane")
        try require(timeline.activeWord(at: 0) == nil && timeline.activeWord(at: 3) == nil,
                    "Neither initial gaps nor inter-word gaps borrow a word")
        try require(timeline.activeWord(at: 1)?.id == first.id && timeline.activeWord(at: 2) == nil,
                    "Duration intervals include their start and exclude their end")
        try require(timeline.activeWord(at: 6)?.id == adjacent.id, "A shared boundary activates the following word")
        try require(timeline.activeWord(at: .nan) == nil && timeline.activeWord(at: .infinity) == nil,
                    "Invalid clocks do not activate a word")
    }

    private static func denseAndOverlappingWords() throws {
        let held = word("held", 0, 8)
        let short = word("short", 2, 2.01)
        let repeated = word("short", 2.02, 2.03)
        let overlap = word("overlap", 2, 4)
        let timeline = WordTimeline(words: [repeated, held, short, overlap])
        let layout = timeline.layout(in: ReviewWindow(duration: 10), viewWidth: 338)
        let spans = layout.rows.flatMap { $0 }
        try require(Set(spans.map(\.id)).count == 4, "Repeated and overlapping words remain distinct accessible spans")
        try require(layout.rows.count > 1, "Dense touch targets are staggered instead of overlapping")
        let shortSpan = spans.first { $0.id == short.id }!
        try require(near(shortSpan.width, 0.3), "A tiny word is not stretched to label or touch-target width")
        try require(shortSpan.hitEndX - shortSpan.hitStartX >= 44, "A short word still has a separate usable touch target")
        for row in layout.rows {
            for pair in zip(row, row.dropFirst()) {
                try require(pair.0.hitEndX < pair.1.hitStartX, "Same-row hit targets never overlap or create ambiguous taps")
            }
            for span in row {
                try require(span.hitStartX >= 38 && span.hitEndX <= 338, "Touch targets stay inside the source-time plot")
            }
        }
        try require(timeline.activeWord(at: 3)?.id == overlap.id, "The latest overlapping word is current")
        try require(timeline.activeWord(at: 5)?.id == held.id, "An earlier held word remains active after a nested word ends")
    }

    private static func pointEventsAndEOF() throws {
        let point = word("point", 4, 4)
        let last = word("last", 8, 10)
        let eof = word("end event", 10, 10)
        let timeline = WordTimeline(words: [point, last, eof])
        let window = ReviewWindow(duration: 10)
        let spans = timeline.layout(in: window, viewWidth: 338).rows.flatMap { $0 }
        let marker = spans.first { $0.id == point.id }!
        let eofMarker = spans.first { $0.id == eof.id }!
        try require(marker.isPoint && marker.width == 0 && near(marker.startX, 158),
                    "Zero-duration words are markers with no invented interval")
        try require(eofMarker.isPoint && eofMarker.width == 0 && near(eofMarker.startX, 338),
                    "An EOF event remains visible on the right edge")
        try require(timeline.activeWord(at: 4)?.id == point.id && timeline.activeWord(at: 4.001) == nil,
                    "A point event is active only at its source timestamp")
        try require(timeline.activeWord(at: 10)?.id == eof.id && timeline.activeWord(at: 10.001) == nil,
                    "EOF does not hold a finished word past its interval")
        let withoutPoint = WordTimeline(words: [last])
        try require(withoutPoint.activeWord(at: 10) == nil, "An ordinary interval is not active at EOF")
        var partialWindow = ReviewWindow(duration: 25)
        partialWindow.follow(22)
        let partial = WordTimeline(words: [word("partial", 22, 25)])
            .layout(in: partialWindow, viewWidth: 338).rows[0][0]
        try require(near(partial.width, 180), "The final partial viewport uses its actual five-second duration, like pitch")
        try require(timeline.layout(in: ReviewWindow(duration: 0), viewWidth: 338).rows.isEmpty,
                    "An empty recording has no fabricated timing area")
    }

}
