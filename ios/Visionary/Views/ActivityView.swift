import SwiftUI
import UIKit

// MARK: - Shared entry presentation

enum EntryKindStyle {
    static func icon(for kind: String) -> String {
        switch kind {
        case "read": return "text.viewfinder"
        case "describe": return "eye"
        case "ask": return "questionmark.bubble"
        case "recording": return "waveform"
        case "translate": return "globe"
        default: return "sparkles"
        }
    }

    static func label(for kind: String) -> String {
        switch kind {
        case "read": return "Read"
        case "describe": return "Description"
        case "ask": return "Question"
        case "recording": return "Recording"
        case "translate": return "Translation"
        default: return kind.capitalized
        }
    }
}

enum TimestampFormat {
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    static func relative(_ ts: Double) -> String {
        let date = Date(timeIntervalSince1970: ts)
        if Date().timeIntervalSince(date) < 60 { return "Just now" }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    static func absolute(_ ts: Double) -> String {
        Date(timeIntervalSince1970: ts).formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Timeline model

@MainActor
final class ActivityModel: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []
    @Published private(set) var isLoading = false
    @Published var loadError: String?

    private var nextPage = 1
    private var total = Int.max
    private var fetched = 0

    var hasMore: Bool { fetched < total }

    func loadFirstPage(client: APIClient?) async {
        nextPage = 1
        total = Int.max
        fetched = 0
        await loadNextPage(client: client, replace: true)
    }

    func loadNextPage(client: APIClient?, replace: Bool = false) async {
        guard let client = client, !isLoading, replace || hasMore else { return }
        isLoading = true
        loadError = nil
        do {
            let page = try await client.history(page: nextPage)
            nextPage += 1
            fetched += page.entries.count
            total = page.entries.isEmpty ? fetched : page.total
            if replace {
                entries = page.entries
            } else {
                let known = Set(entries.map(\.id))
                entries.append(contentsOf: page.entries.filter { !known.contains($0.id) })
            }
        } catch {
            if !Task.isCancelled { loadError = error.localizedDescription }
        }
        isLoading = false
    }
}

// MARK: - Memory search model

@MainActor
final class SearchModel: ObservableObject {
    @Published private(set) var hits: [MemoryHit]?
    @Published private(set) var isSearching = false
    @Published private(set) var searchError: String?
    @Published private(set) var lastQuery = ""

    private var task: Task<Void, Never>?

    func run(_ query: String, client: APIClient?) {
        task?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let client = client else { return }
        isSearching = true
        searchError = nil
        lastQuery = q
        task = Task {
            do {
                let results = try await client.memorySearch(q, k: 12)
                if !Task.isCancelled {
                    hits = results
                    isSearching = false
                }
            } catch {
                if !Task.isCancelled {
                    searchError = error.localizedDescription
                    isSearching = false
                }
            }
        }
    }

    func clear() {
        task?.cancel()
        hits = nil
        searchError = nil
        isSearching = false
        lastQuery = ""
    }
}

// MARK: - Activity tab

/// One timeline for everything the glasses have captured — reads, scene
/// descriptions, questions, recordings, translations — with memory search on
/// top and Flashcards / Notes a row away.
struct ActivityView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = ActivityModel()
    @StateObject private var search = SearchModel()

    @State private var query = ""
    @State private var selectedEntry: HistoryEntry?
    @State private var showFlashcards = false
    @State private var showNotes = false

    private var isSearchMode: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            content
                .background(DS.Palette.canvas)
                .navigationTitle("Activity")
                .searchable(text: $query,
                            placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Search everything the glasses saw")
                .onSubmit(of: .search) { search.run(query, client: appState.client) }
                .onChange(of: query) { newValue in
                    if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        search.clear()
                    }
                }
                .sheet(item: $selectedEntry) { entry in
                    if entry.kind == "recording" {
                        RecordingDetailView(entry: entry)
                    } else {
                        EntryDetailView(entry: entry)
                    }
                }
                .sheet(isPresented: $showFlashcards) { FlashcardsView() }
                .sheet(isPresented: $showNotes) { NotesView() }
                .task {
                    if model.entries.isEmpty {
                        await model.loadFirstPage(client: appState.client)
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isSearchMode {
            searchContent
        } else {
            timelineContent
        }
    }

    // MARK: - Timeline

    @ViewBuilder
    private var timelineContent: some View {
        if model.entries.isEmpty {
            ScrollView {
                timelineStateView
                    .frame(maxWidth: .infinity)
                    .padding(.top, 100)
                    .padding(.horizontal, DS.Space.xxl)
            }
            .refreshable { await model.loadFirstPage(client: appState.client) }
        } else {
            List {
                collectionsSection
                Section {
                    ForEach(model.entries) { entry in
                        Button {
                            selectedEntry = entry
                        } label: {
                            TimelineRow(entry: entry)
                        }
                        .onAppear {
                            if entry.id == model.entries.last?.id {
                                Task { await model.loadNextPage(client: appState.client) }
                            }
                        }
                    }
                    if model.hasMore {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await model.loadFirstPage(client: appState.client) }
        }
    }

    private var collectionsSection: some View {
        Section {
            collectionRow(icon: "rectangle.on.rectangle.angled",
                          title: "Flashcards",
                          subtitle: "Review what the glasses read") {
                showFlashcards = true
            }
            .accessibilityHint("Opens flashcard review.")
            collectionRow(icon: "note.text",
                          title: "Notes",
                          subtitle: "Captured by voice, saved on this phone") {
                showNotes = true
            }
            .accessibilityHint("Opens your notes.")
        }
    }

    private func collectionRow(icon: String, title: String, subtitle: String,
                               action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: DS.Space.m) {
                IconTile(icon: icon)
                VStack(alignment: .leading, spacing: 2) {
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
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private var timelineStateView: some View {
        if model.isLoading {
            LoadingStateView(label: "Loading activity…")
        } else if let error = model.loadError {
            EmptyStateView(
                icon: "wifi.exclamationmark",
                title: "Couldn't load activity",
                message: error,
                actionTitle: "Try Again"
            ) {
                Task { await model.loadFirstPage(client: appState.client) }
            }
        } else {
            EmptyStateView(
                icon: "clock",
                title: "Nothing here yet",
                message: "Everything the glasses read, describe, or record lands here."
            )
        }
    }

    // MARK: - Search

    @ViewBuilder
    private var searchContent: some View {
        if search.isSearching {
            ScrollView {
                LoadingStateView(label: "Searching your memory…")
                    .padding(.top, 100)
                    .padding(.horizontal, DS.Space.xxl)
            }
        } else if let error = search.searchError {
            ScrollView {
                EmptyStateView(
                    icon: "exclamationmark.triangle",
                    title: "Search didn't go through",
                    message: error,
                    actionTitle: "Try Again"
                ) { search.run(query, client: appState.client) }
                    .padding(.top, 100)
                    .padding(.horizontal, DS.Space.xxl)
            }
        } else if let hits = search.hits {
            if hits.isEmpty {
                ScrollView {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        title: "No matches for \u{201C}\(search.lastQuery)\u{201D}",
                        message: "Try different words — search covers everything the glasses have spoken aloud."
                    )
                    .padding(.top, 100)
                    .padding(.horizontal, DS.Space.xxl)
                }
            } else {
                List {
                    Section {
                        ForEach(hits, id: \.entry.id) { hit in
                            Button {
                                selectedEntry = hit.entry
                            } label: {
                                TimelineRow(entry: hit.entry)
                            }
                        }
                    } footer: {
                        Text("Ranked by relevance across everything the glasses have read, described, and answered.")
                    }
                }
                .listStyle(.insetGrouped)
            }
        } else {
            ScrollView {
                EmptyStateView(
                    icon: "sparkle.magnifyingglass",
                    title: "Search your visual memory",
                    message: "Press return to search everything the glasses have seen — even from days ago."
                )
                .padding(.top, 100)
                .padding(.horizontal, DS.Space.xxl)
            }
        }
    }
}

// MARK: - Timeline row

private struct TimelineRow: View {
    let entry: HistoryEntry

    private var firstLine: String {
        let line = entry.text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        return line.isEmpty ? EntryKindStyle.label(for: entry.kind) : line
    }

    var body: some View {
        HStack(spacing: DS.Space.m) {
            IconTile(icon: EntryKindStyle.icon(for: entry.kind))
            VStack(alignment: .leading, spacing: 3) {
                Text(firstLine)
                    .font(.body)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Text(EntryKindStyle.label(for: entry.kind))
                    Text("·")
                    Text(TimestampFormat.relative(entry.ts))
                    if entry.hasImage {
                        Image(systemName: "photo").font(.caption2)
                    }
                    if entry.hasAudio {
                        Image(systemName: "waveform").font(.caption2)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(EntryKindStyle.label(for: entry.kind)), \(TimestampFormat.relative(entry.ts)). \(firstLine)")
        .accessibilityHint("Shows the full entry.")
    }
}

// MARK: - Entry detail

struct EntryDetailView: View {
    let entry: HistoryEntry

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private enum ImageState { case idle, loading, loaded, unavailable }
    @State private var image: UIImage?
    @State private var imageState: ImageState = .idle

    private var shareText: String {
        var parts: [String] = []
        if let question = entry.extra?["question"] {
            parts.append("Question: \(question)")
        }
        parts.append(entry.text)
        if let summary = entry.extra?["summary"] {
            parts.append("Summary: \(summary)")
        }
        return parts.joined(separator: "\n\n")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    header
                    if let question = entry.extra?["question"] {
                        labeledBlock("Question", question)
                    }
                    labeledBlock(entry.kind == "recording" ? "Transcript" : "Text", entry.text)
                    if let summary = entry.extra?["summary"] {
                        labeledBlock("Summary", summary)
                    }
                    imageSection
                }
                .padding()
            }
            .background(DS.Palette.canvas)
            .navigationTitle(EntryKindStyle.label(for: entry.kind))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: shareText)
                        .accessibilityLabel("Share this entry")
                }
            }
            .task { await loadImage() }
        }
    }

    private var header: some View {
        HStack(spacing: DS.Space.m) {
            IconTile(icon: EntryKindStyle.icon(for: entry.kind), size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(TimestampFormat.absolute(entry.ts))
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                if let language = entry.extra?["language"] {
                    Text("Translated to \(language)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private func labeledBlock(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeader(title)
            Text(text)
                .font(.body)
                .textSelection(.enabled)
        }
        .cardStyle()
    }

    @ViewBuilder
    private var imageSection: some View {
        if entry.hasImage {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                SectionHeader("Photo")
                switch imageState {
                case .loaded:
                    if let image = image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 280)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                            .accessibilityLabel("Photo the glasses captured for this entry")
                    }
                case .unavailable:
                    Label("Photo couldn't be loaded", systemImage: "photo.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                default:
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .frame(height: 120)
                }
            }
            .cardStyle()
        }
    }

    private func loadImage() async {
        guard entry.hasImage, image == nil, let client = appState.client else { return }
        imageState = .loading
        do {
            if let loaded = try await client.image(id: entry.id) {
                image = loaded
                imageState = .loaded
            } else {
                imageState = .unavailable
            }
        } catch {
            if !Task.isCancelled { imageState = .unavailable }
        }
    }
}
