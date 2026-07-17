import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    @State private var draft: DeviceConfig?
    @State private var isSaving = false
    @State private var settingsError: String?
    @State private var toast: String?

    @State private var wifiSSID = ""
    @State private var wifiPassword = ""
    @State private var wifiSending = false

    @State private var showUpdateConfirm = false
    @State private var isUpdating = false
    @State private var showForgetConfirm = false

    private static let voices = [
        "en_US-lessac-low",
        "en_US-lessac-medium",
        "en_US-amy-low",
        "en_US-amy-medium",
        "en_US-ryan-low",
        "en_US-ryan-medium",
        "en_GB-alan-low",
        "en_GB-alan-medium",
    ]

    private static let readLanguages = [
        "Spanish", "French", "German", "Italian", "Portuguese", "Dutch",
        "Chinese", "Japanese", "Korean", "Arabic", "Hebrew", "Hindi",
        "Russian", "Ukrainian", "Vietnamese",
    ]

    private static let twoWayLanguages: [(code: String, name: String)] = [
        ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"),
        ("it", "Italian"), ("pt", "Portuguese"), ("zh", "Chinese"), ("ja", "Japanese"),
        ("ko", "Korean"), ("ar", "Arabic"), ("he", "Hebrew"), ("hi", "Hindi"),
        ("ru", "Russian"), ("uk", "Ukrainian"), ("vi", "Vietnamese"),
    ]

    private var hasChanges: Bool {
        guard let draft = draft, let current = appState.config else { return false }
        return draft != current
    }

    var body: some View {
        NavigationStack {
            Group {
                if let cfg = Binding($draft) {
                    configForm(cfg)
                } else if let error = appState.lastError, appState.config == nil {
                    loadFailedState(error)
                } else {
                    loadingState
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }
                            .fontWeight(.semibold)
                            .disabled(!hasChanges || appState.client == nil)
                            .accessibilityHint("Sends the changed settings to the glasses.")
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    if hasChanges && !isSaving {
                        Button("Revert") { draft = appState.config }
                            .accessibilityHint("Discards unsaved changes.")
                    }
                }
            }
            .onAppear { if draft == nil { draft = appState.config } }
            .onChange(of: appState.config) { newValue in
                if draft == nil { draft = newValue }
            }
            .overlay(alignment: .bottom) {
                if let toast = toast {
                    Label(toast, systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .alert("Couldn't reach the glasses", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(settingsError ?? "")
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { settingsError != nil }, set: { if !$0 { settingsError = nil } })
    }

    // MARK: - Loading / error

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("Loading settings from the glasses…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private func loadFailedState(_ error: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Couldn't load settings")
                .font(.title3.bold())
            Text(error)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                Task { await appState.refresh() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Form

    private func configForm(_ cfg: Binding<DeviceConfig>) -> some View {
        Form {
            voiceSection(cfg)
            translationSection(cfg)
            twoWaySection(cfg)
            wakeWordSection(cfg)
            navigationSection(cfg)
            wifiSection
            maintenanceSection
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func voiceSection(_ cfg: Binding<DeviceConfig>) -> some View {
        Section {
            Picker("Voice", selection: cfg.voice) {
                ForEach(voiceOptions(current: cfg.wrappedValue.voice), id: \.self) { voice in
                    Text(voiceDisplayName(voice)).tag(voice)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Speech rate")
                    Spacer()
                    Text(rateLabel(cfg.wrappedValue.rate))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack(spacing: 10) {
                    Image(systemName: "tortoise.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Slider(value: cfg.rate, in: 0.5...2.0, step: 0.05)
                        .accessibilityLabel("Speech rate")
                        .accessibilityValue("\(rateLabel(cfg.wrappedValue.rate)) normal speed")
                    Image(systemName: "hare.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
        } header: {
            Text("Voice")
        } footer: {
            Text("How the glasses sound and how fast they speak. Saved settings apply to the next thing they say.")
        }
    }

    private func translationSection(_ cfg: Binding<DeviceConfig>) -> some View {
        Section {
            Picker("Translate reading to", selection: Binding(
                get: { cfg.wrappedValue.language ?? "" },
                set: { cfg.wrappedValue.language = $0.isEmpty ? nil : $0 }
            )) {
                Text("Off — read as written").tag("")
                ForEach(readLanguageOptions(current: cfg.wrappedValue.language), id: \.self) { lang in
                    Text(lang).tag(lang)
                }
            }
        } header: {
            Text("Reading Translation")
        } footer: {
            Text("When set, everything the glasses read is translated into this language before it's spoken.")
        }
    }

    private func twoWaySection(_ cfg: Binding<DeviceConfig>) -> some View {
        Section {
            Toggle("Two-way interpreter", isOn: cfg.twoWay.enabled)
            if cfg.wrappedValue.twoWay.enabled {
                Picker("They speak", selection: cfg.twoWay.theirs) {
                    ForEach(twoWayOptions(current: cfg.wrappedValue.twoWay.theirs), id: \.code) {
                        Text($0.name).tag($0.code)
                    }
                }
                Picker("You speak", selection: cfg.twoWay.yours) {
                    ForEach(twoWayOptions(current: cfg.wrappedValue.twoWay.yours), id: \.code) {
                        Text($0.name).tag($0.code)
                    }
                }
            }
        } header: {
            Text("Two-Way Interpreter")
        } footer: {
            Text("A live conversation loop: the glasses hear their language and speak yours, then translate your replies out loud. A single button press stops it.")
        }
    }

    private func wakeWordSection(_ cfg: Binding<DeviceConfig>) -> some View {
        Section {
            Toggle("Wake word", isOn: cfg.wakeWord.enabled)
        } header: {
            Text("Wake Word")
        } footer: {
            Text("Say \u{201C}Hey Jarvis\u{201D} to ask a question hands-free. Detection runs entirely on the glasses — audio is never stored or uploaded. The phrase is \u{201C}Hey Jarvis\u{201D} in this version; a custom \u{201C}Hey Vision\u{201D} phrase is planned.")
        }
    }

    private func navigationSection(_ cfg: Binding<DeviceConfig>) -> some View {
        Section {
            Toggle("Navigation assist", isOn: cfg.navigation.enabled)
            if cfg.wrappedValue.navigation.enabled {
                Stepper(value: cfg.navigation.intervalS, in: 1.0...10.0, step: 0.5) {
                    HStack {
                        Text("Check surroundings")
                        Spacer()
                        Text("every \(intervalLabel(cfg.wrappedValue.navigation.intervalS))s")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .accessibilityValue("Every \(intervalLabel(cfg.wrappedValue.navigation.intervalS)) seconds")
            }
        } header: {
            Text("Navigation Assist")
        } footer: {
            Text("Periodically describes hazards, signage, and doorways ahead. It provides assistive information only — it is not a certified safety device and never replaces a cane, guide dog, or other primary mobility aid.")
        }
    }

    private var wifiSection: some View {
        Section {
            TextField("Network name (SSID)", text: $wifiSSID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Password", text: $wifiPassword)
            Button {
                sendWifi()
            } label: {
                HStack {
                    Text("Send to Glasses")
                    if wifiSending {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(wifiSSID.trimmingCharacters(in: .whitespaces).isEmpty
                      || wifiSending || appState.client == nil)
        } header: {
            Text("Wi-Fi")
        } footer: {
            Text("Adds a network to the glasses so they can get online away from home. Credentials travel directly over your local network.")
        }
    }

    private var maintenanceSection: some View {
        Section {
            Button {
                showUpdateConfirm = true
            } label: {
                HStack {
                    Label("Check for Updates", systemImage: "arrow.down.circle")
                    if isUpdating {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isUpdating || appState.client == nil)
            .confirmationDialog("Update the glasses?", isPresented: $showUpdateConfirm, titleVisibility: .visible) {
                Button("Update and Restart") { runUpdate() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The glasses download the latest software and restart. They'll be unavailable for about a minute.")
            }

            Button(role: .destructive) {
                showForgetConfirm = true
            } label: {
                Label("Forget This Device", systemImage: "xmark.circle")
                    .foregroundColor(.red)
            }
            .confirmationDialog("Forget these glasses?", isPresented: $showForgetConfirm, titleVisibility: .visible) {
                Button("Forget", role: .destructive) { appState.forget() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the pairing from this phone. History and settings stay on the glasses.")
            }
        } header: {
            Text("Maintenance")
        } footer: {
            Text("Glasses firmware \(appState.status?.version ?? "—")")
        }
    }

    // MARK: - Actions

    private func save() {
        guard let draft = draft, let client = appState.client else { return }
        Haptics.tap()
        isSaving = true
        Task { @MainActor in
            do {
                let saved = try await client.putConfig(draft)
                self.draft = saved
                appState.config = saved
                Haptics.success()
                showToast("Saved to the glasses")
            } catch {
                Haptics.error()
                settingsError = error.localizedDescription
            }
            isSaving = false
        }
    }

    private func sendWifi() {
        guard let client = appState.client else { return }
        let ssid = wifiSSID.trimmingCharacters(in: .whitespaces)
        guard !ssid.isEmpty else { return }
        Haptics.tap()
        wifiSending = true
        Task { @MainActor in
            do {
                try await client.wifi(ssid: ssid, psk: wifiPassword)
                wifiPassword = ""
                Haptics.success()
                showToast("Network sent to the glasses")
            } catch {
                Haptics.error()
                settingsError = error.localizedDescription
            }
            wifiSending = false
        }
    }

    private func runUpdate() {
        guard let client = appState.client else { return }
        isUpdating = true
        Task { @MainActor in
            do {
                try await client.update()
                Haptics.success()
                showToast("Update started — the glasses are restarting")
            } catch APIError.unauthorized {
                Haptics.error()
                settingsError = APIError.unauthorized.localizedDescription
            } catch APIError.http(let code) {
                Haptics.error()
                settingsError = "The update couldn't start (HTTP \(code))."
            } catch {
                // the API service restarts mid-response, so a dropped connection
                // usually means the update DID begin
                showToast("Update requested — give the glasses a minute to restart")
            }
            isUpdating = false
        }
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        UIAccessibility.post(notification: .announcement, argument: text)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation { if toast == text { toast = nil } }
        }
    }

    // MARK: - Option helpers

    private func voiceOptions(current: String) -> [String] {
        Self.voices.contains(current) ? Self.voices : [current] + Self.voices
    }

    private func voiceDisplayName(_ id: String) -> String {
        let parts = id.split(separator: "-")
        guard parts.count >= 3 else { return id }
        let region: String
        switch parts[0] {
        case "en_US": region = "US English"
        case "en_GB": region = "British English"
        default: region = String(parts[0])
        }
        return "\(parts[1].capitalized) (\(region), \(parts[2]))"
    }

    private func readLanguageOptions(current: String?) -> [String] {
        guard let current = current, !Self.readLanguages.contains(current) else {
            return Self.readLanguages
        }
        return [current] + Self.readLanguages
    }

    private func twoWayOptions(current: String) -> [(code: String, name: String)] {
        if Self.twoWayLanguages.contains(where: { $0.code == current }) {
            return Self.twoWayLanguages
        }
        return [(code: current, name: current)] + Self.twoWayLanguages
    }

    private func rateLabel(_ rate: Double) -> String {
        rate.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    private func intervalLabel(_ interval: Double) -> String {
        interval.formatted(.number.precision(.fractionLength(0...1)))
    }
}
