import SwiftUI
import UIKit
import AVFoundation
import VisionKit

// MARK: - Shared mode presentation

enum ModeStyle {
    static func categoryLabel(_ category: String) -> String {
        category.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Categories come from pack JSON, so match on fragments instead of exact names.
    static func categoryIcon(_ category: String) -> String {
        let c = category.lowercased()
        if c.contains("access") || c.contains("vision") { return "accessibility" }
        if c.contains("learn") || c.contains("school") || c.contains("study") { return "graduationcap.fill" }
        if c.contains("kitchen") || c.contains("cook") || c.contains("food") { return "fork.knife" }
        if c.contains("work") || c.contains("office") || c.contains("meeting") { return "briefcase.fill" }
        if c.contains("repair") || c.contains("diy") || c.contains("fix") || c.contains("field") { return "wrench.and.screwdriver.fill" }
        if c.contains("health") || c.contains("care") || c.contains("med") { return "cross.case.fill" }
        if c.contains("out") || c.contains("travel") || c.contains("explore") { return "map.fill" }
        if c.contains("fun") || c.contains("play") || c.contains("game") { return "gamecontroller.fill" }
        if c.contains("commun") || c.contains("social") { return "bubble.left.and.bubble.right.fill" }
        if c.contains("memory") || c.contains("brain") { return "brain.head.profile" }
        return "sparkles"
    }

    static func categoryColor(_ category: String) -> Color {
        let c = category.lowercased()
        if c.contains("access") || c.contains("vision") { return .blue }
        if c.contains("learn") || c.contains("school") || c.contains("study") { return .indigo }
        if c.contains("kitchen") || c.contains("cook") || c.contains("food") { return .orange }
        if c.contains("work") || c.contains("office") || c.contains("meeting") { return .teal }
        if c.contains("repair") || c.contains("diy") || c.contains("fix") || c.contains("field") { return .brown }
        if c.contains("health") || c.contains("care") || c.contains("med") { return .red }
        if c.contains("out") || c.contains("travel") || c.contains("explore") { return .mint }
        if c.contains("fun") || c.contains("play") || c.contains("game") { return .pink }
        if c.contains("commun") || c.contains("social") { return .green }
        if c.contains("memory") || c.contains("brain") { return .purple }
        return .gray
    }

    static func pipelineLabel(_ pipeline: String) -> String {
        switch pipeline {
        case "see": return "Camera snapshot"
        case "ask": return "Hold to ask"
        case "listen": return "Listens"
        case "loop": return "Runs in background"
        case "session": return "Conversation"
        default: return pipeline.capitalized
        }
    }

    static func pipelineIcon(_ pipeline: String) -> String {
        switch pipeline {
        case "see": return "camera.viewfinder"
        case "ask": return "questionmark.bubble.fill"
        case "listen": return "mic.fill"
        case "loop": return "arrow.triangle.2.circlepath"
        case "session": return "bubble.left.and.bubble.right.fill"
        default: return "sparkles"
        }
    }

    static func pipelineBlurb(_ pipeline: String) -> String {
        switch pipeline {
        case "see": return "A single press takes one photo and the glasses speak the answer."
        case "ask": return "Hold the button, ask your question out loud, and the glasses answer about what you're looking at."
        case "listen": return "The glasses record what they hear, then speak the result."
        case "loop": return "Keeps watching in the background and speaks up when there's something worth saying. A single press stops it."
        case "session": return "An ongoing back-and-forth with the glasses. Say \u{201C}stop\u{201D} or press once to end it."
        default: return ""
        }
    }
}

// MARK: - Model

@MainActor
final class ModesModel: ObservableObject {
    @Published private(set) var modes: [Mode]?
    @Published private(set) var activeModeID: String?
    @Published private(set) var packs: [Pack]?
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    @Published private(set) var switchingModeID: String?   // mode being activated; "" while deactivating
    @Published private(set) var isInstalling = false
    @Published private(set) var removingPackName: String?

    var activeMode: Mode? {
        guard let id = activeModeID else { return nil }
        return modes?.first { $0.id == id }
    }

    func load(client: APIClient?) async {
        guard let client = client, !isLoading else { return }
        isLoading = true
        loadError = nil
        do {
            try await refreshSnapshot(client: client)
        } catch {
            if !Task.isCancelled { loadError = error.localizedDescription }
        }
        isLoading = false
    }

    /// nil returns the glasses to classic single-press reading.
    func setActive(_ id: String?, client: APIClient) async throws {
        guard switchingModeID == nil else { return }
        switchingModeID = id ?? ""
        defer { switchingModeID = nil }
        try await client.setActiveMode(id)
        activeModeID = id
    }

    /// Returns how many modes the pack added.
    func install(url: String, client: APIClient) async throws -> Int {
        guard !isInstalling else { return 0 }
        isInstalling = true
        defer { isInstalling = false }
        let ids = try await client.installPack(url: url)
        try? await refreshSnapshot(client: client)
        return ids.count
    }

    func remove(_ pack: Pack, client: APIClient) async throws {
        guard removingPackName == nil else { return }
        removingPackName = pack.name
        defer { removingPackName = nil }
        try await client.removePack(name: pack.name)
        // re-pull instead of guessing: the device decides what happens to an
        // active mode whose pack just vanished
        try? await refreshSnapshot(client: client)
    }

    private func refreshSnapshot(client: APIClient) async throws {
        async let m = client.modes()
        async let p = client.packs()
        let (snapshot, packList) = try await (m, p)
        modes = snapshot.modes
        activeModeID = snapshot.activeMode
        packs = packList
    }
}

// MARK: - Modes store

struct ModesView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = ModesModel()

    @State private var query = ""
    @State private var selectedMode: Mode?
    @State private var showPacks = false
    @State private var listError: String?
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            content
                .background(Color(.systemGroupedBackground))
                .navigationTitle("Modes")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showPacks = true
                        } label: {
                            Label("Packs", systemImage: "shippingbox")
                        }
                        .disabled(appState.client == nil)
                        .accessibilityHint("Install new mode packs or remove ones you added.")
                    }
                }
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Search modes")
                .sheet(item: $selectedMode) { mode in
                    ModeDetailSheet(mode: mode, model: model) { message in
                        showToast(message)
                    }
                }
                .sheet(isPresented: $showPacks) {
                    PacksSheet(model: model)
                }
                .alert("Couldn't reach the glasses", isPresented: listErrorBinding) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(listError ?? "")
                }
                .dsToast($toast)
                .task {
                    if model.modes == nil {
                        await model.load(client: appState.client)
                    }
                }
        }
    }

    private var listErrorBinding: Binding<Bool> {
        Binding(get: { listError != nil }, set: { if !$0 { listError = nil } })
    }

    @ViewBuilder
    private var content: some View {
        if appState.client == nil {
            unpairedState
        } else if let modes = model.modes {
            modeList(modes)
        } else if let error = model.loadError {
            errorState(error)
        } else {
            loadingState
        }
    }

    // MARK: - States

    private var loadingState: some View {
        LoadingStateView(label: "Loading modes from the glasses…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ error: String) -> some View {
        EmptyStateView(
            icon: "wifi.exclamationmark",
            tint: DS.Palette.attention,
            title: "Couldn't load modes",
            message: error,
            actionTitle: "Try Again"
        ) {
            Task { await model.load(client: appState.client) }
        }
        .padding(.horizontal, DS.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var unpairedState: some View {
        EmptyStateView(
            icon: "square.grid.2x2",
            tint: DS.Palette.modes,
            title: "No glasses connected",
            message: "Pair with your Visionary glasses to browse and activate modes."
        )
        .padding(.horizontal, DS.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List

    private func modeList(_ modes: [Mode]) -> some View {
        let filtered = filteredModes(modes)
        let grouped = Dictionary(grouping: filtered) { $0.category }
        let categories = grouped.keys.sorted()
        return List {
            if query.isEmpty {
                Section {
                    activeModeCard
                } header: {
                    Text("On the Glasses")
                } footer: {
                    Text("The active mode runs on a single button press. Everything else about the glasses stays the same.")
                }
            }
            if filtered.isEmpty {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text("No modes match \u{201C}\(query)\u{201D}")
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        Text("Try different words, or install a pack that has what you need.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .listRowBackground(Color.clear)
                }
            } else {
                ForEach(categories, id: \.self) { category in
                    Section {
                        ForEach(grouped[category] ?? []) { mode in
                            Button {
                                selectedMode = mode
                            } label: {
                                ModeRow(mode: mode,
                                        isActive: mode.id == model.activeModeID,
                                        isSwitching: model.switchingModeID == mode.id)
                            }
                        }
                    } header: {
                        Label(ModeStyle.categoryLabel(category),
                              systemImage: ModeStyle.categoryIcon(category))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await model.load(client: appState.client) }
    }

    private func filteredModes(_ modes: [Mode]) -> [Mode] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return modes }
        return modes.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || $0.description.localizedCaseInsensitiveContains(q)
                || $0.category.localizedCaseInsensitiveContains(q)
                || $0.id.localizedCaseInsensitiveContains(q)
        }
    }

    // MARK: - Active mode card

    @ViewBuilder
    private var activeModeCard: some View {
        if let mode = model.activeMode {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    IconTile(icon: ModeStyle.categoryIcon(mode.category),
                             tint: ModeStyle.categoryColor(mode.category),
                             size: 48, prominent: true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(mode.name)
                            .font(.headline)
                        Label(ModeStyle.pipelineLabel(mode.pipeline),
                              systemImage: ModeStyle.pipelineIcon(mode.pipeline))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    DSBadge(text: "Active", tint: .accentColor)
                }
                .accessibilityElement(children: .combine)
                Button(action: deactivate) {
                    Group {
                        if model.switchingModeID == "" {
                            ProgressView()
                        } else {
                            Text("Deactivate — back to classic reading")
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.bordered)
                .disabled(model.switchingModeID != nil)
                .accessibilityHint("A single press reads text again.")
            }
            .padding(.vertical, 4)
        } else {
            HStack(spacing: 12) {
                IconTile(icon: "text.viewfinder", tint: DS.Palette.read,
                         size: 48, prominent: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Classic reading")
                        .font(.headline)
                    Text("No mode active — a single press reads what's in front of you. Pick a mode below to change that.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }

    private func deactivate() {
        guard let client = appState.client else { return }
        Haptics.tap()
        Task { @MainActor in
            do {
                try await model.setActive(nil, client: client)
                Haptics.success()
                showToast("Back to classic reading")
            } catch {
                Haptics.error()
                listError = error.localizedDescription
            }
        }
    }

    private func showToast(_ text: String) {
        toast = text   // .dsToast announces, floats in, and auto-dismisses
    }
}

// MARK: - Mode row

private struct ModeRow: View {
    let mode: Mode
    let isActive: Bool
    let isSwitching: Bool

    var body: some View {
        HStack(spacing: 12) {
            IconTile(icon: ModeStyle.categoryIcon(mode.category),
                     tint: ModeStyle.categoryColor(mode.category))
            VStack(alignment: .leading, spacing: 3) {
                Text(mode.name)
                    .font(.body.weight(isActive ? .semibold : .regular))
                    .foregroundColor(.primary)
                if !mode.description.isEmpty {
                    Text(mode.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Label(ModeStyle.pipelineLabel(mode.pipeline),
                      systemImage: ModeStyle.pipelineIcon(mode.pipeline))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if isSwitching {
                ProgressView()
            } else if isActive {
                DSBadge(text: "Active", tint: .accentColor)
            } else {
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(mode.name)\(isActive ? ", active" : ""). \(mode.description)")
        .accessibilityHint(isActive ? "Shows details and lets you deactivate it."
                                    : "Shows details and lets you activate it.")
    }
}

// MARK: - Mode detail

private struct ModeDetailSheet: View {
    let mode: Mode
    @ObservedObject var model: ModesModel
    let onDone: (String) -> Void

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var detailError: String?
    @State private var showPrompt = false

    private var isActive: Bool { model.activeModeID == mode.id }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    hero
                    pipelineCard
                    if !mode.description.isEmpty {
                        descriptionCard
                    }
                    if !mode.prompt.isEmpty {
                        promptCard
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) { activateBar }
            .navigationTitle(mode.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Couldn't switch modes", isPresented: detailErrorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(detailError ?? "")
            }
        }
    }

    private var detailErrorBinding: Binding<Bool> {
        Binding(get: { detailError != nil }, set: { if !$0 { detailError = nil } })
    }

    private var hero: some View {
        VStack(spacing: 12) {
            IconTile(icon: ModeStyle.categoryIcon(mode.category),
                     tint: ModeStyle.categoryColor(mode.category),
                     size: 84, prominent: true)
            Text(mode.name)
                .font(DS.Text.title)
                .multilineTextAlignment(.center)
            HStack(spacing: 6) {
                DSBadge(text: ModeStyle.categoryLabel(mode.category),
                        tint: ModeStyle.categoryColor(mode.category),
                        icon: ModeStyle.categoryIcon(mode.category))
                if isActive {
                    DSBadge(text: "Active", tint: .accentColor)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var pipelineCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(ModeStyle.pipelineLabel(mode.pipeline),
                  systemImage: ModeStyle.pipelineIcon(mode.pipeline))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(ModeStyle.pipelineBlurb(mode.pipeline))
                .font(.body)
        }
        .cardStyle()
        .accessibilityElement(children: .combine)
    }

    private var descriptionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("About", systemImage: "info.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(mode.description)
                .font(.body)
        }
        .cardStyle()
    }

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(isExpanded: $showPrompt) {
                Text(mode.prompt)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 8)
            } label: {
                Label("What the glasses are told", systemImage: "text.quote")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityHint("Shows the exact instructions this mode gives the AI.")
        }
        .cardStyle()
    }

    private var activateBar: some View {
        Button(action: toggleActive) {
            Group {
                if model.switchingModeID != nil {
                    ProgressView().tint(.white)
                } else {
                    Text(isActive ? "Deactivate" : "Activate on Glasses")
                        .font(.headline)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.borderedProminent)
        .tint(isActive ? .red : .accentColor)
        .disabled(model.switchingModeID != nil || appState.client == nil)
        .padding()
        .background(.thinMaterial)
        .accessibilityHint(isActive
            ? "Returns the glasses to classic single-press reading."
            : "A single press on the glasses runs this mode.")
    }

    private func toggleActive() {
        guard let client = appState.client else { return }
        let wasActive = isActive
        Haptics.tap()
        Task { @MainActor in
            do {
                try await model.setActive(wasActive ? nil : mode.id, client: client)
                Haptics.success()
                dismiss()
                onDone(wasActive ? "Back to classic reading"
                                 : "\(mode.name) is live on the glasses")
            } catch {
                Haptics.error()
                detailError = error.localizedDescription
            }
        }
    }
}

// MARK: - Packs

private struct PacksSheet: View {
    @ObservedObject var model: ModesModel

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var showScanner = false
    @State private var cameraMessage: String?
    @State private var packError: String?
    @State private var packToRemove: Pack?
    @State private var showRemoveConfirm = false
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            List {
                installSection
                packsSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Mode Packs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
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
        }
    }

    private var packErrorBinding: Binding<Bool> {
        Binding(get: { packError != nil }, set: { if !$0 { packError = nil } })
    }

    private var cameraMessageBinding: Binding<Bool> {
        Binding(get: { cameraMessage != nil }, set: { if !$0 { cameraMessage = nil } })
    }

    // MARK: - Install

    private var installSection: some View {
        Section {
            TextField("Pack URL (https://…/pack.json)", text: $urlText)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(installFromField)
                .accessibilityHint("A web link to a pack's JSON file.")
            HStack(spacing: 10) {
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
            Text("A pack is a shareable set of modes — just prompts, no code. Scan a pack QR at a meetup or paste a link, and its modes install instantly.")
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
                showToast(count == 1 ? "Installed 1 new mode" : "Installed \(count) new modes")
            } catch {
                Haptics.error()
                packError = error.localizedDescription
            }
        }
    }

    // MARK: - Scanner

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

    // MARK: - Installed packs

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
                HStack(spacing: 10) {
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
        HStack(spacing: 12) {
            IconTile(icon: pack.builtin ? "shippingbox.fill" : "shippingbox",
                     tint: .accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(pack.name)
                    .font(.body)
                Text(pack.modes.count == 1 ? "1 mode" : "\(pack.modes.count) modes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.removingPackName == pack.name {
                ProgressView()
            } else if pack.builtin {
                DSBadge(text: "Built-in", tint: .gray)
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
                Haptics.success()
                showToast("Removed \u{201C}\(pack.name)\u{201D}")
            } catch {
                Haptics.error()
                packError = error.localizedDescription
            }
            packToRemove = nil
        }
    }

    private func showToast(_ text: String) {
        toast = text   // .dsToast announces, floats in, and auto-dismisses
    }
}

// MARK: - Pack QR scanner (same DataScanner wrapper pattern as PairingView)

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
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 24)
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
