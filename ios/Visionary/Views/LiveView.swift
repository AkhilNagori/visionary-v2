import SwiftUI

struct LiveView: View {
    @EnvironmentObject private var appState: AppState
    @State private var streamID = UUID()

    var body: some View {
        NavigationStack {
            Group {
                if let client = appState.client {
                    ScrollView {
                        VStack(spacing: 16) {
                            // .id ties the stream's lifetime to the Restart button:
                            // a new UUID recreates MJPEGView, whose onAppear reconnects
                            MJPEGView(request: client.liveRequest())
                                .id(streamID)
                                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            hintCard
                            privacyNote
                        }
                        .padding()
                    }
                    .background(Color(.systemGroupedBackground))
                } else {
                    unpairedState
                }
            }
            .navigationTitle("Live View")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Haptics.tap()
                        streamID = UUID()
                    } label: {
                        Label("Restart Stream", systemImage: "arrow.clockwise")
                    }
                    .disabled(appState.client == nil)
                    .accessibilityHint("Reconnects the live preview if it stalls.")
                }
            }
        }
    }

    private var hintCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Aiming and focus", systemImage: "camera.viewfinder")
                .font(.headline)
            hintRow(icon: "ruler",
                    text: "Hold reading material 25–35 cm from the glasses — about a forearm's length.")
            hintRow(icon: "camera.metering.center.weighted",
                    text: "Center the text. The camera reads best when the page fills the frame.")
            hintRow(icon: "circle.dashed",
                    text: "Turn the lens ring slowly until small print looks sharp in this preview.")
            hintRow(icon: "timer",
                    text: "The preview runs at about 4 frames per second, so expect a short delay.")
        }
        .cardStyle()
    }

    private func hintRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var privacyNote: some View {
        Label("This preview streams directly from the glasses to your phone and is never recorded.",
              systemImage: "lock.shield")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var unpairedState: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No glasses connected")
                .font(.title3.bold())
            Text("Pair with your Visionary glasses to see their live camera preview.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}
