import SwiftUI

// MARK: - Model

/// A note the glasses queued as a `note` phone action ("take a note…"), saved
/// on the phone from the Actions inbox. Device-local, like everything else.
struct Note: Identifiable, Codable, Equatable {
    let id: UUID
    let createdAt: Date
    var title: String
    var body: String
    /// The phone-action id that minted this note. Guards against saving the
    /// same queued action twice when an acknowledgment doesn't reach the glasses.
    let sourceActionID: Int?

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let firstLine = body
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        return firstLine.isEmpty ? "Note" : firstLine
    }
}

// MARK: - Store

/// Local store for notes: a JSON file in Application Support. No accounts,
/// no cloud — matching the privacy posture of the rest of the app. Shared by
/// NotesView (list/detail) and ActionsInboxView (saving `note` actions).
@MainActor
final class NotesStore: ObservableObject {
    static let shared = NotesStore()

    @Published private(set) var notes: [Note] = []
    @Published private(set) var storeError: String?

    private let fileURL: URL

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(fileURL: URL? = nil) {
        if let fileURL = fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? FileManager.default.temporaryDirectory
            let dir = base.appendingPathComponent("Visionary", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("notes.json")
        }
        load()
    }

    /// Idempotent for a given source action: an ack retry after a WiFi blip
    /// returns the existing note instead of duplicating it.
    @discardableResult
    func add(title: String, body: String, sourceActionID: Int? = nil) -> Note {
        if let sourceActionID = sourceActionID,
           let existing = notes.first(where: { $0.sourceActionID == sourceActionID }) {
            return existing
        }
        let note = Note(id: UUID(), createdAt: Date(), title: title, body: body,
                        sourceActionID: sourceActionID)
        notes.insert(note, at: 0)
        save()
        return note
    }

    func delete(_ note: Note) {
        notes.removeAll { $0.id == note.id }
        save()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            notes = try Self.decoder.decode([Note].self, from: data)
                .sorted { $0.createdAt > $1.createdAt }
        } catch {
            // Move the unreadable file aside so the next save can't clobber it.
            let backup = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            storeError = "Couldn't read saved notes, so the list started fresh. The old file was kept as notes.json.corrupt."
        }
    }

    private func save() {
        do {
            let data = try Self.encoder.encode(notes)
            try data.write(to: fileURL, options: .atomic)
            storeError = nil
        } catch {
            storeError = "Couldn't save notes: \(error.localizedDescription)"
        }
    }
}

// MARK: - Notes list

struct NotesView: View {
    @ObservedObject private var store = NotesStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectedNote: Note?

    private var filtered: [Note] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return store.notes }
        return store.notes.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.body.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.notes.isEmpty {
                    emptyState
                } else {
                    notesList
                }
            }
            .background(DS.Palette.canvas)
            .navigationTitle("Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $selectedNote) { note in
                NoteDetailView(note: note)
            }
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: DS.Space.m) {
                EmptyStateView(
                    icon: "note.text",
                    title: "No notes yet",
                    message: "Say \u{201C}take a note\u{201D} to the glasses, then save it from the Actions inbox."
                )
                if let error = store.storeError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(DS.Text.caption)
                        .foregroundStyle(DS.Palette.attention)
                        .padding(.top, DS.Space.s)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 100)
            .padding(.horizontal, DS.Space.xxl)
        }
    }

    private var notesList: some View {
        List {
            if let error = store.storeError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(DS.Palette.attention)
                }
            }
            Section {
                if filtered.isEmpty {
                    Text("No notes match \u{201C}\(searchText)\u{201D}")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filtered) { note in
                        Button {
                            selectedNote = note
                        } label: {
                            NoteRow(note: note)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Haptics.tap()
                                store.delete(note)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            } footer: {
                Text("Notes live only on this phone.")
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $searchText, prompt: "Search notes")
    }
}

private struct NoteRow: View {
    let note: Note

    private var preview: String {
        note.body
            .split(separator: "\n", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(note.displayTitle)
                .font(.body.weight(.medium))
                .foregroundColor(.primary)
                .lineLimit(1)
            if !preview.isEmpty && preview != note.displayTitle {
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(TimestampFormat.relative(note.createdAt.timeIntervalSince1970))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Note, \(TimestampFormat.relative(note.createdAt.timeIntervalSince1970)). \(note.displayTitle)")
        .accessibilityHint("Shows the full note.")
    }
}

// MARK: - Note detail

private struct NoteDetailView: View {
    let note: Note

    @ObservedObject private var store = NotesStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    private var shareText: String {
        note.body.isEmpty ? note.displayTitle : "\(note.displayTitle)\n\n\(note.body)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if !note.body.isEmpty {
                        VStack(alignment: .leading, spacing: DS.Space.s) {
                            SectionHeader("Note")
                            Text(note.body)
                                .font(.body)
                                .textSelection(.enabled)
                        }
                        .cardStyle()
                    }
                }
                .padding()
            }
            .background(DS.Palette.canvas)
            .navigationTitle(note.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: shareText)
                        .accessibilityLabel("Share this note")
                }
                ToolbarItem(placement: .bottomBar) {
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Delete Note", systemImage: "trash")
                    }
                    .foregroundStyle(.red)
                    .frame(minWidth: 44, minHeight: 44)
                }
            }
            .confirmationDialog("Delete this note?", isPresented: $confirmDelete,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    Haptics.tap()
                    store.delete(note)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It only exists on this phone, so this can't be undone.")
            }
        }
    }

    private var header: some View {
        HStack(spacing: DS.Space.m) {
            IconTile(icon: "note.text", size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(note.displayTitle)
                    .font(.headline)
                Text(TimestampFormat.absolute(note.createdAt.timeIntervalSince1970))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}
