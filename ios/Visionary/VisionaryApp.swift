import SwiftUI

@main
struct VisionaryApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .onChange(of: scenePhase) { phase in
                    appState.handleScenePhase(phase)
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if appState.paired {
            TabView {
                HomeView()
                    .tabItem { Label("Home", systemImage: "house.fill") }
                HistoryView()
                    .tabItem { Label("History", systemImage: "clock.fill") }
                SearchView()
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                LiveView()
                    .tabItem { Label("Live", systemImage: "video.fill") }
                RecorderView()
                    .tabItem { Label("Recorder", systemImage: "waveform") }
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape.fill") }
            }
            .onAppear { appState.connect() }
        } else {
            PairingView()
        }
    }
}
