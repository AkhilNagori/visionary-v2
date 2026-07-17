import SwiftUI

/// Live tab: Live preview / Captions / Guide. Unlike Library, the segments are
/// torn down on switch (a plain `switch`, not a hidden ZStack) so only one
/// stream — MJPEG or the /events SSE connection — is ever held open against
/// the Pi at a time.
struct LiveTabView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            SegmentPicker(
                title: "Live section",
                options: LiveSegment.allCases,
                label: Self.label(for:),
                selection: $appState.liveSegment
            )
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch appState.liveSegment {
            case .live: LiveView()
            case .captions: CaptionsView()
            case .guide: GuideView()
            }
        }
        .background(DS.Palette.canvas.ignoresSafeArea())
    }

    private static func label(for segment: LiveSegment) -> String {
        switch segment {
        case .live: return "Live"
        case .captions: return "Captions"
        case .guide: return "Guide"
        }
    }
}
