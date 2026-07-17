import SwiftUI
import AVFoundation
import Combine

// MARK: - Recordings list model

@MainActor
final class RecordingsModel: ObservableObject {
    @Published private(set) var recordings: [HistoryEntry] = []
    @Published private(set) var isLoading = false
    @Published var loadError: String?

    private var nextPage = 1
    private var total = Int.max
    private var fetched = 0

    var hasMore: Bool { fetched < total }

    func reload(client: APIClient?) async {
        nextPage = 1
        total = Int.max
        fetched = 0
        recordings = []
        await loadMore(client: client)
    }

    /// Recordings are sparse in the history stream, so each batch scans up to
    /// five pages until it turns up new entries or runs out.
    func loadMore(client: APIClient?) async {
        guard let client = client, !isLoading, hasMore else { return }
        isLoading = true
        loadError = nil
        var pagesScanned = 0
        var foundThisBatch = 0
        do {
            while hasMore && pagesScanned < 5 && foundThisBatch < 10 {
                let page = try await client.history(page: nextPage)
                nextPage += 1
                pagesScanned += 1
                fetched += page.entries.count
                total = page.entries.isEmpty ? fetched : page.total
                let known = Set(recordings.map(\.id))
                let found = page.entries.filter { $0.kind == "recording" && !known.contains($0.id) }
                foundThisBatch += found.count
                recordings.append(contentsOf: found)
            }
        } catch {
            if !Task.isCancelled { loadError = error.localizedDescription }
        }
        isLoading = false
    }
}

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

// MARK: - Recorder tab

struct RecorderView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = RecordingsModel()
    @State private var selectedEntry: HistoryEntry?

    var body: some View {
        NavigationStack {
            Group {
                if model.recordings.isEmpty {
                    ScrollView {
                        stateView
                            .frame(maxWidth: .infinity)
                            .padding(.top, 100)
                            .padding(.horizontal, 32)
                    }
                    .refreshable { await model.reload(client: appState.client) }
                } else {
                    recordingList
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Recorder")
            .sheet(item: $selectedEntry) { entry in
                RecordingDetailView(entry: entry)
            }
            .task {
                if model.recordings.isEmpty {
                    await model.reload(client: appState.client)
                }
            }
        }
    }

    @ViewBuilder
    private var stateView: some View {
        if model.isLoading {
            LoadingStateView(label: "Loading recordings…")
        } else if let error = model.loadError {
            EmptyStateView(
                icon: "wifi.exclamationmark",
                tint: DS.Palette.attention,
                title: "Couldn't load recordings",
                message: error,
                actionTitle: "Try Again"
            ) {
                Task { await model.reload(client: appState.client) }
            }
        } else if model.hasMore {
            EmptyStateView(
                icon: "waveform.badge.magnifyingglass",
                tint: DS.Palette.record,
                title: "No recordings yet",
                message: "None in recent activity — there may be older ones.",
                actionTitle: "Scan Older History"
            ) {
                Task { await model.loadMore(client: appState.client) }
            }
        } else {
            EmptyStateView(
                icon: "waveform",
                tint: DS.Palette.record,
                title: "No recordings yet",
                message: "Triple-press the button on the glasses to record a lecture or conversation. The transcript and an AI summary land here."
            )
        }
    }

    private var recordingList: some View {
        List {
            ForEach(model.recordings) { entry in
                Button {
                    selectedEntry = entry
                } label: {
                    RecordingRow(entry: entry)
                }
                .onAppear {
                    if entry.id == model.recordings.last?.id {
                        Task { await model.loadMore(client: appState.client) }
                    }
                }
            }
            if model.hasMore {
                Button {
                    Task { await model.loadMore(client: appState.client) }
                } label: {
                    HStack {
                        Spacer()
                        if model.isLoading {
                            ProgressView()
                        } else {
                            Text("Scan Older History")
                                .font(.subheadline)
                        }
                        Spacer()
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await model.reload(client: appState.client) }
    }
}

private struct RecordingRow: View {
    let entry: HistoryEntry

    private var title: String {
        let line = entry.text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        return line.isEmpty ? "Recording" : line
    }

    var body: some View {
        HStack(spacing: DS.Space.m) {
            IconTile(icon: "waveform", tint: DS.Palette.record)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                if let summary = entry.extra?["summary"] {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(TimestampFormat.relative(entry.ts))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Image(systemName: entry.hasAudio ? "play.circle" : "chevron.forward")
                .font(.title3)
                .foregroundStyle(entry.hasAudio ? DS.Palette.record : Color(.tertiaryLabel))
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording, \(TimestampFormat.relative(entry.ts)). \(title)")
        .accessibilityHint("Opens the transcript, summary, and playback.")
    }
}

// MARK: - Recording detail

private struct RecordingDetailView: View {
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
                VStack(alignment: .leading, spacing: 20) {
                    playbackCard
                    if let summary = entry.extra?["summary"] {
                        block("Summary", summary, icon: "sparkles")
                    }
                    block("Transcript", entry.text, icon: "text.alignleft")
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
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
        VStack(spacing: 14) {
            if !entry.hasAudio {
                Label("Audio isn't available for this recording", systemImage: "speaker.slash")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if player.failed {
                VStack(spacing: 10) {
                    Label("Couldn't load the audio from the glasses", systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
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
                        .foregroundStyle(DS.Palette.record)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.pressable)
                .disabled(!player.isReady)
                .opacity(player.isReady ? 1 : 0.4)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play recording")

                VStack(spacing: 4) {
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
                    HStack(spacing: 8) {
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

    private func block(_ title: String, _ text: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
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
