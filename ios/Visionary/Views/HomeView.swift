import SwiftUI
import UIKit

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
    }
}

extension View {
    func cardStyle() -> some View { modifier(CardBackground()) }
}

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var inFlightMode: String?
    @State private var actionError: String?
    @State private var showInbox = false

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
                VStack(spacing: 16) {
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
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Visionary")
            .toolbar {
                ToolbarItem(placement: .primaryAction) { inboxButton }
            }
            .refreshable {
                await appState.refresh()
                await appState.refreshModes()
            }
            // Re-pull /modes on every visit: a mode activated in the Modes tab
            // (or by voice on the glasses) shows on the card without waiting
            // for the slow poll.
            .onAppear {
                Task { await appState.refreshModes() }
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

    // MARK: - Hero status card

    @ViewBuilder
    private var statusCard: some View {
        if let status = appState.status {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.12))
                            .frame(width: 48, height: 48)
                        Image(systemName: "eyeglasses")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Visionary Glasses")
                            .font(.headline)
                        HStack(spacing: 6) {
                            Circle()
                                .fill(status.online ? Color.green : Color.orange)
                                .frame(width: 8, height: 8)
                            Text(status.online ? "Online" : "Offline — reading still works")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if status.recording {
                        chip(text: "REC", color: .red, icon: "record.circle")
                    } else if status.busy {
                        chip(text: "Working", color: .orange, icon: "hourglass")
                    }
                }
                .accessibilityElement(children: .combine)

                Divider()

                VStack(spacing: 8) {
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
                .font(.subheadline)
            }
            .cardStyle()
        } else if let error = appState.lastError {
            VStack(alignment: .leading, spacing: 10) {
                Label("Can't reach the glasses", systemImage: "wifi.exclamationmark")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Make sure the glasses are powered on and on the same network, then pull down to retry.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .cardStyle()
        } else {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Circle().fill(Color(.tertiarySystemFill)).frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Visionary Glasses").font(.headline)
                        Text("Connecting…").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ProgressView()
                }
            }
            .cardStyle()
            .accessibilityLabel("Connecting to the glasses")
        }
    }

    private func chip(text: String, color: Color, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
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
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.red, in: Capsule())
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
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.red.opacity(0.14))
                        .frame(width: 44, height: 44)
                    Image(systemName: "tray.full.fill")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.red)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.inboxCount == 1
                         ? "1 action waiting"
                         : "\(appState.inboxCount) actions waiting")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Text("Texts, emails, and notes need your OK before they go out.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .cardStyle()
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the actions inbox.")
    }

    // MARK: - Current mode

    private var currentModeCard: some View {
        Button {
            Haptics.tap()
            appState.selectedTab = .modes
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.indigo.opacity(0.14))
                        .frame(width: 44, height: 44)
                    Image(systemName: appState.activeMode == nil ? "text.viewfinder" : "wand.and.stars")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.indigo)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Current mode")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(appState.modeDisplayName(appState.activeMode))
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text(appState.activeMode == nil
                         ? "Single press reads whatever is in view"
                         : "Single press on the glasses runs this mode")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .cardStyle()
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Current mode: \(appState.modeDisplayName(appState.activeMode))")
        .accessibilityHint("Opens the mode gallery to switch modes.")
    }

    // MARK: - Read / Describe

    private var actionButtons: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            BigActionButton(
                title: "Read",
                subtitle: "Speak the text in view",
                icon: "text.viewfinder",
                tint: .blue,
                inFlight: inFlightMode == "read",
                disabled: inFlightMode != nil || appState.client == nil
            ) { trigger("read") }
                .accessibilityHint("Takes a photo and the glasses read its text out loud.")
            BigActionButton(
                title: "Describe",
                subtitle: "Describe the scene",
                icon: "eye",
                tint: .purple,
                inFlight: inFlightMode == "describe",
                disabled: inFlightMode != nil || appState.client == nil
            ) { trigger("describe") }
                .accessibilityHint("Takes a photo and the glasses describe what they see.")
        }
    }

    private func trigger(_ mode: String) {
        guard inFlightMode == nil, let client = appState.client else { return }
        Haptics.tap()
        inFlightMode = mode
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
            inFlightMode = nil
        }
    }

    // MARK: - Quick actions

    private var isRecording: Bool { appState.status?.recording == true }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick actions")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                QuickActionTile(
                    title: isRecording ? "Stop Recording" : "Voice Note",
                    subtitle: isRecording ? "The glasses are recording" : "Record and summarize",
                    icon: isRecording ? "stop.circle.fill" : "waveform",
                    tint: .pink,
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
                    tint: .teal
                ) { open(.live, live: .captions) }
                    .accessibilityHint("Opens live captions.")
                QuickActionTile(
                    title: "Guide",
                    subtitle: "See and talk them through",
                    icon: "person.wave.2",
                    tint: .green
                ) { open(.live, live: .guide) }
                    .accessibilityHint("Opens sighted-guide mode.")
                QuickActionTile(
                    title: "Search Memory",
                    subtitle: "Find anything seen",
                    icon: "sparkle.magnifyingglass",
                    tint: .orange
                ) { open(.library, library: .search) }
                    .accessibilityHint("Opens visual memory search.")
                QuickActionTile(
                    title: "Flashcards",
                    subtitle: "Review today's deck",
                    icon: "rectangle.on.rectangle.angled",
                    tint: .purple
                ) { open(.library, library: .flashcards) }
                    .accessibilityHint("Opens flashcard review.")
                QuickActionTile(
                    title: "Notes",
                    subtitle: "Captured by voice",
                    icon: "note.text",
                    tint: .yellow
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
            VStack(spacing: 8) {
                if inFlight {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 32, weight: .semibold))
                }
                Text(title)
                    .font(.title3.bold())
                Text(subtitle)
                    .font(.caption)
                    .opacity(0.85)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 130)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(tint.gradient)
            )
        }
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
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.15))
                        .frame(width: 36, height: 36)
                    if inFlight {
                        ProgressView()
                            .controlSize(.small)
                            .tint(tint)
                    } else {
                        Image(systemName: icon)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(tint)
                    }
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled && !inFlight ? 0.5 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(inFlight ? "\(title), in progress" : "\(title). \(subtitle)")
        .accessibilityAddTraits(.isButton)
    }
}
