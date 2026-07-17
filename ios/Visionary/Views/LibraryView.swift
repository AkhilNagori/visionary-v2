import SwiftUI

/// Segmented control that falls back to a menu at accessibility type sizes,
/// where several segments can't render legibly. Shared by the Library and
/// Live tabs.
struct SegmentPicker<Option: Hashable>: View {
    let title: String
    let options: [Option]
    let label: (Option) -> String
    @Binding var selection: Option

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                Picker(title, selection: $selection) {
                    ForEach(options, id: \.self) { option in
                        Text(label(option)).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            } else {
                Picker(title, selection: $selection) {
                    ForEach(options, id: \.self) { option in
                        Text(label(option)).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .onChange(of: selection) { _ in Haptics.selection() }
    }
}

/// Library tab: everything the glasses have captured, in one place —
/// History / Search / Recorder / Flashcards / Notes. The segments are the
/// existing full screens, kept alive behind the switcher so scroll positions,
/// search queries, and audio playback survive segment hops.
struct LibraryView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            SegmentPicker(
                title: "Library section",
                options: LibrarySegment.allCases,
                label: Self.label(for:),
                selection: $appState.librarySegment
            )
            .padding(.horizontal)
            .padding(.vertical, 8)

            ZStack {
                pane(.history) { HistoryView() }
                pane(.search) { SearchView() }
                pane(.recorder) { RecorderView() }
                pane(.flashcards) { FlashcardsView() }
                pane(.notes) { NotesView() }
            }
            .animation(.easeInOut(duration: 0.15), value: appState.librarySegment)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    private func pane<Content: View>(_ segment: LibrarySegment,
                                     @ViewBuilder content: () -> Content) -> some View {
        let selected = appState.librarySegment == segment
        return content()
            .opacity(selected ? 1 : 0)
            .allowsHitTesting(selected)
            .accessibilityHidden(!selected)
    }

    private static func label(for segment: LibrarySegment) -> String {
        switch segment {
        case .history: return "History"
        case .search: return "Search"
        case .recorder: return "Recorder"
        case .flashcards: return "Cards"
        case .notes: return "Notes"
        }
    }
}
