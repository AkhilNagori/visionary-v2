import SwiftUI

@main
struct VisionaryApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .tint(DS.Palette.accent)
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

    // Three tabs. The device is the hero: live surfaces, the mode picker, and
    // the inbox all launch from Home.
    private var mainTabs: some View {
        TabView(selection: $appState.selectedTab) {
            HomeView()
                .tabItem { Label("Home", systemImage: "eyeglasses") }
                .badge(appState.inboxCount)
                .tag(AppTab.home)
            ActivityView()
                .tabItem { Label("Activity", systemImage: "clock") }
                .tag(AppTab.activity)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
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
            withAnimation(DS.Motion.spring) { appeared = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connected. Your glasses are ready.")
    }
}
