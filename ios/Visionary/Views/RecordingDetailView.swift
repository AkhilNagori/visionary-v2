import SwiftUI
import AVFoundation
import Combine

// MARK: - Audio playback

/// Not actor-isolated: every callback is delivered on the main queue and all
/// mutation happens there, which keeps @Published updates UI-safe.
final class RecordingPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var isReady = false
    @Published private(set) var failed = false
    @Published var progress: Double = 0
    @Published private(set) var duration: Double = 0

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var statusCancellable: AnyCancellable?
    private var endObserver: NSObjectProtocol?

    func load(request: URLRequest) {
        teardown()
        guard let url = request.url else {
            failed = true
            return
        }
        // The Bearer header must ride along with AVFoundation's own requests;
        // the string key is the documented spelling of the private constant.
        let headers = request.allHTTPHeaderFields ?? [:]
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        self.player = player

        statusCancellable = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self = self else { return }
                switch status {
                case .readyToPlay:
                    self.isReady = true
                    let d = item.duration.seconds
                    if d.isFinite && d > 0 { self.duration = d }
                case .failed:
                    self.failed = true
                    self.isPlaying = false
                default:
                    break
                }
            }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self = self else { return }
            self.progress = time.seconds
            if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 {
                self.duration = d
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.isPlaying = false
            self?.player?.seek(to: .zero)
            self?.progress = 0
        }
    }

    func toggle() {
        guard let player = player, !failed else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
        progress = seconds
    }

    func teardown() {
        if let timeObserver = timeObserver, let player = player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let endObserver = endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        statusCancellable = nil
        player?.pause()
        player = nil
        isPlaying = false
        isReady = false
        failed = false
        progress = 0
        duration = 0
    }
}

// MARK: - Recording detail

/// Transcript, summary, and playback for a `recording` history entry. Opened
/// from the Activity timeline and Home's recent strip.
struct RecordingDetailView: View {
    let entry: HistoryEntry

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = RecordingPlayer()

    @State private var isScrubbing = false
    @State private var scrubPosition: Double = 0

    private var shareText: String {
        var parts = ["Transcript:\n\(entry.text)"]
        if let summary = entry.extra?["summary"] {
            parts.append("Summary:\n\(summary)")
        }
        return parts.joined(separator: "\n\n")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    playbackCard
                    if let summary = entry.extra?["summary"] {
                        block("Summary", summary)
                    }
                    block("Transcript", entry.text)
                }
                .padding()
            }
            .background(DS.Palette.canvas)
            .navigationTitle(TimestampFormat.absolute(entry.ts))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: shareText)
                        .accessibilityLabel("Share transcript and summary")
                }
            }
            .onAppear {
                if entry.hasAudio, let client = appState.client {
                    player.load(request: client.audioRequest(id: entry.id))
                }
            }
            .onDisappear { player.teardown() }
        }
    }

    @ViewBuilder
    private var playbackCard: some View {
        VStack(spacing: DS.Space.m) {
            if !entry.hasAudio {
                Label("Audio isn't available for this recording", systemImage: "speaker.slash")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if player.failed {
                VStack(spacing: DS.Space.s) {
                    Label("Couldn't load the audio from the glasses",
                          systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(DS.Palette.attention)
                    Button("Try Again") {
                        if let client = appState.client {
                            player.load(request: client.audioRequest(id: entry.id))
                        }
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Button {
                    Haptics.tap()
                    player.toggle()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(DS.Palette.accent)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.pressable)
                .disabled(!player.isReady)
                .opacity(player.isReady ? 1 : 0.4)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play recording")

                VStack(spacing: DS.Space.xs) {
                    Slider(
                        value: Binding(
                            get: { isScrubbing ? scrubPosition : min(player.progress, max(player.duration, 0.01)) },
                            set: { scrubPosition = $0 }
                        ),
                        in: 0...max(player.duration, 0.01)
                    ) { editing in
                        if editing {
                            isScrubbing = true
                            scrubPosition = player.progress
                        } else {
                            player.seek(to: scrubPosition)
                            isScrubbing = false
                        }
                    }
                    .disabled(!player.isReady)
                    .accessibilityLabel("Playback position")
                    HStack {
                        Text(timeString(isScrubbing ? scrubPosition : player.progress))
                        Spacer()
                        Text(timeString(player.duration))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }

                if !player.isReady {
                    HStack(spacing: DS.Space.s) {
                        ProgressView()
                        Text("Loading audio…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    private func block(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeader(title)
            Text(text)
                .font(.body)
                .textSelection(.enabled)
        }
        .cardStyle()
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let t = Int(seconds.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}
