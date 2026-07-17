import EventKit
import Foundation

/// Tier 3 agent actions: the glasses queue calendar_event / reminder actions
/// via Claude tool-use; the phone executes them through EventKit and reports
/// done/failed back to the device. Owned and started/stopped by AppState —
/// polls only while the app is active.
@MainActor
final class ActionRunner {
    private let client: APIClient
    private var pollTask: Task<Void, Never>?
    private var store: EKEventStore?
    // Executed but not yet acknowledged to the device (completeAction failed,
    // e.g. WiFi blip). Retried before executing anything new, so an event is
    // never added to the calendar twice.
    private var unreported: [Int: (status: String, result: String)] = [:]

    private static let pollInterval: UInt64 = 10_000_000_000  // ns

    init(client: APIClient) {
        self.client = client
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(nanoseconds: Self.pollInterval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func poll() async {
        for (id, report) in unreported {
            do {
                try await client.completeAction(id: id, status: report.status, result: report.result)
                unreported[id] = nil
            } catch {
                return  // device unreachable; retry the whole batch next cycle
            }
        }
        guard let actions = try? await client.pendingActions() else { return }
        for action in actions {
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
