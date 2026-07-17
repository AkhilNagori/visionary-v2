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
    @State private var showPairSplash = false

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
            if showPairSplash {
                PairSuccessSplash()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: appState.paired)
        .animation(.easeInOut(duration: 0.35), value: hasOnboarded)
        .animation(.easeOut(duration: 0.4), value: showPairSplash)
        // The AirPods-style success moment: pairing flips `paired`, and the
        // splash holds the checkmark for a beat before revealing the app.
        .onChange(of: appState.paired) { paired in
            guard paired else { return }
            showPairSplash = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_700_000_000)
                showPairSplash = false
            }
        }
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

/// Full-screen "Connected" beat shown the moment pairing succeeds.
private struct PairSuccessSplash: View {
    @State private var appeared = false

    var body: some View {
        ZStack {
            DS.Palette.canvas.ignoresSafeArea()
            VStack(spacing: DS.Space.xl) {
                ZStack {
                    Circle()
                        .fill(DS.Palette.online.opacity(0.12))
                        .frame(width: 140, height: 140)
                        .scaleEffect(appeared ? 1 : 0.4)
                    Image(systemName: "checkmark")
                        .font(.system(size: 56, weight: .bold))
                        .foregroundStyle(DS.Palette.online)
                        .scaleEffect(appeared ? 1 : 0.2)
                        .opacity(appeared ? 1 : 0)
                }
                VStack(spacing: DS.Space.s) {
                    Text("Connected")
                        .font(DS.Text.hero)
                    Text("Your glasses are ready.")
                        .font(DS.Text.subhead)
                        .foregroundStyle(.secondary)
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 12)
            }
        }
        .onAppear {
            Haptics.success()
            withAnimation(DS.Motion.bouncy) { appeared = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connected. Your glasses are ready.")
    }
}
