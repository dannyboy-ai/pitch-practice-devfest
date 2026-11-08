import SwiftUI

extension PitchTuning {
    var color: Color {
        switch direction {
        case .flat: .blue
        case .centered: .green
        case .sharp: .orange
        }
    }

    var label: String {
        switch direction {
        case .flat: "Flat"
        case .centered: "On pitch"
        case .sharp: "Sharp"
        }
    }

    var symbol: String {
        switch direction {
        case .flat: "arrow.down"
        case .centered: "checkmark.circle.fill"
        case .sharp: "arrow.up"
        }
    }

    var guidance: String {
        switch direction {
        case .flat: "Sing a little higher"
        case .centered: "Within 10 cents"
        case .sharp: "Sing a little lower"
        }
    }
}

struct TuningIndicator: View {
    let midi: Double?

    var body: some View {
        VStack(spacing: 4) {
            if let midi {
                let tuning = PitchTuning(midi: midi)
                Label(tuning.label, systemImage: tuning.symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tuning.color)
                Text(tuning.guidance)
                    .font(.subheadline)
                Text(String(format: "%+.0f¢ from nearest note %@", tuning.cents,
                            PitchNote.name(Int(midi.rounded()))))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("No clear pitch")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("tuningIndicator")
    }
}

struct StaffPair: View {
    let pitch: Double?
    let noteColor: Color
    var isInteractive = false
    var onPitchChange: ((Double) -> Void)? = nil

    var body: some View {
        VStack(spacing: 20) {
            MusicStaff(
                title: "TENOR TREBLE",
                clef: "𝄞",
                midi: pitch.map { Int($0.rounded()) + 12 },
                caption: pitch.map { "written \(PitchNote.name(Int($0.rounded()) + 12))" },
                color: noteColor,
                isTreble: true,
                isInteractive: isInteractive,
                onPitchChange: onPitchChange
            )
            MusicStaff(
                title: "BASS",
                clef: "𝄢",
                midi: pitch.map { Int($0.rounded()) },
                caption: pitch.map { "sounds \(PitchNote.name(Int($0.rounded())))" },
                color: noteColor,
                isTreble: false,
                isInteractive: isInteractive,
                onPitchChange: onPitchChange
            )
        }
    }
}

enum ReplayClef: String, CaseIterable {
    case tenor = "Treble"
    case bass = "Bass"
}

/// One readout for the active timeline point; staff and labels share a spelling.
struct ReplayPitchBadge: View {
    let midi: Double?
    let clef: ReplayClef
    let emptyLabel: String

    var body: some View {
        let tuning = midi.map { PitchTuning(midi: $0) }
        let color = tuning?.color ?? .secondary
        HStack(spacing: 10) {
            MusicStaff(
                title: "", clef: clef == .tenor ? "𝄞" : "𝄢",
                midi: midi.map { Int($0.rounded()) + (clef == .tenor ? 12 : 0) },
                caption: nil, color: color, isTreble: clef == .tenor,
                isInteractive: false, onPitchChange: nil,
                compact: true
            )
            .frame(width: 86, height: 90)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                if let midi, let tuning {
                    Text(PitchNote.name(Int(midi.rounded())))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Label(tuning.label, systemImage: tuning.symbol)
                        .font(.subheadline.weight(.semibold))
                    Text(tuning.direction == .centered ? "Within 10¢" :
                            String(format: "%.0f¢ %@", abs(tuning.cents), tuning.cents < 0 ? "low" : "high"))
                        .font(.caption.monospacedDigit())
                } else {
                    Text(emptyLabel).font(.headline)
                    Text("Tap or drag to explore").font(.caption).foregroundStyle(Color.secondary)
                }
            }
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).strokeBorder(color.opacity(0.4), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("playheadPitch")
    }
}

private struct MusicStaff: View {
    let title: String
    let clef: String
    let midi: Int?
    let caption: String?
    let color: Color
    let isTreble: Bool
    let isInteractive: Bool
    let onPitchChange: ((Double) -> Void)?
    var compact = false

    var body: some View {
        GeometryReader { geometry in
            let bottomY = 80.0
            let step = 4.5
            let staffSpace = step * 2
            let clefSize = staffSpace * (isTreble ? 10 : 5)
            let clefLineY = bottomY - staffSpace * (isTreble ? 1 : 3)
            let noteX = geometry.size.width * (compact ? 0.78 : 0.68)
            let notation = midi.map { notationForMIDI($0) }
            let baseDiatonic = isTreble ? 30 : 18
            let staffOffset = notation.map { $0.diatonic - baseDiatonic }
            let noteY = bottomY - Double(staffOffset ?? 4) * step
            let drawingTop = min(16, noteY - ((staffOffset ?? 4) < 4 ? 34 : 10))
            let drawingBottom = max(96, noteY + ((staffOffset ?? 4) >= 4 ? 34 : 10))
            let scale = compact ? min(1, geometry.size.height / (drawingBottom - drawingTop)) : 1

            ZStack(alignment: .topLeading) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .position(x: 62, y: 7)

                ForEach(0..<5, id: \.self) { line in
                    Rectangle()
                        .fill(.primary.opacity(0.65))
                        .frame(height: 1)
                        .position(x: geometry.size.width / 2, y: bottomY - Double(line) * step * 2)
                }

                // Align the G-clef curl and F-clef dot midpoint, not their text boxes.
                Text(clef)
                    .font(.system(size: clefSize))
                    .position(x: compact ? 22 : 31, y: clefLineY + clefSize * (isTreble ? -0.16 : 0.09))


                if let notation, let staffOffset {
                    ForEach(ledgerLines(for: staffOffset), id: \.self) { line in
                        Rectangle()
                            .fill(.primary)
                            .frame(width: 30, height: 1)
                            .position(x: noteX, y: bottomY - Double(line * 2) * step)
                    }

                    if !notation.accidental.isEmpty {
                        Text(notation.accidental)
                            .font(.title3)
                            .position(x: noteX - 19, y: bottomY - Double(staffOffset) * step)
                    }

                    Capsule()
                        .fill(color)
                        .frame(width: 19, height: 13)
                        .rotationEffect(.degrees(-14))
                        .position(x: noteX, y: bottomY - Double(staffOffset) * step)

                    Rectangle()
                        .fill(color)
                        .frame(width: 2, height: 31)
                        .position(
                            x: noteX + (staffOffset < 4 ? 8 : -8),
                            y: bottomY - Double(staffOffset) * step + (staffOffset < 4 ? -13 : 13)
                        )

                    if let caption {
                        Text(caption)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .position(x: geometry.size.width - 55, y: 7)
                    }
                }
            }
            .scaleEffect(scale, anchor: .topLeading)
            .offset(x: compact ? geometry.size.width * (1 - scale) / 2 : 0,
                    y: compact ? (geometry.size.height - (drawingBottom - drawingTop) * scale) / 2 - drawingTop * scale : 0)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isInteractive else { return }
                        let staffStep = Int(((bottomY - value.location.y) / step).rounded())
                        let selectedDiatonic = max(isTreble ? 21 : 14, min(isTreble ? 49 : 42, baseDiatonic + staffStep))
                        let writtenMIDI = midiForDiatonic(selectedDiatonic)
                        onPitchChange?(Double(isTreble ? writtenMIDI - 12 : writtenMIDI))
                    },
                including: isInteractive ? .all : .none
            )
        }
    }
}

private func notationForMIDI(_ midi: Int) -> (diatonic: Int, accidental: String) {
    let pitchClass = (midi % 12 + 12) % 12
    let notation: (Int, String)
    switch pitchClass {
    case 0: notation = (0, "")
    case 1: notation = (0, "♯")
    case 2: notation = (1, "")
    case 3: notation = (2, "♭")
    case 4: notation = (2, "")
    case 5: notation = (3, "")
    case 6: notation = (3, "♯")
    case 7: notation = (4, "")
    case 8: notation = (4, "♯")
    case 9: notation = (5, "")
    case 10: notation = (6, "♭")
    default: notation = (6, "")
    }
    return ((midi / 12 - 1) * 7 + notation.0, notation.1)
}

private func ledgerLines(for noteOffset: Int) -> Range<Int> {
    noteOffset < 0 ? (noteOffset / 2)..<0 : 5..<max(5, noteOffset / 2 + 1)
}
private func midiForDiatonic(_ diatonic: Int) -> Int {
    let naturalSemitones = [0, 2, 4, 5, 7, 9, 11]
    let octave = Int(floor(Double(diatonic) / 7))
    let degree = (diatonic % 7 + 7) % 7
    return (octave + 1) * 12 + naturalSemitones[degree]
}
