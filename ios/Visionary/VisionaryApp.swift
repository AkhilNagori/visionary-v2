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
    @AppStorage("has_onboarded") private var hasOnboarded = false

    var body: some View {
        ZStack {
            if appState.paired {
                mainTabs
                    .transition(.opacity)
            } else if hasOnboarded {
                PairingView()
                    .transition(.opacity)
            } else {
                OnboardingView {
                    hasOnboarded = true
                }
                .transition(.asymmetric(
                    insertion: .opacity,
                    removal: .move(edge: .leading).combined(with: .opacity)))
            }
        }
        .animation(.easeInOut(duration: 0.35), value: appState.paired)
        .animation(.easeInOut(duration: 0.35), value: hasOnboarded)
    }

    // v3 tab structure: Home / Library / Live / Modes / Settings.
    private var mainTabs: some View {
        TabView(selection: $appState.selectedTab) {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }
                .badge(appState.inboxCount)
                .tag(AppTab.home)
            LibraryView()
                .tabItem { Label("Library", systemImage: "books.vertical.fill") }
                .tag(AppTab.library)
            LiveTabView()
                .tabItem { Label("Live", systemImage: "video.fill") }
                .tag(AppTab.live)
            ModesView()
                .tabItem { Label("Modes", systemImage: "square.grid.2x2.fill") }
                .tag(AppTab.modes)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
        .onAppear { appState.connect() }
    }
}
