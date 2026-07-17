import SwiftUI

// MARK: - Shared mode presentation

enum ModeStyle {
    static func categoryLabel(_ category: String) -> String {
        category.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Categories come from pack JSON, so match on fragments instead of exact names.
    static func categoryIcon(_ category: String) -> String {
        let c = category.lowercased()
        if c.contains("access") || c.contains("vision") { return "accessibility" }
        if c.contains("learn") || c.contains("school") || c.contains("study") { return "graduationcap" }
        if c.contains("kitchen") || c.contains("cook") || c.contains("food") { return "fork.knife" }
        if c.contains("work") || c.contains("office") || c.contains("meeting") { return "briefcase" }
        if c.contains("repair") || c.contains("diy") || c.contains("fix") || c.contains("field") { return "wrench.and.screwdriver" }
        if c.contains("health") || c.contains("care") || c.contains("med") { return "cross.case" }
        if c.contains("out") || c.contains("travel") || c.contains("explore") { return "map" }
        if c.contains("fun") || c.contains("play") || c.contains("game") { return "gamecontroller" }
        if c.contains("commun") || c.contains("social") { return "bubble.left.and.bubble.right" }
        if c.contains("memory") || c.contains("brain") { return "brain.head.profile" }
        return "sparkles"
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
        case "ask": return "questionmark.bubble"
        case "listen": return "mic"
        case "loop": return "arrow.triangle.2.circlepath"
        case "session": return "bubble.left.and.bubble.right"
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

// MARK: - Mode picker sheet

/// Launched from the current-mode chip on Home: a grouped, searchable picker.
/// One mode runs on the glasses at a time; packs are managed from Settings.
struct ModePickerView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ModesModel()

    @State private var query = ""
    @State private var selectedMode: Mode?
    @State private var listError: String?
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            content
                .background(DS.Palette.canvas)
                .navigationTitle("Modes")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Search modes")
                .sheet(item: $selectedMode) { mode in
                    ModeDetailSheet(mode: mode, model: model) { message in
                        toast = message
                    }
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
            EmptyStateView(
                icon: "eyeglasses",
                title: "No glasses connected",
                message: "Pair with your Visionary glasses to browse and activate modes."
            )
            .padding(.horizontal, DS.Space.xxl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let modes = model.modes {
            modeList(modes)
        } else if let error = model.loadError {
            EmptyStateView(
                icon: "wifi.exclamationmark",
                title: "Couldn't load modes",
                message: error,
                actionTitle: "Try Again"
            ) {
                Task { await model.load(client: appState.client) }
            }
            .padding(.horizontal, DS.Space.xxl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LoadingStateView(label: "Loading modes from the glasses…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
                    EmptyStateView(
                        icon: "magnifyingglass",
                        title: "No modes match \u{201C}\(query)\u{201D}",
                        message: "Try different words, or install a pack from Settings."
                    )
                    .padding(.vertical, DS.Space.xl)
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
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(spacing: DS.Space.m) {
                    IconTile(icon: ModeStyle.categoryIcon(mode.category),
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
                    DSBadge(text: "Active")
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
            .padding(.vertical, DS.Space.xs)
        } else {
            HStack(spacing: DS.Space.m) {
                IconTile(icon: "text.viewfinder", size: 48, prominent: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Classic reading")
                        .font(.headline)
                    Text("No mode active — a single press reads what's in front of you.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, DS.Space.xs)
            .accessibilityElement(children: .combine)
        }
    }

    private func deactivate() {
        guard let client = appState.client else { return }
        Haptics.tap()
        Task { @MainActor in
            do {
                try await model.setActive(nil, client: client)
                await appState.refreshModes()
                Haptics.success()
                toast = "Back to classic reading"
            } catch {
                Haptics.error()
                listError = error.localizedDescription
            }
        }
    }
}

// MARK: - Mode row

private struct ModeRow: View {
    let mode: Mode
    let isActive: Bool
    let isSwitching: Bool

    var body: some View {
        HStack(spacing: DS.Space.m) {
            IconTile(icon: ModeStyle.categoryIcon(mode.category))
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
                DSBadge(text: "Active")
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
                VStack(alignment: .leading, spacing: DS.Space.l) {
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
            .background(DS.Palette.canvas)
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
        VStack(spacing: DS.Space.m) {
            IconTile(icon: ModeStyle.categoryIcon(mode.category),
                     size: 84, prominent: true)
            Text(mode.name)
                .font(DS.Text.title)
                .multilineTextAlignment(.center)
            HStack(spacing: DS.Space.xs) {
                DSBadge(text: ModeStyle.categoryLabel(mode.category),
                        icon: ModeStyle.categoryIcon(mode.category))
                if isActive {
                    DSBadge(text: "Active", filled: true)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, DS.Space.s)
    }

    private var pipelineCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeader("How it runs")
            Label(ModeStyle.pipelineLabel(mode.pipeline),
                  systemImage: ModeStyle.pipelineIcon(mode.pipeline))
                .font(.subheadline.weight(.semibold))
            Text(ModeStyle.pipelineBlurb(mode.pipeline))
                .font(.body)
        }
        .cardStyle()
        .accessibilityElement(children: .combine)
    }

    private var descriptionCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeader("About")
            Text(mode.description)
                .font(.body)
        }
        .cardStyle()
    }

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            DisclosureGroup(isExpanded: $showPrompt) {
                Text(mode.prompt)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, DS.Space.s)
            } label: {
                SectionHeader("What the glasses are told")
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
        .tint(isActive ? DS.Palette.danger : DS.Palette.accent)
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
                await appState.refreshModes()
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
