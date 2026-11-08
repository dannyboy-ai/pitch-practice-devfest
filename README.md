# Pitch Practice

A local-only iPhone pitch tool, practice recorder, and approximate lyric navigator. Requires iOS 26 or later.

Public source snapshot for DevFest. This is the code submission, not an App Store or TestFlight download. Recordings, bundled model weights, build products, and prior repository history are not included; model setup and build instructions are below.

## Use

- **One main screen:** the bass and tenor-style treble staves, pitch readout, and sliding pitch lane stay together. Select a reference on the staff or lane while the microphone is stopped; there is no duplicate stepper.
- **Listen:** plays the selected reference note. **Tune:** uses the microphone to show your current note and cents relative to the nearest semitone without saving. **Practice:** records audio and pitch; **Stop & Review** saves the take and opens review. Starting Practice from Tune starts a fresh recording; playing a reference stops unsaved tuning.
- **Reference loudness:** the three-second reference tone sustains its level, with short attack/release fades to avoid clicks. Its harmonic mix peaks below full scale (about 0.96), with roughly +8 dB of gain over the earlier tone. The iPhone's system volume and selected output still control listening volume; saved recordings are unchanged.
- **Review:** opens as a full-screen navigation destination with a **Take** title, lowercase `9:42 pm`-style timestamp, and **Saved** indicator once the recording is loaded. Custom names remain supported. **Done** retains the saved recording and reference selection, returning to a ready main screen without starting the microphone.
- **Pitch graph:** opens a ten-second section. Use the arrows to move through sections, pinch or use the magnifying-glass buttons to zoom (down to one second), **10 sec** to reset, or **Full take** for an overview. Tap/drag the graph to seek inside the visible section; the bottom slider seeks across the entire recording. Time labels are absolute recording times. The playhead and note readout follow the audio sample clock, and the section advances during playback. Scrubbing pauses playback until release; paused scrubbing stays paused. Play at the end restarts from the beginning.
- **Words on the graph:** recognized whole words sit directly above the pitch trace on the same time axis. Each bar shows the recognizer's estimated start and end, including words that cross section boundaries; gaps remain unlabeled audio, not detected breaths. The current word follows the source-audio clock at every speed. Tap a word to seek its original start, retaining playback speed and playing/paused state. Zoom in for short words, scroll the compact word lane for stacked labels, or long-press for the full text. These are approximate word windows, not syllable alignment or reliable held-vowel boundaries.
- **Recognition status:** open from **•••** or the compact unfinished-analysis status above the trace. This secondary sheet contains saved phrases, preparation/progress, errors, and Analyze/Resume/Retry actions. Older phrase-only transcripts offer **Add word timing** and retain their saved phrases during reanalysis. Recording and review never wait for recognition. Recognition can miss or invent sung words and is not verified lyrics; empty output does not establish silence.
- **Playback:** Play/Pause, speed, the full-recording scrubber, and Done stay at the bottom. Ordinary review fits on one screen; small displays and larger text can scroll the content without losing the controls. Choose **¼×**, **½×**, **¾×**, or **1×**. Slow replay preserves pitch and original recording time. Changing speed keeps position and playing/paused state; seeking and replay retain that speed. Each opened take starts at **1×**. Saved audio and analysis are unchanged.
- **Replay pitch display:** the graph fits the pitches in the visible section instead of the whole recording, with nearby note names on the left. Its scale stays fixed while the playhead moves through that section; zooming or changing sections refits it. The fixed readout above the trace shows the active staff note, name, flat/sharp arrow, and cents low/high. Choose **Treble** (tenor-style notation, written an octave above sounding pitch) or **Bass** above the graph; this preference is saved. Wide full-take overviews thin axis labels, not pitch data.
- **Secondary actions:** **••• → Audio output** provides route selection, system volume, and **Boost quiet recordings** (+12 dB before a peak limiter). It never changes saved audio or analysis. Playback uses the iPhone speaker without headphones/external output; output changes pause playback. **Rename** and confirmed **Delete Recording** also live in this menu.
- **Recordings:** open the waveform button on the main screen to reopen saved takes. Closing review returns to the screen that opened it. Deletion removes audio, pitch analysis, metadata, and transcript together only after confirmation.
- **Tuning:** labels omit octave numbers and consistently use E♭/B♭ alongside C♯/F♯/G♯ across the staff, lane, readout, and review. Down-arrow **Flat** means sing higher; up-arrow **Sharp** means sing lower; green **On pitch** means within ten cents of the nearest note. Fixed-reference comparison is removed, including when reviewing older takes that saved a target.

Pitch detection supports monophonic voice from **C2 through C6**, with A4 = 440 Hz. Silence or uncertain detection produces a gap, not a held previous note. Free singing reports the notes detected; it cannot know your intended melody. Backgrounding, audio interruptions, and input-device changes stop capture and save any active practice take; playback also pauses. Reference playback is stopped before microphone capture starts.

## Local storage

`Documents/Recordings` contains original `.caf` audio, versioned `.pitch.json` analysis, small `.metadata.json` headers, and `.transcript.json` recognition checkpoints. New audio filenames use UUIDs. Pitch, phrase, and word timestamps use original recording time; review duration comes from the audio file itself. Renaming does not change audio filenames or invalidate saved words. Version 2 transcripts retain full word intervals and stable word IDs. Version 1 phrase-only transcripts remain readable; adding word timing restarts recognition from the beginning and retains the prior phrases until successful completion.

Existing date-named CAF recordings stay untouched. Opening an old recording streams its audio through the detector and saves adjacent analysis files. Missing, outdated, or invalid analysis is rebuilt from the original audio. Nothing is uploaded; no account or server is involved. Microphone permission is required only to tune or practice, not to hear a reference.

## On-device transcription

The app uses one fixed compressed Whisper Turbo checkpoint through the shared `LocalSpeech` package and WhisperKit 1.1.0. There is no production engine/model picker, remote inference, runtime asset download, or Apple Speech dependency. Approximately 629.5 MB of pinned model/tokenizer assets are bundled. Mel processing uses CPU only; the encoder and decoder use CPU/Neural Engine. No background GPU entitlement is needed.

One coordinator owns one model and one decode operation. It prepares asynchronously when the app enters the foreground and stays loaded between takes while the app is open; idle time no longer unloads it. The newly finished take gets priority over older queued work after the current decode window. Backgrounding without a processing grant, memory warnings, and serious thermal pressure pause analysis and release the model. Foreground recovery resumes eligible pending work. Saved phrases and word spans remain available without model preparation. Cold preparation after an update can still take time; review identifies preparation rather than showing only a generic pending label.

The microphone callback writes the original audio and measures pitch; it never runs recognition. Recognition reads committed CAF data in windows of at most 30 seconds: 20-second cores with up to five seconds of context on either side. Aligned word midpoints assign ownership at boundaries, preserving genuine repeated lyrics. Full accepted word intervals survive across core boundaries; only the original audio's end clips them. Each completed core is atomically checkpointed. Stop finalizes the remaining tail while review opens independently.

Record and explicit Analyze/Resume actions allow one iOS continued-processing request, submitted only once the model is ready and an audio window can be decoded. Cold preparation and waiting for recording lookahead do not start a system Live Activity; keep the app open for model setup. Completed saved transcripts and automatic foreground recovery do not start new system tasks. Its concrete registration/submission identifier matches the plist's wildcard prefix, and committed audio progress is reported to the system. When granted, work can finish after backgrounding; the model is released before completing the background task. If time is unavailable or expires, the last committed cursor survives. Foreground return resumes work paused for unavailable background time; system cancellation or memory pressure offers explicit Resume. Unfinished work remains paused or failed, not falsely completed, and unavailable grants are not retried on every audio window. Force-quit stops execution, but unfinished compatible checkpoints are recovered on the next Practice visit. Background execution is not guaranteed by iOS.

Checkpoints validate their schema, fixed model identity, and source file. Growing recordings allow appended samples and the CAF header rewrite on close; finalized recordings also require unchanged size and modification time. Bounded source probes are used, not a whole-file cryptographic integrity guarantee. Invalid/stale transcripts can be analyzed again; original audio and pitch data are never replaced by recognition.

### Observed integration measurements

On the iPhone 15 Plus / iOS 26.5, the CPU/Neural Engine configuration with word alignment processed a 101.6-second saved take in **28.06 seconds** across six committed windows. One cold preparation after a development reinstall, with a new model-asset path, took **212.71 seconds**; an unloaded-model reload in the same running installation took **5.60 seconds**. These reinstall measurements do not establish ordinary launch time. Preparation can take several minutes; audio recording remains independent.

In that run, sampled app footprint peaked at **117.44 MB** and fell to **58.92 MB** after unloading, from a **38.83 MB** pre-load baseline. These are app-process footprint samples, not total model/Neural Engine/system memory. Thermal state remained nominal, and background GPU support reported false. Core ML cache retention depends on asset location/configuration, OS updates, and available storage; these observations are not startup guarantees.

A live microphone run committed its first 20 seconds while capture continued, then completed the saved 35-second take. A separate native background run completed a 101.6-second take after switching to Settings and unloaded before completing its continued-processing task. All 25 original audio/pitch/metadata files in the pre-install backup retained identical SHA-256 hashes after those integration checks.

The word-lane smoke used real recognition on a copied 101.6-second recording: 43 word intervals were durably saved and reopened. Native simulator checks exercised paused/playing word seeks at all four speeds, a word crossing the 30-second viewport boundary, an unlabeled gap, reopening saved word IDs, and the legacy **Add word timing** action retaining prior phrases. Geometry regressions cover three-second bars, clipped intervals, dense labels, zero-duration markers, and EOF. These checks establish synchronization and persistence, not lyric or singing-alignment accuracy.

Native simulator lifecycle checks observed no continued-processing request during model setup, initial recording lookahead, completed-checkpoint loading, or automatic foreground recovery. Once an audio window was ready, one request was attempted; the simulator rejected background scheduling, and foreground inference still checkpointed the full 101.6-second take without changing its CAF. Recovery preserved an existing saved word, and the setup guidance remained readable above the pinned Record control. These checks do not establish iPhone notification behavior.


## Transcription Lab (isolated experiment)

`Experiments/TranscriptionLab` remains a separate iOS/macOS 26 comparison app, with bundle ID `ai.dannyboy.pitchpractice.transcriptionlab`. It uses copies of saved takes in its own `Documents/Recordings`, local assets in `Documents/Models`, and checkpointed JSON results in `Documents/Reports`. **Listen and compare** plays original audio alongside raw model output. Its Whisper adapter reuses `LocalSpeech`; the production app exposes only Turbo and its fixed lifecycle.

The lab offers [WhisperKit 1.1.0](https://github.com/argmaxinc/argmax-oss-swift/tree/v1.1.0) with Whisper Base or the compressed 626 MB Turbo checkpoint, [Apple SpeechAnalyzer/SpeechTranscriber](https://developer.apple.com/videos/play/wwdc2025/277/), and FluidAudio 0.17.5 with [Parakeet Ultra](https://huggingface.co/FluidInference/parakeet-ultra-coreml). The downloader pins model revisions and checks downloaded file hashes. Whisper loads a local tokenizer with model downloads disabled; Parakeet uses local-only loading. Apple may download language assets during preparation, outside the transcription timer. No audio-upload path is implemented. Parakeet Ultra weights are CC-BY-4.0 (Moondream; Core ML conversion by FluidInference).

### Observed iPhone results

Before production integration, on an iPhone 15 Plus running iOS 26.5, both Turbo and Apple completed 11 saved takes totaling 480.4 seconds, plus a repeated first take. These historical lab measurements used phrase timestamps without word alignment and are not production-window benchmarks. First-pass processing totals exclude model setup and the repeat:

| Engine | Processing all 11 takes | Processing a 101.6-second take | Observed setup |
|---|---:|---:|---:|
| Whisper Turbo, compressed | 57.89 s | 18.18 s | 80.95 s |
| Apple Speech, English (US) | 4.96 s | 1.41 s | 0.39 s |

Turbo model assets occupy 626.7 MB, excluding tokenizer and system caches. Sampled peak app footprint was 117.9 MB; this is not total model/system memory. Both runs reported nominal thermal state throughout. Setup numbers are single observations, not a guarantee of subsequent startup time. No airplane-mode or network-capture test was performed. Base and Parakeet were not benchmarked.

The user judged Turbo's output good enough to locate recognizable sung words, though less accurate than their MacBook transcription. It is used for approximate lyric navigation, not lyric correctness or vocal grading. No word-error rate was calculated against a human reference. One 33.5-second take produced empty text on its first pass and recognizable lyrics on its repeat; empty output is not evidence of silence. The comparison lab keeps word alignment disabled; production uses aligned words to reconcile windows and display tappable phrases and word-duration spans.

### Run the lab

Open `Experiments/TranscriptionLab/TranscriptionLab.xcodeproj` for the separate iPhone app. Stage copied CAF recordings and model directories into its Documents folders with Xcode/devicectl; do not point it at or replace the production app's storage. Reports and model/audio directories are ignored by version control.

From `Experiments/TranscriptionLab`, prepare public model assets and run the macOS CLI:

```sh
python3 download_models.py Models
swift run -c release transcription-bench \
  --model whisper-turbo --models Models --recordings Recordings --reports Reports
```

Use `--file NAME.caf` to select one take. The runner repeats the first selected take last, reports preparation separately, and checkpoints after each file. Private recordings and raw transcripts must remain outside commits.


## Development

Open `PitchPractice.xcodeproj` in Xcode 26 or later, select the `PitchPractice` scheme and an iOS 26 iPhone/simulator. For a device build, select your own Apple Developer team and a unique bundle identifier under Signing & Capabilities; the included signing settings belong to the original development setup. Stage the fixed assets before building; the folder resource is copied verbatim so compiled Core ML bundles and tokenizer paths remain intact:

```sh
python3 Scripts/prepare_speech_models.py
# Optional: verify/reuse a previously downloaded lab asset cache without network:
python3 Scripts/prepare_speech_models.py --offline --reuse /path/to/model-cache
```

The staging script pins the revision and validates every asset's size and content hash (SHA-256 for LFS objects, Git blob SHA-1 for the remaining files). Generated `PitchPractice/SpeechModels`, package build products, private recordings, and raw transcripts are ignored by version control.

Simulator build:

```sh
xcodebuild -project PitchPractice.xcodeproj -scheme PitchPractice \
  -configuration Debug -sdk iphonesimulator \
  -derivedDataPath /tmp/pitch-practice-build CODE_SIGNING_ALLOWED=NO build
```

Model regressions run directly on macOS with Xcode's Swift compiler:

```sh
xcrun swiftc -O -parse-as-library \
  PitchPractice/PitchAnalysis.swift PitchPractice/RecordingStore.swift \
  PitchPractice/ReviewWindow.swift \
  Tests/PitchModelsTests.swift -o /tmp/pitch-practice-model-tests
/tmp/pitch-practice-model-tests
```

These cover range boundaries, harmonic-rich signals, noise/silence, timestamp gaps/endpoints, nearest-note tuning direction and tolerance, zoom anchors, absolute section seeks, partial final sections, visible-section pitch fitting (including overlapping frames and silence), legacy CAF analysis, durable naming, invalid-cache recovery, and unchanged original audio. Verify microphone capture and the playback/scrubbing UI on a simulator or device separately; model regressions do not establish real-world vocal accuracy. The playback DSP and clock can also be exercised on macOS: `RecordingPlaybackLimiter` exposes the production audio unit for offline rendering, and `RecordingPlayback` streams file segments without a microphone.

Transcript regressions use the shared package's real recognition types:

```sh
swift build --package-path LocalSpeech -c release
xcrun swiftc -O -parse-as-library -I LocalSpeech/.build/release/Modules \
  LocalSpeech/.build/release/LocalSpeech.build/*.o \
  LocalSpeech/.build/release/WhisperKit.build/*.o \
  LocalSpeech/.build/release/ArgmaxCore.build/*.o \
  PitchPractice/TranscriptStore.swift Tests/TranscriptModelsTests.swift \
  -o /tmp/pitch-transcript-model-tests
/tmp/pitch-transcript-model-tests
```

These cover lookahead and final tails, boundary ownership versus repeated lyrics, held-word intervals, stable word IDs, empty/invalid alignment, durable resume, interrupted legacy upgrades, corrupt word data, growing/replaced CAF sources, model/schema mismatch, and sidecar-only deletion. Word-lane geometry regressions use the same shared-package object files:

```sh
xcrun swiftc -O -parse-as-library -I LocalSpeech/.build/release/Modules \
  LocalSpeech/.build/release/LocalSpeech.build/*.o \
  LocalSpeech/.build/release/WhisperKit.build/*.o \
  LocalSpeech/.build/release/ArgmaxCore.build/*.o \
  PitchPractice/PitchAnalysis.swift PitchPractice/ReviewWindow.swift \
  PitchPractice/TranscriptStore.swift PitchPractice/WordTimeline.swift \
  Tests/WordTimelineTests.swift -o /tmp/pitch-word-timeline-tests
/tmp/pitch-word-timeline-tests
```

Native smoke checks remain necessary for actual recognition, live microphone concurrency, background grants, unloading, and phrase/word-to-playback navigation. Seek boundaries use the first audio frame at or after the requested time, so a paused word tap cannot land one sample before its highlight interval.

## 1.6

- Unify the original staves and pitch lane with Listen, Tune, and Practice controls; remove the mode tabs, duplicate stepper, and fixed-reference comparison.
- Keep the three home actions text-only and single-line; reserve stable status/tuning space and overlay startup progress so the pitch lane does not shift when tuning starts or pitch disappears.
- Use consistent E♭/B♭ spellings across live and saved pitch displays.
- Push full-screen review with timestamped Take titles, explicit Saved status, and Done returning to the ready main screen.
- Keep word spans above the trace and playback controls pinned below; move audio output, recognition details, rename, and delete into secondary surfaces.
- Expand dense word timelines to six visible rows instead of hiding all but the first; retain internal scrolling for denser views and thin pitch-axis labels when space is tight. Recognition and saved word timing are unchanged.
- Prepare recognition on foreground entry, retain the loaded model between foreground takes, prioritize newly finished takes, and preserve pending-work recovery and resource-pressure release.
- Preserve existing recordings, custom names, analysis, and transcripts. Older saved comparison targets no longer affect tuning.

## 1.5

- Integrate fixed, bundled Whisper Turbo with asynchronous Practice preparation and one bounded-window worker.
- Save recognized phrases, whole-word intervals, and resumable checkpoints beside the original recording; preserve existing audio, pitch, and metadata.
- Add tappable word-duration spans above the pitch graph, current-word highlighting, and pinned playback controls at every speed.
- Keep phrase-only transcripts readable while explicitly adding word timing, including across interrupted upgrades.
- Match newly saved takes by stable recording ID for the Stop & Review handoff.
- Reuse between takes, unload after idle/Practice exit, and pause safely for resource pressure.
- Support iOS 26 continued background processing with CPU/Neural Engine compute and durable foreground recovery.
- Defer system analysis tasks until the model and an audio window are ready, avoiding zero-progress tasks during setup and unnecessary tasks for completed transcripts.


## 1.4

- Add pitch-preserving quarter-, half-, three-quarter-, and normal-speed playback to saved-take review.
- Keep the playhead and fixed staff/tuning readout on the player's source-frame clock at every speed.
- Preserve position and playing/paused state when changing speed; retain the chosen speed through seeking and replay.
- Leave live Pitch mode, recording, original audio, and saved analysis unchanged.

## 1.3.1

- Pin the replay staff/tuning readout above the graph instead of moving it with the playhead and pitch.
- Keep its location stable across playback, scrubbing, note changes, silence, and zoom, without covering the pitch trace.

## 1.3

- Unify saved-take replay around a playhead-attached staff note and explicit tuning readout; remove the detached tuner and expandable staff panel.
- Fit the vertical range to the visible phrase, label neighboring notes, and keep the scale stable during playback and scrubbing.
- Offer tenor/bass replay notation, retain gaps and exact pitch traces, and keep reference comparisons explicit.
- Leave live Pitch, recording mode, audio playback, and original recordings unchanged.

## 1.2

- Make long takes readable in ten-second windows, with pinch/button zoom, section navigation, and synchronized local/global seeking.
- Add playback-only +12 dB boost with peak limiting, a system volume control, and an output route picker.
- Replace color-only tuning feedback with sharp/flat arrows and guidance; remove octave suffixes from note labels.
- Bring the existing aligned bass/tenor treble staves into Practice, keep recording controls fixed, and put Recordings in the toolbar.
- Preserve original CAFs and cached pitch data. No transcription, looping, retry workflow, or song grading added.

## 1.1.1

- Enlarge the treble clef and align its curl with the G line.
- Size and position the bass clef so its dots straddle the F line.
- No changes to pitch detection, practice recordings, or playback.

## 1.1

- Separate unsaved Pitch mode from saved Practice mode.
- Add synchronized pitch history, audio seeking, play/pause, and persistent take review.
- Preserve and analyze previous recordings; add take names and confirmed deletion.
- Expand supported detection to C2–C6 and show gaps for unvoiced/uncertain audio.
- Keep phase/section selection, looping, retry flows, song grading, and cloud services out of scope.
