import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var inFlightMode: String?
    @State private var actionError: String?
    @State private var showInbox = false
    @State private var lastEntry: HistoryEntry?

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
                VStack(spacing: DS.Space.l) {
                    statusCard
                    if appState.inboxCount > 0 {
                        inboxBanner
                    }
                    currentModeCard
                    actionButtons
                    quickActions
                }
                .padding()
            }
            .background(DS.Palette.canvas)
            .navigationTitle("Visionary")
            .toolbar {
                ToolbarItem(placement: .primaryAction) { inboxButton }
            }
            .refreshable {
                await appState.refresh()
                await appState.refreshModes()
                await loadLastActivity()
            }
            // Re-pull /modes on every visit: a mode activated in the Modes tab
            // (or by voice on the glasses) shows on the card without waiting
            // for the slow poll.
            .onAppear {
                Task {
                    await appState.refreshModes()
                    await loadLastActivity()
                }
            }
            .alert("Couldn't complete that", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actionError ?? "")
            }
            .sheet(isPresented: $showInbox) {
                ActionsInboxView()
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
    }

    private func loadLastActivity() async {
        guard let client = appState.client else { return }
        if let page = try? await client.history(page: 1, perPage: 1) {
            lastEntry = page.entries.first
        }
    }

    // MARK: - Hero status card

    @ViewBuilder
    private var statusCard: some View {
        if let status = appState.status {
            VStack(spacing: DS.Space.l) {
                HStack(spacing: DS.Space.l) {
                    ZStack(alignment: .topTrailing) {
                        IconTile(icon: "eyeglasses", tint: .accentColor, size: 64)
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
                    HStack(spacing: DS.Space.s) {
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

                lastActivityRow

                Divider()

                VStack(spacing: DS.Space.s) {
                    LabeledContent("Wi-Fi") {
                        Text(status.wifi ?? "Not connected")
                    }
                    LabeledContent("Battery") {
                        Text("—").accessibilityLabel("Not reported on this hardware")
                    }
                    LabeledContent("Version") {
                        Text(status.version)
                    }
                    LabeledContent("Uptime") {
                        Text(Self.uptimeFormatter.string(from: max(status.uptime, 60)) ?? "—")
                    }
                }
                .font(DS.Text.subhead)
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
                IconTile(icon: "eyeglasses", tint: .accentColor, size: 64)
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

    @ViewBuilder
    private var lastActivityRow: some View {
        HStack(spacing: DS.Space.m) {
            if let entry = lastEntry {
                IconTile(icon: EntryKindStyle.icon(for: entry.kind),
                         tint: EntryKindStyle.color(for: entry.kind), size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(EntryKindStyle.label(for: entry.kind)) · \(TimestampFormat.relative(entry.ts))")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(entry.text.split(separator: "\n", omittingEmptySubsequences: true)
                            .first.map(String.init) ?? "")
                        .font(DS.Text.subhead)
                        .lineLimit(1)
                }
            } else {
                IconTile(icon: "sparkles", tint: .accentColor, size: 32)
                Text("No activity yet — try Read or Describe below.")
                    .font(DS.Text.subhead)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(lastEntry.map {
            "Last activity: \(EntryKindStyle.label(for: $0.kind)), \(TimestampFormat.relative($0.ts))"
        } ?? "No activity yet")
    }

    // MARK: - Actions inbox (badge + banner)

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
                IconTile(icon: "tray.full.fill", tint: DS.Palette.danger, size: 44)
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

    // MARK: - Current mode

    private var currentModeCard: some View {
        Button {
            Haptics.tap()
            appState.selectedTab = .modes
        } label: {
            HStack(spacing: DS.Space.m) {
                IconTile(icon: appState.activeMode == nil ? "text.viewfinder" : "wand.and.stars",
                         tint: DS.Palette.modes, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Current mode")
                        .font(DS.Text.caption)
                        .foregroundStyle(.secondary)
                    Text(appState.modeDisplayName(appState.activeMode))
                        .font(DS.Text.cardTitle)
                        .foregroundColor(.primary)
                    Text(appState.activeMode == nil
                         ? "Single press reads whatever is in view"
                         : "Single press on the glasses runs this mode")
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Current mode: \(appState.modeDisplayName(appState.activeMode))")
        .accessibilityHint("Opens the mode gallery to switch modes.")
    }

    // MARK: - Read / Describe

    private var actionButtons: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: DS.Space.m))
            : AnyLayout(HStackLayout(spacing: DS.Space.m))
        return layout {
            BigActionButton(
                title: "Read",
                subtitle: "Speak the text in view",
                icon: "text.viewfinder",
                tint: DS.Palette.read,
                inFlight: inFlightMode == "read",
                disabled: inFlightMode != nil || appState.client == nil
            ) { trigger("read") }
                .accessibilityHint("Takes a photo and the glasses read its text out loud.")
            BigActionButton(
                title: "Describe",
                subtitle: "Describe the scene",
                icon: "eye",
                tint: DS.Palette.describe,
                inFlight: inFlightMode == "describe",
                disabled: inFlightMode != nil || appState.client == nil
            ) { trigger("describe") }
                .accessibilityHint("Takes a photo and the glasses describe what they see.")
        }
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

    // MARK: - Quick actions

    private var isRecording: Bool { appState.status?.recording == true }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text("Quick actions")
                .font(DS.Text.cardTitle)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: DS.Space.m)],
                      spacing: DS.Space.m) {
                QuickActionTile(
                    title: isRecording ? "Stop Recording" : "Voice Note",
                    subtitle: isRecording ? "The glasses are recording" : "Record and summarize",
                    icon: isRecording ? "stop.circle.fill" : "waveform",
                    tint: DS.Palette.record,
                    inFlight: inFlightMode == "recorder",
                    disabled: inFlightMode != nil || appState.client == nil
                ) { trigger("recorder") }
                    .accessibilityHint(isRecording
                        ? "Stops the voice recording."
                        : "Starts a voice recording on the glasses.")
                QuickActionTile(
                    title: "Live Captions",
                    subtitle: "Read speech around you",
                    icon: "captions.bubble",
                    tint: DS.Palette.captions
                ) { open(.live, live: .captions) }
                    .accessibilityHint("Opens live captions.")
                QuickActionTile(
                    title: "Guide",
                    subtitle: "See and talk them through",
                    icon: "person.wave.2",
                    tint: DS.Palette.guide
                ) { open(.live, live: .guide) }
                    .accessibilityHint("Opens sighted-guide mode.")
                QuickActionTile(
                    title: "Search Memory",
                    subtitle: "Find anything seen",
                    icon: "sparkle.magnifyingglass",
                    tint: DS.Palette.memory
                ) { open(.library, library: .search) }
                    .accessibilityHint("Opens visual memory search.")
                QuickActionTile(
                    title: "Flashcards",
                    subtitle: "Review today's deck",
                    icon: "rectangle.on.rectangle.angled",
                    tint: DS.Palette.flashcards
                ) { open(.library, library: .flashcards) }
                    .accessibilityHint("Opens flashcard review.")
                QuickActionTile(
                    title: "Notes",
                    subtitle: "Captured by voice",
                    icon: "note.text",
                    tint: DS.Palette.notes
                ) { open(.library, library: .notes) }
                    .accessibilityHint("Opens notes from the glasses.")
            }
        }
    }

    private func open(_ tab: AppTab, library: LibrarySegment? = nil, live: LiveSegment? = nil) {
        Haptics.tap()
        if let library = library { appState.librarySegment = library }
        if let live = live { appState.liveSegment = live }
        appState.selectedTab = tab
    }
}

private struct BigActionButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let inFlight: Bool
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: DS.Space.s) {
                ZStack {
                    Image(systemName: icon)
                        .font(.system(size: 30, weight: .semibold))
                        .opacity(inFlight ? 0 : 1)
                    if inFlight {
                        ProgressView()
                            .tint(.white)
                    }
                }
                .frame(height: 36)
                Text(title)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                Text(subtitle)
                    .font(DS.Text.caption)
                    .opacity(0.85)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 132)
            .background(
                tint.gradient,
                in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            )
        }
        .buttonStyle(.pressable)
        .disabled(disabled)
        .opacity(disabled && !inFlight ? 0.5 : 1)
        .accessibilityLabel(inFlight ? "\(title), in progress" : title)
    }
}

private struct QuickActionTile: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    var inFlight: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                ZStack {
                    IconTile(icon: icon, tint: tint, size: 36)
                        .opacity(inFlight ? 0 : 1)
                    if inFlight {
                        ProgressView()
                            .controlSize(.small)
                            .tint(tint)
                    }
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(DS.Text.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(DS.Space.m)
            .background(
                DS.Palette.card,
                in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            )
        }
        .buttonStyle(.pressable)
        .disabled(disabled)
        .opacity(disabled && !inFlight ? 0.5 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(inFlight ? "\(title), in progress" : "\(title). \(subtitle)")
        .accessibilityAddTraits(.isButton)
    }
}
