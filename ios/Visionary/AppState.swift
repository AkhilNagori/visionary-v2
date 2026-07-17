import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var paired: Bool = false
    @Published var status: DeviceStatus?
    @Published var config: DeviceConfig?
    @Published var lastError: String?

    private(set) var client: APIClient?
    private var refreshTask: Task<Void, Never>?
    private var actionRunner: ActionRunner?
    private var isActive = true  // scenes launch active; onChange only fires on transitions

    private static let urlKey = "device_url"
    private static let tokenKey = "device_token"
    private static let refreshInterval: UInt64 = 5_000_000_000  // ns

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
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: Self.refreshInterval)
            }
        }
        reconcileActionRunner()
    }

    /// One refresh pass: pulls /status and /config in parallel.
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
    }

    func forget() {
        refreshTask?.cancel()
        refreshTask = nil
        actionRunner?.stop()
        actionRunner = nil
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.urlKey)
        defaults.removeObject(forKey: Self.tokenKey)
        client = nil
        status = nil
        config = nil
        lastError = nil
        paired = false
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
            actionRunner = ActionRunner(client: client)
        }
        actionRunner?.start()
    }
}
