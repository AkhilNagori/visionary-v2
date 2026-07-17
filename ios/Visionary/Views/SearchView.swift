import SwiftUI

@MainActor
final class SearchModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var hits: [MemoryHit]?
    @Published private(set) var isSearching = false
    @Published private(set) var searchError: String?
    @Published private(set) var lastQuery = ""

    private var task: Task<Void, Never>?

    func run(client: APIClient?) {
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

    func cancelInFlight() {
        task?.cancel()
        isSearching = false
    }
}

struct SearchView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = SearchModel()
    @State private var selectedEntry: HistoryEntry?

    private static let suggestions = [
        "What room number was on that door?",
        "gluten-free menu item",
        "homework due date",
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                content
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Search")
            .scrollDismissesKeyboard(.interactively)
            .sheet(item: $selectedEntry) { entry in
                EntryDetailView(entry: entry)
            }
            .onDisappear { model.cancelInFlight() }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("What room number was on that door?", text: $model.query)
                .submitLabel(.search)
                .onSubmit { model.run(client: appState.client) }
                .accessibilityLabel("Search your visual memory")
                .accessibilityHint("Searches everything the glasses have read, described, or answered.")
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                    model.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, model.query.isEmpty ? DS.Space.m : 2)
        .background(
            DS.Palette.card,
            in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
        )
    }

    @ViewBuilder
    private var content: some View {
        if model.isSearching {
            centered {
                LoadingStateView(label: "Searching your memory…")
            }
        } else if let error = model.searchError {
            centered {
                EmptyStateView(
                    icon: "exclamationmark.triangle",
                    tint: DS.Palette.attention,
                    title: "Search didn't go through",
                    message: error,
                    actionTitle: "Try Again"
                ) { model.run(client: appState.client) }
            }
        } else if let hits = model.hits {
            if hits.isEmpty {
                centered {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        tint: DS.Palette.memory,
                        title: "No matches for \u{201C}\(model.lastQuery)\u{201D}",
                        message: "Try different words — search covers everything the glasses have spoken aloud."
                    )
                }
            } else {
                resultsList(hits)
            }
        } else {
            idleState
        }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
                .padding(.horizontal, 32)
        }
    }

    private var idleState: some View {
        ScrollView {
            VStack(spacing: DS.Space.l) {
                EmptyStateView(
                    icon: "sparkle.magnifyingglass",
                    tint: DS.Palette.memory,
                    title: "Your visual memory",
                    message: "Everything the glasses read, describe, or answer becomes searchable — even from days ago. Search works offline, too."
                )
                VStack(spacing: DS.Space.s) {
                    ForEach(Self.suggestions, id: \.self) { suggestion in
                        Button {
                            Haptics.selection()
                            model.query = suggestion
                            model.run(client: appState.client)
                        } label: {
                            Text("\u{201C}\(suggestion)\u{201D}")
                                .font(DS.Text.subhead)
                                .padding(.horizontal, DS.Space.l)
                                .padding(.vertical, 10)
                                .background(
                                    Capsule().strokeBorder(Color.accentColor.opacity(0.4))
                                )
                        }
                        .buttonStyle(.pressable)
                        .accessibilityHint("Runs this example search.")
                    }
                }
                .padding(.top, DS.Space.xs)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
            .padding(.horizontal, DS.Space.xxl)
        }
    }

    private func resultsList(_ hits: [MemoryHit]) -> some View {
        let maxScore = hits.map(\.score).max() ?? 0
        return List {
            Section {
                ForEach(hits, id: \.entry.id) { hit in
                    Button {
                        selectedEntry = hit.entry
                    } label: {
                        SearchHitRow(hit: hit, relevance: normalized(hit.score, maxScore: maxScore))
                    }
                }
            } footer: {
                Text("Ranked by relevance across everything the glasses have read, described, and answered.")
            }
        }
        .listStyle(.insetGrouped)
    }

    private func normalized(_ score: Double, maxScore: Double) -> Double {
        // FTS5 fallback scores aren't 0–1, so rank relative to the best hit
        guard maxScore > 0 else { return 1 }
        return max(0, min(1, score / maxScore))
    }
}

private struct SearchHitRow: View {
    let hit: MemoryHit
    let relevance: Double

    private var snippet: String {
        let line = hit.entry.text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        return line.isEmpty ? EntryKindStyle.label(for: hit.entry.kind) : line
    }

    private var relevanceWord: String {
        relevance > 0.75 ? "high" : (relevance > 0.4 ? "medium" : "low")
    }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.accentColor.opacity(0.3 + 0.7 * relevance))
                .frame(width: 4, height: 40)
            IconTile(icon: EntryKindStyle.icon(for: hit.entry.kind),
                     tint: EntryKindStyle.color(for: hit.entry.kind))
            VStack(alignment: .leading, spacing: 3) {
                Text(snippet)
                    .font(.body)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                Text("\(EntryKindStyle.label(for: hit.entry.kind)) · \(TimestampFormat.relative(hit.entry.ts))")
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
        .accessibilityLabel("\(EntryKindStyle.label(for: hit.entry.kind)), \(TimestampFormat.relative(hit.entry.ts)), \(relevanceWord) relevance. \(snippet)")
        .accessibilityHint("Shows the full entry.")
    }
}
