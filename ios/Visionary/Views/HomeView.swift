import SwiftUI
import UIKit

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
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
    @State private var speakText = ""
    @State private var isSpeaking = false
    @State private var actionError: String?

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
                    actionButtons
                    speakCard
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Visionary")
            .refreshable { await appState.refresh() }
            .scrollDismissesKeyboard(.interactively)
            .alert("Couldn't complete that", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actionError ?? "")
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
    }

    // MARK: - Status card

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
            } catch {
                Haptics.error()
                actionError = error.localizedDescription
            }
            // brief linger so a fast round trip still visibly registers
            try? await Task.sleep(nanoseconds: 400_000_000)
            inFlightMode = nil
        }
    }

    // MARK: - Speak

    private var speakCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Speak through the glasses", systemImage: "speaker.wave.2.fill")
                .font(.headline)
            Text("Type a sentence and the glasses say it out loud — handy for demos or getting a student's attention.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("Something to say…", text: $speakText)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.send)
                    .onSubmit(sendSpeak)
                Button(action: sendSpeak) {
                    if isSpeaking {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                }
                .frame(minWidth: 44, minHeight: 44)
                .disabled(trimmedSpeakText.isEmpty || isSpeaking || appState.client == nil)
                .accessibilityLabel("Speak")
                .accessibilityHint("The glasses say the typed sentence out loud.")
            }
        }
        .cardStyle()
    }

    private var trimmedSpeakText: String {
        speakText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sendSpeak() {
        let text = trimmedSpeakText
        guard !text.isEmpty, !isSpeaking, let client = appState.client else { return }
        Haptics.tap()
        isSpeaking = true
        Task { @MainActor in
            do {
                try await client.speak(text)
                speakText = ""
                Haptics.success()
            } catch {
                Haptics.error()
                actionError = error.localizedDescription
            }
            isSpeaking = false
        }
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
