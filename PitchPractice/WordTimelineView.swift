import SwiftUI

struct WordTimelineView: View {
    let words: [TranscriptWord]
    let window: ReviewWindow
    let playbackTime: Double
    let canSeek: Bool
    let seek: (Double) -> Void
    @State private var timeline: WordTimeline?
    @State private var visibleRows = 1
    @ScaledMetric(relativeTo: .caption) private var rowHeight: CGFloat = 44

    var body: some View {
        let activeWord = timeline?.activeWord(at: playbackTime)
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geometry in
                if let timeline {
                    let layout = timeline.layout(in: window, viewWidth: Double(geometry.size.width))
                    ZStack(alignment: .topLeading) {
                        if layout.rows.isEmpty {
                            Text("No timed words in this section")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, WordTimeline.plotLeftInset)
                        } else {
                            ScrollViewReader { scroll in
                                ScrollView(.vertical) {
                                    WordTimelineSpans(layout: layout, activeID: activeWord?.id,
                                                      canSeek: canSeek, rowHeight: rowHeight, seek: seek)
                                        .equatable()
                                }
                                .scrollBounceBehavior(.basedOnSize)
                                .scrollIndicatorsFlash(trigger: layout.rows.count)
                                .onChange(of: activeWord?.id) { _, activeID in
                                    if let activeID {
                                        scroll.scrollTo(activeID, anchor: .center)
                                    }
                                }
                            }
                        }
                        if playbackTime >= window.start, playbackTime <= window.end {
                            Rectangle()
                                .fill(.primary.opacity(0.35))
                                .frame(width: 1.5)
                                .offset(x: WordTimeline.x(at: playbackTime, in: window,
                                                           viewWidth: Double(geometry.size.width)) - 0.75)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .onChange(of: layout.rows.count, initial: true) { _, count in
                        visibleRows = min(6, max(1, count))
                    }
                }
            }
            .frame(height: rowHeight * CGFloat(visibleRows))
        }
        .onChange(of: WordTimeline.Revision(words), initial: true) { _, _ in
            timeline = WordTimeline(words: words)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wordTimeline")
    }
}

private struct WordTimelineSpans: View, Equatable {
    let layout: WordTimeline.Layout
    let activeID: UUID?
    let canSeek: Bool
    let rowHeight: CGFloat
    let seek: (Double) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.layout === rhs.layout && lhs.activeID == rhs.activeID &&
            lhs.canSeek == rhs.canSeek && lhs.rowHeight == rhs.rowHeight
    }

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(layout.rows.indices, id: \.self) { row in
                ZStack(alignment: .topLeading) {
                    ForEach(layout.rows[row]) { span in
                        wordButton(span)
                            .offset(x: span.hitStartX)
                            .id(span.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: rowHeight)
            }
        }
    }

    private func wordButton(_ span: WordTimeline.Span) -> some View {
        let isActive = span.id == activeID
        return Button {
            seek(span.word.start)
        } label: {
            ZStack(alignment: .topLeading) {
                Text(span.word.text)
                    .font(.caption.weight(isActive ? .bold : .regular))
                    .foregroundStyle(isActive ? Color.accentColor : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: span.hitEndX - span.hitStartX, alignment: .leading)
                if span.isPoint {
                    // A vertical marker is an event, never an invented duration.
                    Rectangle()
                        .fill(isActive ? Color.accentColor : .secondary)
                        .frame(width: 1, height: 12)
                        .offset(x: span.startX - span.hitStartX - 0.5, y: rowHeight - 17)
                } else {
                    Rectangle()
                        .fill(isActive ? Color.accentColor : Color.accentColor.opacity(0.4))
                        .frame(width: span.width, height: 7)
                        .offset(x: span.startX - span.hitStartX, y: rowHeight - 14)
                }
            }
            .frame(width: span.hitEndX - span.hitStartX, height: rowHeight, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canSeek)
        .accessibilityLabel(span.word.text)
        .accessibilityValue("Start \(span.word.start.formatted(.number.precision(.fractionLength(2)))) seconds, end \(span.word.end.formatted(.number.precision(.fractionLength(2)))) seconds\(isActive ? ", current word" : "")")
        .accessibilityHint("Seek to this word, keeping playback speed and whether audio is playing or paused")
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityIdentifier("transcriptWord-\(span.id.uuidString)")
        .contextMenu {
            Text(span.word.text)
            Button("Seek to word", systemImage: "play") { seek(span.word.start) }
                .disabled(!canSeek)
        }
    }
}
