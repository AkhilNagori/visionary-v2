import SwiftUI

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
            .animation(DS.Motion.gentle, value: appState.librarySegment)
        }
        .background(DS.Palette.canvas.ignoresSafeArea())
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
