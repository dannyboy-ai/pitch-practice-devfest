import AVKit
import MediaPlayer
import SwiftUI

struct PlaybackOutputControls: View {
    let detector: PitchDetector

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Output device")
                    Text(detector.playbackRouteName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                PlaybackRoutePicker()
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("Choose audio output")
                    .accessibilityIdentifier("playbackRoutePicker")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("System volume").font(.subheadline)
                PlaybackSystemVolume()
                    .frame(height: 32)
                    .accessibilityIdentifier("playbackSystemVolume")
            }

            Toggle("Boost quiet recordings", isOn: Binding(
                get: { detector.playbackBoost },
                set: { detector.setPlaybackBoost($0) }
            ))
            .disabled(!detector.canPlayReview)
            .accessibilityIdentifier("playbackBoostToggle")

            Text("Up to +12 dB with peak limiting. Saved audio is unchanged; start at a comfortable volume.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("playbackOutputControls")
    }
}

private struct PlaybackRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) { }
}

private struct PlaybackSystemVolume: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsRouteButton = false
        view.showsVolumeSlider = true
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) { }
}
