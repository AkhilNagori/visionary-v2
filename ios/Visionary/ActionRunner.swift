import Combine
import EventKit
import Foundation

extension Notification.Name {
    /// Posted when the phone changes the device's action queue outside this
    /// runner (the Actions inbox completing a send_text / email_draft / note),
    /// so the badge count refreshes without waiting for the next poll.
    static let visionaryActionsDidChange = Notification.Name("visionaryActionsDidChange")
}

/// Tier 3 agent actions: the glasses queue phone actions via Claude tool-use.
/// The phone auto-executes ONLY calendar_event / reminder through EventKit and
/// reports done/failed back to the device. send_text / email_draft / note can't
/// be auto-sent by iOS — those stay pending on the device and surface here as
/// `pendingInboxCount` for the Actions-inbox badge; ActionsInboxView owns
/// executing and completing them. Owned and started/stopped by AppState —
/// polls only while the app is active.
@MainActor
final class ActionRunner: ObservableObject {
    /// Pending actions waiting in the in-app Actions inbox (the badge count).
    @Published private(set) var pendingInboxCount = 0

    /// Action types the phone hands to the user instead of auto-executing.
    static let inboxTypes: Set<String> = ["send_text", "email_draft", "note"]

    private let client: APIClient
    private var pollTask: Task<Void, Never>?
    private var changeObserver: NSObjectProtocol?
    private var store: EKEventStore?
    // Executed but not yet acknowledged to the device (completeAction failed,
    // e.g. WiFi blip). Retried before executing anything new, so an event is
    // never added to the calendar twice.
    private var unreported: [Int: (status: String, result: String)] = [:]
    // Notification-triggered polls can land mid-poll; coalesce instead of
    // interleaving two passes over the same pending queue.
    private var isPolling = false
    private var needsRepoll = false

    private static let pollInterval: UInt64 = 10_000_000_000  // ns

    init(client: APIClient) {
        self.client = client
    }

    func start() {
        if pollTask == nil {
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.poll()
                    try? await Task.sleep(nanoseconds: Self.pollInterval)
                }
            }
        }
        if changeObserver == nil {
            changeObserver = NotificationCenter.default.addObserver(
                forName: .visionaryActionsDidChange, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.poll() }
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        if let changeObserver = changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
        changeObserver = nil
    }

    private func poll() async {
        if isPolling {
            needsRepoll = true
            return
        }
        isPolling = true
        defer { isPolling = false }
        repeat {
            needsRepoll = false
            await pollOnce()
        } while needsRepoll
    }

    private func pollOnce() async {
        for (id, report) in unreported {
            do {
                try await client.completeAction(id: id, status: report.status, result: report.result)
                unreported[id] = nil
            } catch {
                return  // device unreachable; retry the whole batch next cycle
            }
        }
        guard let actions = try? await client.pendingActions() else { return }
        // Inbox types are never auto-executed — only counted for the badge.
        pendingInboxCount = actions.filter { Self.inboxTypes.contains($0.type) }.count
        for action in actions where !Self.inboxTypes.contains(action.type) {
            if Task.isCancelled { return }
            let (status, result) = await execute(action)
            do {
                try await client.completeAction(id: action.id, status: status, result: result)
            } catch {
                unreported[action.id] = (status, result)
            }
        }
    }

    private func execute(_ action: PhoneAction) async -> (String, String) {
        switch action.type {
        case "calendar_event": return await addCalendarEvent(action.payload)
        case "reminder": return await addReminder(action.payload)
        default: return ("failed", "Unsupported action type: \(action.type)")
        }
    }

    // MARK: - EventKit

    private func addCalendarEvent(_ payload: [String: String]) async -> (String, String) {
        guard let title = payload["title"], !title.isEmpty else {
            return ("failed", "Missing event title")
        }
        guard let raw = payload["date"], let date = Self.parseDate(raw) else {
            return ("failed", "Missing or unreadable event date")
        }
        guard await requestAccess(.event) else {
            return ("failed", "Calendar access denied")
        }
        let store = eventStore()
        guard let calendar = store.defaultCalendarForNewEvents else {
            return ("failed", "No default calendar available")
        }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = date
        event.endDate = date.addingTimeInterval(3600)
        event.notes = payload["notes"]
        event.calendar = calendar
        do {
            try store.save(event, span: .thisEvent, commit: true)
            return ("done", "Added \"\(title)\" to Calendar")
        } catch {
            return ("failed", "Calendar save failed: \(error.localizedDescription)")
        }
    }

    private func addReminder(_ payload: [String: String]) async -> (String, String) {
        guard let title = payload["title"], !title.isEmpty else {
            return ("failed", "Missing reminder title")
        }
        guard await requestAccess(.reminder) else {
            return ("failed", "Reminders access denied")
        }
        let store = eventStore()
        guard let calendar = store.defaultCalendarForNewReminders() else {
            return ("failed", "No default reminders list available")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = payload["notes"]
        reminder.calendar = calendar
        do {
            try store.save(reminder, commit: true)
            return ("done", "Added reminder \"\(title)\"")
        } catch {
            return ("failed", "Reminder save failed: \(error.localizedDescription)")
        }
    }

    private func eventStore() -> EKEventStore {
        if let store = store { return store }
        let s = EKEventStore()
        store = s
        return s
    }

    private func requestAccess(_ type: EKEntityType) async -> Bool {
        let store = eventStore()
        let granted: Bool
        if #available(iOS 17.0, *) {
            granted = (try? await (type == .event
                ? store.requestFullAccessToEvents()
                : store.requestFullAccessToReminders())) ?? false
        } else {
            granted = await legacyRequestAccess(store, type)
        }
        // a store created before the grant may not see sources until refreshed
        if granted { store.reset() }
        return granted
    }

    @available(iOS, deprecated: 17.0)
    private func legacyRequestAccess(_ store: EKEventStore, _ type: EKEntityType) async -> Bool {
        (try? await store.requestAccess(to: type)) ?? false
    }

    /// Accepts full ISO8601 (with or without fractional seconds), a naive
    /// local datetime, or a bare date — flyers rarely spell out time zones.
    private static func parseDate(_ raw: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: raw) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: raw) { return d }
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = format
            if let d = f.date(from: raw) { return d }
        }
        return nil
    }
}
