import SwiftUI
import UIKit
import AVFoundation
import VisionKit

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
        "marin", "cedar", "alloy", "ash", "ballad", "coral", "echo",
        "fable", "nova", "onyx", "sage", "shimmer", "verse",
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
            .dsToast($toast)
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
        LoadingStateView(label: "Loading settings from the glasses…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.Palette.canvas)
    }

    private func loadFailedState(_ error: String) -> some View {
        EmptyStateView(
            icon: "wifi.exclamationmark",
            title: "Couldn't load settings",
            message: error,
            actionTitle: "Try Again"
        ) {
            Task { await appState.refresh() }
        }
        .padding(.horizontal, DS.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Palette.canvas)
    }

    // MARK: - Form

    private func configForm(_ cfg: Binding<DeviceConfig>) -> some View {
        Form {
            voiceSection(cfg)
            translationSection(cfg)
            twoWaySection(cfg)
            navigationSection(cfg)
            packsSection
            wifiSection
            maintenanceSection
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var packsSection: some View {
        Section {
            NavigationLink {
                PacksView()
            } label: {
                Label("Mode Packs", systemImage: "shippingbox")
            }
            .disabled(appState.client == nil)
            .accessibilityHint("Install new mode packs or remove ones you added.")
        } header: {
            Text("Modes")
        } footer: {
            Text("A pack is a shareable set of modes — just prompts, no code. Activate modes from the Home tab.")
        }
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
        toast = text   // .dsToast announces, floats in, and auto-dismisses
    }

    // MARK: - Option helpers

    private func voiceOptions(current: String) -> [String] {
        Self.voices.contains(current) ? Self.voices : [current] + Self.voices
    }

    private func voiceDisplayName(_ id: String) -> String {
        let openAIVoices: [String: String] = [
            "marin": "Marin", "cedar": "Cedar", "alloy": "Alloy",
            "ash": "Ash", "ballad": "Ballad", "coral": "Coral",
            "echo": "Echo", "fable": "Fable", "nova": "Nova",
            "onyx": "Onyx", "sage": "Sage", "shimmer": "Shimmer",
            "verse": "Verse",
        ]
        if let name = openAIVoices[id] { return name }
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

// MARK: - Mode packs

/// Pack management, pushed from Settings: install by URL or QR, review what's
/// installed, remove community packs. Modes themselves activate from Home.
private struct PacksView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = ModesModel()

    @State private var urlText = ""
    @State private var showScanner = false
    @State private var cameraMessage: String?
    @State private var packError: String?
    @State private var packToRemove: Pack?
    @State private var showRemoveConfirm = false
    @State private var toast: String?

    var body: some View {
        List {
            installSection
            packsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Mode Packs")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $showScanner) {
            PackScannerSheet { code in handleScanned(code) }
        }
        .alert("Couldn't manage packs", isPresented: packErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(packError ?? "")
        }
        .alert("Camera Unavailable", isPresented: cameraMessageBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(cameraMessage ?? "")
        }
        .confirmationDialog("Remove \u{201C}\(packToRemove?.name ?? "")\u{201D}?",
                            isPresented: $showRemoveConfirm, titleVisibility: .visible) {
            Button("Remove Pack", role: .destructive) {
                if let pack = packToRemove { remove(pack) }
            }
            Button("Cancel", role: .cancel) { packToRemove = nil }
        } message: {
            Text("Its modes disappear from the glasses. You can reinstall the pack any time.")
        }
        .dsToast($toast)
        .task {
            if model.packs == nil {
                await model.load(client: appState.client)
            }
        }
    }

    private var packErrorBinding: Binding<Bool> {
        Binding(get: { packError != nil }, set: { if !$0 { packError = nil } })
    }

    private var cameraMessageBinding: Binding<Bool> {
        Binding(get: { cameraMessage != nil }, set: { if !$0 { cameraMessage = nil } })
    }

    // MARK: Install

    private var installSection: some View {
        Section {
            TextField("Pack URL (https://…/pack.json)", text: $urlText)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(installFromField)
                .accessibilityHint("A web link to a pack's JSON file.")
            HStack(spacing: DS.Space.s) {
                Button(action: installFromField) {
                    Group {
                        if model.isInstalling {
                            ProgressView()
                        } else {
                            Text("Install")
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedURL.isEmpty || model.isInstalling || appState.client == nil)
                Button(action: openScanner) {
                    Label("Scan QR", systemImage: "qrcode.viewfinder")
                        .frame(minHeight: 32)
                }
                .buttonStyle(.bordered)
                .disabled(model.isInstalling || appState.client == nil)
                .accessibilityHint("Opens the camera to scan a pack's QR code.")
            }
        } header: {
            Text("Install a Pack")
        } footer: {
            Text("Scan a pack QR or paste a link, and its modes install instantly.")
        }
    }

    private var trimmedURL: String {
        urlText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func installFromField() {
        install(url: trimmedURL)
    }

    private func install(url: String) {
        guard !url.isEmpty, let client = appState.client, !model.isInstalling else { return }
        Haptics.tap()
        Task { @MainActor in
            do {
                let count = try await model.install(url: url, client: client)
                urlText = ""
                Haptics.success()
                toast = count == 1 ? "Installed 1 new mode" : "Installed \(count) new modes"
            } catch {
                Haptics.error()
                packError = error.localizedDescription
            }
        }
    }

    // MARK: Scanner

    private func openScanner() {
        guard DataScannerViewController.isSupported else {
            cameraMessage = "This device can't scan QR codes. Paste the pack's URL instead."
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            presentScannerIfAvailable()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        presentScannerIfAvailable()
                    } else {
                        cameraMessage = "Camera access was declined. Paste the pack's URL instead, or allow the camera in Settings."
                    }
                }
            }
        default:
            cameraMessage = "Camera access is off. Allow it in Settings, or paste the pack's URL instead."
        }
    }

    private func presentScannerIfAvailable() {
        if DataScannerViewController.isAvailable {
            showScanner = true
        } else {
            cameraMessage = "The camera isn't available right now. Paste the pack's URL instead."
        }
    }

    /// Pack QR codes carry either a bare URL or JSON {"url": "..."}.
    private func handleScanned(_ code: String) {
        struct PackQR: Decodable { let url: String }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        var packURL: String?
        if trimmed.hasPrefix("{"),
           let decoded = try? JSONDecoder().decode(PackQR.self, from: Data(trimmed.utf8)) {
            packURL = decoded.url
        } else if let url = URL(string: trimmed),
                  url.scheme == "http" || url.scheme == "https" {
            packURL = trimmed
        }
        if let packURL = packURL {
            install(url: packURL)
        } else {
            Haptics.error()
            packError = "That QR code doesn't contain a pack link."
        }
    }

    // MARK: Installed packs

    private var packsSection: some View {
        Section {
            if let packs = model.packs, !packs.isEmpty {
                ForEach(packs) { pack in
                    packRow(pack)
                }
            } else if model.packs != nil {
                Text("No packs yet — even the built-in modes should appear here once the glasses respond.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: DS.Space.s) {
                    ProgressView()
                    Text("Loading packs…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Installed")
        } footer: {
            Text("The built-in pack ships with the glasses and can't be removed.")
        }
    }

    private func packRow(_ pack: Pack) -> some View {
        HStack(spacing: DS.Space.m) {
            IconTile(icon: "shippingbox")
            VStack(alignment: .leading, spacing: 3) {
                Text(pack.name)
                    .font(.body)
                Text(pack.modes.count == 1 ? "1 mode" : "\(pack.modes.count) modes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            if model.removingPackName == pack.name {
                ProgressView()
            } else if pack.builtin {
                DSBadge(text: "Built-in", tint: .secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityHint(pack.builtin ? "" : "Swipe up or down for the remove action.")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !pack.builtin {
                Button(role: .destructive) {
                    packToRemove = pack
                    showRemoveConfirm = true
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
        .contextMenu {
            if !pack.builtin {
                Button(role: .destructive) {
                    packToRemove = pack
                    showRemoveConfirm = true
                } label: {
                    Label("Remove Pack", systemImage: "trash")
                }
            }
        }
    }

    private func remove(_ pack: Pack) {
        guard let client = appState.client else { return }
        Haptics.tap()
        Task { @MainActor in
            do {
                try await model.remove(pack, client: client)
                await appState.refreshModes()
                Haptics.success()
                toast = "Removed \u{201C}\(pack.name)\u{201D}"
            } catch {
                Haptics.error()
                packError = error.localizedDescription
            }
            packToRemove = nil
        }
    }
}

// MARK: - Pack QR scanner

private struct PackScannerSheet: View {
    let onFound: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var found = false

    var body: some View {
        NavigationStack {
            PackQRScanner { code in
                guard !found else { return }
                found = true
                Haptics.tap()
                dismiss()
                onFound(code)
            }
            .ignoresSafeArea()
            .overlay(alignment: .bottom) {
                Text("Point the camera at a mode-pack QR code.")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, DS.Space.l)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, DS.Space.xl)
            }
            .navigationTitle("Scan Pack Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct PackQRScanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        if !controller.isScanning {
            try? controller.startScanning()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let barcode) = item, let value = barcode.payloadStringValue {
                    onScan(value)
                    return
                }
            }
        }
    }
}
