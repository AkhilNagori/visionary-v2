import SwiftUI

/// Home: the glasses are the hero. One device card (connection, current mode),
/// the three primary actions, small entry points into the live surfaces, and a
/// compact recent-activity strip. Everything else is a sheet away.
struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dynamicTypeSize) private var typeSize

    private enum LiveSurface: String, Identifiable {
        case live, captions, guide
        var id: String { rawValue }
    }

    @State private var inFlightMode: String?
    @State private var actionError: String?
    @State private var showInbox = false
    @State private var showModePicker = false
    @State private var liveSurface: LiveSurface?
    @State private var selectedEntry: HistoryEntry?
    @State private var recentEntries: [HistoryEntry] = []

    private static let uptimeFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f
    }()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Space.xl) {
                    deviceCard
                    if appState.inboxCount > 0 {
                        inboxBanner
                    }
                    primaryActions
                    liveSection
                    recentSection
                }
                .padding(.horizontal, DS.Space.l)
                .padding(.vertical, DS.Space.s)
            }
            .background(DS.Palette.canvas)
            .navigationTitle("Visionary")
            .toolbar {
                ToolbarItem(placement: .primaryAction) { inboxButton }
            }
            .refreshable {
                await appState.refresh()
                await appState.refreshModes()
                await loadRecentActivity()
            }
            // Re-pull /modes on every visit: a mode activated by voice on the
            // glasses shows on the card without waiting for the slow poll.
            .onAppear {
                Task {
                    await appState.refreshModes()
                    await loadRecentActivity()
                }
            }
            .alert("Couldn't complete that", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actionError ?? "")
            }
            .sheet(isPresented: $showInbox) { ActionsInboxView() }
            .sheet(isPresented: $showModePicker) { ModePickerView() }
            .sheet(item: $selectedEntry) { entry in
                if entry.kind == "recording" {
                    RecordingDetailView(entry: entry)
                } else {
                    EntryDetailView(entry: entry)
                }
            }
            .fullScreenCover(item: $liveSurface) { surface in
                switch surface {
                case .live: LiveView()
                case .captions: CaptionsView()
                case .guide: GuideView()
                }
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
    }

    private func loadRecentActivity() async {
        guard let client = appState.client else { return }
        if let page = try? await client.history(page: 1, perPage: 3) {
            recentEntries = page.entries
        }
    }

    // MARK: - Device hero card

    @ViewBuilder
    private var deviceCard: some View {
        if let status = appState.status {
            VStack(spacing: DS.Space.l) {
                HStack(spacing: DS.Space.l) {
                    ZStack(alignment: .topTrailing) {
                        IconTile(icon: "eyeglasses", size: 64)
                        StatusDot(color: status.online ? DS.Palette.online : DS.Palette.attention,
                                  breathing: status.online)
                            .id(status.online)
                            .offset(x: 5, y: -5)
                    }
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text("Visionary Glasses")
                            .font(DS.Text.title)
                        Text(status.online ? "Online" : "Offline — reading still works")
                            .font(DS.Text.subhead)
                            .foregroundStyle(status.online ? DS.Palette.online : DS.Palette.attention)
                    }
                    Spacer()
                }
                .accessibilityElement(children: .combine)

                if status.recording || status.busy {
                    HStack {
                        if status.recording {
                            DSBadge(text: "Recording", tint: DS.Palette.danger,
                                    icon: "record.circle", filled: true)
                        } else {
                            DSBadge(text: "Working", tint: DS.Palette.attention, icon: "hourglass")
                        }
                        Spacer()
                    }
                    .accessibilityElement(children: .combine)
                }

                VStack(spacing: DS.Space.s) {
                    LabeledContent("Wi-Fi") {
                        Text(status.wifi ?? "Not connected")
                    }
                    LabeledContent("Battery") {
                        Text("—").accessibilityLabel("Not reported on this hardware")
                    }
                    LabeledContent("Version") {
                        Text(status.version).monospacedDigit()
                    }
                    LabeledContent("Uptime") {
                        Text(Self.uptimeFormatter.string(from: max(status.uptime, 60)) ?? "—")
                            .monospacedDigit()
                    }
                }
                .font(DS.Text.subhead)

                Divider()

                modeChip
            }
            .cardStyle()
            .animation(DS.Motion.spring, value: status.recording)
            .animation(DS.Motion.spring, value: status.busy)
        } else if let error = appState.lastError {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(spacing: DS.Space.m) {
                    IconTile(icon: "wifi.exclamationmark", tint: DS.Palette.attention, size: 44)
                    Text("Can't reach the glasses")
                        .font(DS.Text.cardTitle)
                }
                Text(error)
                    .font(DS.Text.subhead)
                    .foregroundStyle(.secondary)
                Text("Make sure the glasses are powered on and on the same network, then pull down to retry.")
                    .font(DS.Text.caption)
                    .foregroundStyle(.tertiary)
            }
            .cardStyle()
            .accessibilityElement(children: .combine)
        } else {
            HStack(spacing: DS.Space.l) {
                IconTile(icon: "eyeglasses", size: 64)
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Visionary Glasses")
                        .font(DS.Text.title)
                    Text("Connecting…")
                        .font(DS.Text.subhead)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ProgressView()
            }
            .cardStyle()
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Connecting to the glasses")
        }
    }

    /// The current-mode row inside the device card; tapping it opens the
    /// mode picker sheet.
    private var modeChip: some View {
        Button {
            Haptics.tap()
            showModePicker = true
        } label: {
            HStack(spacing: DS.Space.m) {
                Image(systemName: appState.activeMode == nil ? "text.viewfinder" : "wand.and.stars")
                    .font(.body.weight(.medium))
                    .foregroundStyle(DS.Palette.accent)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Mode")
                        .font(DS.Text.caption)
                        .foregroundStyle(.secondary)
                    Text(appState.modeDisplayName(appState.activeMode))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                }
                Spacer()
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mode: \(appState.modeDisplayName(appState.activeMode))")
        .accessibilityHint("Opens the mode picker. A single press on the glasses runs the active mode.")
    }

    // MARK: - Inbox

    private var inboxButton: some View {
        Button {
            Haptics.tap()
            showInbox = true
        } label: {
            Image(systemName: appState.inboxCount > 0 ? "tray.full" : "tray")
                .overlay(alignment: .topTrailing) {
                    if appState.inboxCount > 0 {
                        Text("\(min(appState.inboxCount, 99))")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, DS.Space.xs)
                            .padding(.vertical, 1)
                            .background(DS.Palette.danger, in: Capsule())
                            .offset(x: 10, y: -8)
                            .accessibilityHidden(true)
                    }
                }
        }
        .accessibilityLabel(appState.inboxCount > 0
            ? "Actions inbox, \(appState.inboxCount) waiting"
            : "Actions inbox")
        .accessibilityHint("Texts, emails, and notes the glasses queued for you.")
    }

    private var inboxBanner: some View {
        Button {
            Haptics.tap()
            showInbox = true
        } label: {
            HStack(spacing: DS.Space.m) {
                IconTile(icon: "tray.full", size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.inboxCount == 1
                         ? "1 action waiting"
                         : "\(appState.inboxCount) actions waiting")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Text("Texts, emails, and notes need your OK before they go out.")
                        .font(DS.Text.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .cardStyle()
        }
        .buttonStyle(.pressable)
        .accessibilityHint("Opens the actions inbox.")
    }

    // MARK: - Primary actions

    private var isRecording: Bool { appState.status?.recording == true }

    private var primaryActions: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: DS.Space.m))
            : AnyLayout(HStackLayout(spacing: DS.Space.m))
        return VStack(spacing: DS.Space.m) {
            layout {
                BigActionButton(
                    title: "Read",
                    subtitle: "Speak the text in view",
                    icon: "text.viewfinder",
                    inFlight: inFlightMode == "read",
                    disabled: inFlightMode != nil || appState.client == nil
                ) { trigger("read") }
                    .accessibilityHint("Takes a photo and the glasses read its text out loud.")
                BigActionButton(
                    title: "Describe",
                    subtitle: "Describe the scene",
                    icon: "eye",
                    inFlight: inFlightMode == "describe",
                    disabled: inFlightMode != nil || appState.client == nil
                ) { trigger("describe") }
                    .accessibilityHint("Takes a photo and the glasses describe what they see.")
            }
            voiceNoteButton
        }
    }

    private var voiceNoteButton: some View {
        Button {
            trigger("recorder")
        } label: {
            HStack(spacing: DS.Space.s) {
                ZStack {
                    Image(systemName: isRecording ? "stop.circle.fill" : "waveform")
                        .font(.body.weight(.medium))
                        .opacity(inFlightMode == "recorder" ? 0 : 1)
                    if inFlightMode == "recorder" {
                        ProgressView().controlSize(.small)
                    }
                }
                Text(isRecording ? "Stop Recording" : "Voice Note")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(isRecording ? DS.Palette.danger : DS.Palette.accent)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(
                DS.Palette.card,
                in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            )
        }
        .buttonStyle(.pressable)
        .disabled(inFlightMode != nil || appState.client == nil)
        .opacity(inFlightMode != nil && inFlightMode != "recorder" ? 0.5 : 1)
        .accessibilityLabel(inFlightMode == "recorder"
            ? "Voice note, in progress"
            : (isRecording ? "Stop recording" : "Voice note"))
        .accessibilityHint(isRecording
            ? "Stops the voice recording."
            : "Starts a voice recording on the glasses; the transcript and summary land in Activity.")
    }

    private func trigger(_ mode: String) {
        guard inFlightMode == nil, let client = appState.client else { return }
        Haptics.tap()
        withAnimation(DS.Motion.snappy) { inFlightMode = mode }
        Task { @MainActor in
            do {
                try await client.capture(mode: mode)
                Haptics.success()
                // pick up busy/recording chips right away instead of next poll
                await appState.refresh()
            } catch {
                Haptics.error()
                actionError = error.localizedDescription
            }
            // brief linger so a fast round trip still visibly registers
            try? await Task.sleep(nanoseconds: 400_000_000)
            withAnimation(DS.Motion.snappy) { inFlightMode = nil }
        }
    }

    // MARK: - Live surfaces

    private var liveSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader("Live")
            VStack(spacing: 0) {
                liveRow(surface: .live, icon: "video",
                        title: "Live View", subtitle: "See what the glasses see")
                    .accessibilityHint("Opens the live camera preview.")
                Divider().padding(.leading, 52)
                liveRow(surface: .captions, icon: "captions.bubble",
                        title: "Captions", subtitle: "Read the speech around you")
                    .accessibilityHint("Opens live captions.")
                Divider().padding(.leading, 52)
                liveRow(surface: .guide, icon: "person.wave.2",
                        title: "Guide", subtitle: "See for them, speak in their ear")
                    .accessibilityHint("Opens sighted-guide mode.")
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.xs)
            .background(
                DS.Palette.card,
                in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            )
        }
    }

    private func liveRow(surface: LiveSurface, icon: String,
                         title: String, subtitle: String) -> some View {
        Button {
            Haptics.tap()
            liveSurface = surface
        } label: {
            HStack(spacing: DS.Space.m) {
                Image(systemName: icon)
                    .font(.body.weight(.medium))
                    .foregroundStyle(DS.Palette.accent)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(DS.Text.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(appState.client == nil)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Recent activity

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack {
                SectionHeader("Recent")
                Button("See All") {
                    Haptics.tap()
                    appState.selectedTab = .activity
                }
                .font(.caption.weight(.semibold))
                .accessibilityHint("Opens the Activity tab.")
            }
            if recentEntries.isEmpty {
                HStack(spacing: DS.Space.m) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text("No activity yet — try Read or Describe.")
                        .font(DS.Text.subhead)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .cardStyle()
                .accessibilityElement(children: .combine)
            } else {
                VStack(spacing: 0) {
                    ForEach(recentEntries) { entry in
                        recentRow(entry)
                        if entry.id != recentEntries.last?.id {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
                .padding(.horizontal, DS.Space.l)
                .padding(.vertical, DS.Space.xs)
                .background(
                    DS.Palette.card,
                    in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                )
            }
        }
    }

    private func recentRow(_ entry: HistoryEntry) -> some View {
        Button {
            Haptics.tap()
            selectedEntry = entry
        } label: {
            HStack(spacing: DS.Space.m) {
                Image(systemName: EntryKindStyle.icon(for: entry.kind))
                    .font(.body.weight(.medium))
                    .foregroundStyle(DS.Palette.accent)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.text.split(separator: "\n", omittingEmptySubsequences: true)
                            .first.map(String.init) ?? EntryKindStyle.label(for: entry.kind))
                        .font(DS.Text.subhead)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text("\(EntryKindStyle.label(for: entry.kind)) · \(TimestampFormat.relative(entry.ts))")
                        .font(DS.Text.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(EntryKindStyle.label(for: entry.kind)), \(TimestampFormat.relative(entry.ts))")
        .accessibilityHint("Shows the full entry.")
    }
}

// MARK: - Primary action button

private struct BigActionButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let inFlight: Bool
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: DS.Space.s) {
                ZStack {
                    Image(systemName: icon)
                        .font(.system(size: 28, weight: .semibold))
                        .opacity(inFlight ? 0 : 1)
                    if inFlight {
                        ProgressView()
                            .tint(.white)
                    }
                }
                .frame(height: 34)
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(DS.Text.caption)
                    .opacity(0.8)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 128)
            .background(
                DS.Palette.accent,
                in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            )
        }
        .buttonStyle(.pressable)
        .disabled(disabled)
        .opacity(disabled && !inFlight ? 0.5 : 1)
        .accessibilityLabel(inFlight ? "\(title), in progress" : title)
    }
}
