import SwiftUI
import UIKit

// MARK: - Shared entry presentation (used by History, Search, Recorder)

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

    static func color(for kind: String) -> Color {
        switch kind {
        case "read": return .blue
        case "describe": return .purple
        case "ask": return .orange
        case "recording": return .pink
        case "translate": return .teal
        default: return .gray
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

// MARK: - History list

@MainActor
final class HistoryModel: ObservableObject {
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

struct HistoryView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = HistoryModel()
    @State private var selectedEntry: HistoryEntry?

    var body: some View {
        NavigationStack {
            Group {
                if model.entries.isEmpty {
                    ScrollView {
                        stateView
                            .frame(maxWidth: .infinity)
                            .padding(.top, 100)
                            .padding(.horizontal, 32)
                    }
                    .refreshable { await model.loadFirstPage(client: appState.client) }
                } else {
                    entryList
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("History")
            .sheet(item: $selectedEntry) { entry in
                EntryDetailView(entry: entry)
            }
            .task {
                if model.entries.isEmpty {
                    await model.loadFirstPage(client: appState.client)
                }
            }
        }
    }

    @ViewBuilder
    private var stateView: some View {
        if model.isLoading {
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Loading history…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else if let error = model.loadError {
            VStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
                Text("Couldn't load history")
                    .font(.title3.bold())
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    Task { await model.loadFirstPage(client: appState.client) }
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Nothing here yet")
                    .font(.title3.bold())
                Text("When the glasses read a page, describe a scene, or answer a question, it shows up here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var entryList: some View {
        List {
            ForEach(model.entries) { entry in
                Button {
                    selectedEntry = entry
                } label: {
                    HistoryRow(entry: entry)
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
        .listStyle(.insetGrouped)
        .refreshable { await model.loadFirstPage(client: appState.client) }
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry

    private var firstLine: String {
        let line = entry.text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        return line.isEmpty ? EntryKindStyle.label(for: entry.kind) : line
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(EntryKindStyle.color(for: entry.kind).opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: EntryKindStyle.icon(for: entry.kind))
                    .font(.body.weight(.medium))
                    .foregroundStyle(EntryKindStyle.color(for: entry.kind))
            }
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
        .accessibilityHint("Shows the full text.")
    }
}

// MARK: - Entry detail (shared with Search)

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
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if let question = entry.extra?["question"] {
                        labeledBlock("Question", question, icon: "questionmark.bubble")
                    }
                    labeledBlock(entry.kind == "recording" ? "Transcript" : "Text", entry.text,
                                 icon: "text.alignleft")
                    if let summary = entry.extra?["summary"] {
                        labeledBlock("Summary", summary, icon: "sparkles")
                    }
                    imageSection
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
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
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(EntryKindStyle.color(for: entry.kind).opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: EntryKindStyle.icon(for: entry.kind))
                    .foregroundStyle(EntryKindStyle.color(for: entry.kind))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(TimestampFormat.absolute(entry.ts))
                    .font(.subheadline.weight(.medium))
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

    private func labeledBlock(_ title: String, _ text: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.body)
                .textSelection(.enabled)
        }
        .cardStyle()
    }

    @ViewBuilder
    private var imageSection: some View {
        if entry.hasImage {
            VStack(alignment: .leading, spacing: 8) {
                Label("Photo", systemImage: "photo")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                switch imageState {
                case .loaded:
                    if let image = image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 280)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
