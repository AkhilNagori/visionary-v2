import Combine
import Foundation
import SwiftUI

// MARK: - Navigation

/// Top-level tabs: Home / Activity / Settings. The device is the hero — live
/// surfaces and the mode picker launch from Home, not from tabs of their own.
enum AppTab: Hashable {
    case home, activity, settings
}

@MainActor
final class AppState: ObservableObject {
    @Published var paired: Bool = false
    @Published var status: DeviceStatus?
    @Published var config: DeviceConfig?
    @Published var lastError: String?

    @Published var selectedTab: AppTab = .home

    // v3 mode packs: the active mode id (nil = classic read) plus id → display
    // name, both pulled from GET /modes. The mode picker updates them
    // optimistically after POST /modes/active; the slow poll in refresh()
    // catches switches made by voice on the glasses themselves.
    @Published var activeMode: String?
    @Published var modeNames: [String: String] = [:]

    // Pending actions the phone can't auto-execute (send_text / email_draft /
    // note) — mirrored from ActionRunner for the Home badge and inbox banner.
    @Published var inboxCount: Int = 0

    private(set) var client: APIClient?
    private var refreshTask: Task<Void, Never>?
    private var actionRunner: ActionRunner?
    private var inboxCountSub: AnyCancellable?
    private var isActive = true  // scenes launch active; onChange only fires on transitions
    private var modesTick = 0

    private static let urlKey = "device_url"
    private static let tokenKey = "device_token"
    private static let refreshInterval: UInt64 = 5_000_000_000  // ns
    private static let modesEveryNthRefresh = 6  // ≈ every 30s

    init() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: Self.urlKey),
           let url = URL(string: raw),
           let token = defaults.string(forKey: Self.tokenKey) {
            client = APIClient(baseURL: url, token: token)
            paired = true
        }
    }

    /// Validates the payload by hitting /status; persists and flips `paired` on success.
    @discardableResult
    func pair(payload: PairingPayload) async -> Bool {
        guard let url = URL(string: payload.url), url.scheme != nil else {
            lastError = "That pairing code has an invalid device address."
            return false
        }
        let candidate = APIClient(baseURL: url, token: payload.token)
        do {
            let s = try await candidate.status()
            client = candidate
            status = s
            let defaults = UserDefaults.standard
            defaults.set(payload.url, forKey: Self.urlKey)
            defaults.set(payload.token, forKey: Self.tokenKey)
            lastError = nil
            paired = true
            actionRunner?.stop()
            actionRunner = nil   // old runner holds the old client
            inboxCountSub = nil
            inboxCount = 0
            activeMode = nil
            modeNames = [:]
            reconcileActionRunner()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Starts (or restarts) the background status+config refresh loop.
    func connect() {
        refreshTask?.cancel()
        modesTick = 0   // re-pull /modes promptly after launch or foregrounding
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: Self.refreshInterval)
            }
        }
        reconcileActionRunner()
    }

    /// One refresh pass: /status and /config in parallel, plus /modes when stale.
    func refresh() async {
        guard let client = client else { return }
        do {
            async let s = client.status()
            async let c = client.getConfig()
            status = try await s
            config = try await c
            lastError = nil
        } catch {
            // keep the last known status/config; surface why the refresh failed
            lastError = error.localizedDescription
        }
        if modesTick == 0 { await refreshModes() }
        modesTick = (modesTick + 1) % Self.modesEveryNthRefresh
    }

    /// One /modes pass. Best-effort: the Home card keeps its last known value
    /// when the call fails. Public so ModesView can re-sync after activating a
    /// mode or installing a pack.
    func refreshModes() async {
        guard let client = client,
              let result = try? await client.modes() else { return }
        activeMode = result.activeMode
        modeNames = Dictionary(result.modes.map { ($0.id, $0.name) },
                               uniquingKeysWith: { first, _ in first })
    }

    /// Human-readable name for a mode id; nil is the classic read pipeline.
    /// Falls back to prettifying the id ("explain_10" → "Explain 10") until
    /// /modes has loaded.
    func modeDisplayName(_ id: String?) -> String {
        guard let id = id, !id.isEmpty else { return "Classic Read" }
        if let name = modeNames[id] { return name }
        return id.split(separator: "_").map(\.capitalized).joined(separator: " ")
    }

    func forget() {
        refreshTask?.cancel()
        refreshTask = nil
        actionRunner?.stop()
        actionRunner = nil
        inboxCountSub = nil
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.urlKey)
        defaults.removeObject(forKey: Self.tokenKey)
        client = nil
        status = nil
        config = nil
        lastError = nil
        paired = false
        selectedTab = .home
        activeMode = nil
        modeNames = [:]
        inboxCount = 0
    }

    /// Pauses polling (refresh + action runner) when the app leaves the
    /// foreground; resumes both when it comes back.
    func handleScenePhase(_ phase: ScenePhase) {
        isActive = phase == .active
        if isActive {
            connect()
        } else {
            refreshTask?.cancel()
            refreshTask = nil
            reconcileActionRunner()
        }
    }

    private func reconcileActionRunner() {
        guard paired, isActive, let client = client else {
            actionRunner?.stop()
            return
        }
        if actionRunner == nil {
            let runner = ActionRunner(client: client)
            actionRunner = runner
            // Mirror the badge count; the runner republishes after every poll
            // and whenever ActionsInboxView posts .visionaryActionsDidChange.
            inboxCountSub = runner.$pendingInboxCount
                .sink { [weak self] count in self?.inboxCount = count }
        }
        actionRunner?.start()
    }
}
