import SwiftUI
import UIKit

/// Live captions for deaf and hard-of-hearing wearers: a full-bleed,
/// high-contrast transcript of the speech around the glasses, streamed over
/// the /events SSE connection. The black-on-white-text stage is deliberate in
/// both light and dark mode — captions are read at a glance, across a table,
/// so contrast beats theme-matching here.
struct CaptionsView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var source = EventSource()

    @State private var autoScroll = true
    @State private var clearedThroughSeq = 0
    @State private var lastScannedSeq = 0
    @State private var helpEvent: DeviceEvent?

    @ScaledMetric(relativeTo: .largeTitle) private var latestSize: CGFloat = 40
    @ScaledMetric(relativeTo: .title2) private var earlierSize: CGFloat = 26

    /// Event kinds that should raise the urgent banner. The firmware publishes
    /// the caption stream as kind "caption"; anything alert-shaped lands here.
    private static let helpKinds: Set<String> = ["help", "help_phrase", "sos", "alert"]
    private static let nameKinds: Set<String> = ["name", "listen_name"]

    private var captions: [DeviceEvent] {
        source.events.filter { $0.kind == "caption" && $0.seq > clearedThroughSeq && !$0.text.isEmpty }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if appState.client == nil {
                    unpairedState
                } else {
                    stage
                }
            }
            .navigationTitle("Captions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Toggle(isOn: $autoScroll) {
                            Label("Follow Latest", systemImage: "arrow.down.to.line")
                        }
                        Button {
                            clearedThroughSeq = source.events.last?.seq ?? clearedThroughSeq
                        } label: {
                            Label("Clear Transcript", systemImage: "trash")
                        }
                        .disabled(captions.isEmpty)
                    } label: {
                        Label("Caption Options", systemImage: "ellipsis.circle")
                    }
                    .disabled(appState.client == nil)
                }
            }
            .onAppear(perform: startStream)
            .onDisappear { source.stop() }
            .onReceive(source.$events) { events in scanForAlerts(events) }
        }
    }

    private func startStream() {
        guard let client = appState.client else { return }
        source.start(request: client.eventsRequest())
    }

    // MARK: - Stage

    private var stage: some View {
        VStack(spacing: 0) {
            statusBar
            if let help = helpEvent {
                helpBanner(help)
            }
            if captions.isEmpty {
                emptyState
            } else {
                transcript
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            Text(statusText)
                .font(.footnote.weight(.medium))
                .foregroundColor(Color(white: 0.75))
            Spacer()
            if !autoScroll {
                Label("Paused", systemImage: "pause.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.yellow)
                    .accessibilityLabel("Auto-scroll paused")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Caption stream \(statusText)")

    }

    private var statusColor: Color {
        switch source.state {
        case .open: return .green
        case .connecting: return .yellow
        case .waitingToRetry: return .orange
        case .idle: return .gray
        }
    }

    private var statusText: String {
        switch source.state {
        case .open: return "Live"
        case .connecting: return "Connecting…"
        case .waitingToRetry: return "Reconnecting…"
        case .idle: return "Not connected"
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(captions) { caption in
                        Text(caption.text)
                            .font(.system(size: caption.id == captions.last?.id ? latestSize : earlierSize,
                                          weight: caption.id == captions.last?.id ? .bold : .semibold,
                                          design: .rounded))
                            .foregroundColor(caption.id == captions.last?.id ? .white : Color(white: 0.68))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .id(caption.id)
                    }
                    Color.clear
                        .frame(height: 12)
                        .id("captions-bottom")
                }
                .padding(20)
            }
            .onChange(of: captions.last?.id) { _ in
                guard autoScroll else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo("captions-bottom", anchor: .bottom)
                }
            }
            .onChange(of: autoScroll) { follow in
                guard follow else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo("captions-bottom", anchor: .bottom)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live transcript of speech around the glasses")
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: - Alerts

    private func scanForAlerts(_ events: [DeviceEvent]) {
        for event in events where event.seq > lastScannedSeq {
            if Self.helpKinds.contains(event.kind) || Self.nameKinds.contains(event.kind) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    helpEvent = event
                }
                Haptics.error()
                UIAccessibility.post(notification: .announcement,
                                     argument: "\(alertTitle(for: event)). \(event.text)")
            }
        }
        lastScannedSeq = events.last?.seq ?? lastScannedSeq
    }

    private func alertTitle(for event: DeviceEvent) -> String {
        Self.nameKinds.contains(event.kind) ? "Your name was mentioned" : "Help phrase detected"
    }

    private func helpBanner(_ event: DeviceEvent) -> some View {
        let isName = Self.nameKinds.contains(event.kind)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: isName ? "person.wave.2.fill" : "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundColor(.white)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(alertTitle(for: event))
                    .font(.headline)
                    .foregroundColor(.white)
                if !event.text.isEmpty {
                    Text(event.text)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.9))
                }
                Text(TimestampFormat.relative(event.ts))
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
            }
            Spacer()
            Button {
                withAnimation { helpEvent = nil }
            } label: {
                Text("Dismiss")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityHint("Hides this alert. The transcript keeps running.")
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isName ? Color.blue.gradient : Color.red.gradient)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Empty / unpaired

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            if source.state == .open {
                Image(systemName: "waveform")
                    .font(.system(size: 44))
                    .foregroundColor(Color(white: 0.5))
                Text("Listening for speech")
                    .font(.title3.bold())
                    .foregroundColor(.white)
                Text("Captions appear here in near-real-time while the Live Captions mode runs on the glasses. Turn it on from the Modes tab.")
                    .font(.subheadline)
                    .foregroundColor(Color(white: 0.65))
                    .multilineTextAlignment(.center)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text(statusText)
                    .font(.title3.bold())
                    .foregroundColor(.white)
                Text("Waiting for the glasses' event stream. It reconnects on its own if the connection drops.")
                    .font(.subheadline)
                    .foregroundColor(Color(white: 0.65))
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var unpairedState: some View {
        VStack(spacing: 12) {
            Image(systemName: "captions.bubble")
                .font(.system(size: 40))
                .foregroundColor(Color(white: 0.5))
            Text("No glasses connected")
                .font(.title3.bold())
                .foregroundColor(.white)
            Text("Pair with your Visionary glasses to see live captions of the speech around them.")
                .font(.subheadline)
                .foregroundColor(Color(white: 0.65))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
    }
}
