import MessageUI
import SwiftUI
import UIKit

// MARK: - Row presentation

private enum InboxStyle {
    static func icon(for type: String) -> String {
        switch type {
        case "send_text": return "message"
        case "email_draft": return "envelope"
        case "note": return "note.text"
        default: return "tray"
        }
    }

    static func label(for type: String) -> String {
        switch type {
        case "send_text": return "Text message"
        case "email_draft": return "Email draft"
        case "note": return "Note"
        default: return type.capitalized
        }
    }
}

// MARK: - Model

/// Pending send_text / email_draft / note actions the glasses queued. iOS
/// can't auto-send messages or mail, so each one waits here for a one-tap
/// review; notes save straight into the local Notes store.
@MainActor
final class ActionsInboxModel: ObservableObject {
    private struct Ack: Codable {
        let status: String
        let result: String
    }

    @Published private(set) var actions: [PhoneAction] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    private var hasLoaded = false
    var needsInitialLoad: Bool { !hasLoaded }

    /// Completions the glasses haven't acknowledged yet (WiFi blip after the
    /// user already sent the text). Persisted so re-opening the inbox never
    /// offers to send the same message twice.
    private var unacked: [Int: Ack] = ActionsInboxModel.loadUnacked()
    private static let unackedKey = "actions_inbox_unacked"

    func load(client: APIClient?) async {
        guard let client = client, !isLoading else { return }
        isLoading = true
        loadError = nil
        await retryAcks(client: client)
        do {
            let pending = try await client.pendingActions()
            actions = pending
                .filter { ActionRunner.inboxTypes.contains($0.type) && unacked[$0.id] == nil }
                .sorted { $0.ts > $1.ts }
            hasLoaded = true
        } catch {
            if !Task.isCancelled { loadError = error.localizedDescription }
        }
        isLoading = false
    }

    /// Removes the row immediately and reports to the glasses; a failed report
    /// is queued and retried so the device queue eventually converges.
    func complete(_ action: PhoneAction, status: String, result: String, client: APIClient?) async {
        actions.removeAll { $0.id == action.id }
        defer { NotificationCenter.default.post(name: .visionaryActionsDidChange, object: nil) }
        guard let client = client else {
            unacked[action.id] = Ack(status: status, result: result)
            Self.saveUnacked(unacked)
            return
        }
        do {
            try await client.completeAction(id: action.id, status: status, result: result)
        } catch APIError.http(404) {
            // already completed elsewhere — nothing to report
        } catch {
            unacked[action.id] = Ack(status: status, result: result)
            Self.saveUnacked(unacked)
        }
    }

    private func retryAcks(client: APIClient) async {
        guard !unacked.isEmpty else { return }
        for (id, ack) in unacked {
            do {
                try await client.completeAction(id: id, status: ack.status, result: ack.result)
                unacked[id] = nil
            } catch APIError.http(404) {
                unacked[id] = nil   // the device already dropped it
            } catch {
                break               // unreachable; retry on the next load
            }
        }
        Self.saveUnacked(unacked)
    }

    private static func loadUnacked() -> [Int: Ack] {
        guard let data = UserDefaults.standard.data(forKey: unackedKey),
              let decoded = try? JSONDecoder().decode([Int: Ack].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func saveUnacked(_ value: [Int: Ack]) {
        if value.isEmpty {
            UserDefaults.standard.removeObject(forKey: unackedKey)
        } else if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: unackedKey)
        }
    }
}

// MARK: - Inbox view

struct ActionsInboxView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = ActionsInboxModel()

    @State private var composerRoute: ComposerRoute?
    @State private var fallback: Fallback?

    var body: some View {
        NavigationStack {
            Group {
                if model.actions.isEmpty {
                    ScrollView {
                        stateView
                            .frame(maxWidth: .infinity)
                            .padding(.top, 100)
                            .padding(.horizontal, 32)
                    }
                    .refreshable { await model.load(client: appState.client) }
                } else {
                    actionList
                }
            }
            .background(DS.Palette.canvas)
            .navigationTitle("Actions")
            .task {
                if model.needsInitialLoad {
                    await model.load(client: appState.client)
                }
            }
            .sheet(item: $composerRoute) { route in
                composerSheet(route)
            }
            .alert("Can't send from this phone",
                   isPresented: fallbackBinding,
                   presenting: fallback) { f in
                Button(f.kind == .text ? "Copy Message" : "Copy Draft") { copy(f) }
                Button("Discard", role: .destructive) { discard(f.action) }
                Button("Cancel", role: .cancel) {}
            } message: { f in
                Text(f.kind == .text
                     ? "This device can't send text messages. Copy the message to send it another way, or discard it."
                     : "No email account is set up in Mail. Copy the draft to send it another way, or discard it.")
            }
        }
    }

    private var fallbackBinding: Binding<Bool> {
        Binding(get: { fallback != nil }, set: { if !$0 { fallback = nil } })
    }

    // MARK: States

    @ViewBuilder
    private var stateView: some View {
        if model.isLoading {
            LoadingStateView(label: "Checking with the glasses…")
        } else if let error = model.loadError {
            EmptyStateView(
                icon: "wifi.exclamationmark",
                title: "Couldn't load actions",
                message: error,
                actionTitle: "Try Again"
            ) {
                Task { await model.load(client: appState.client) }
            }
        } else {
            EmptyStateView(
                icon: "tray",
                title: "Inbox zero",
                message: "Texts, emails, and notes from the glasses wait here for your OK."
            )
        }
    }

    private var actionList: some View {
        List {
            Section {
                ForEach(model.actions) { action in
                    Button {
                        handleTap(action)
                    } label: {
                        InboxRow(action: action)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            discard(action)
                        } label: {
                            Label("Discard", systemImage: "trash")
                        }
                    }
                }
            } footer: {
                Text("iOS doesn't let apps send texts or email on their own — review each one here, then send with a tap. Notes save straight to the Notes list.")
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await model.load(client: appState.client) }
    }

    // MARK: Actions

    private func handleTap(_ action: PhoneAction) {
        Haptics.tap()
        switch action.type {
        case "send_text":
            if MFMessageComposeViewController.canSendText() {
                composerRoute = .text(action)
            } else {
                fallback = Fallback(action: action, kind: .text)
            }
        case "email_draft":
            if MFMailComposeViewController.canSendMail() {
                composerRoute = .mail(action)
            } else {
                fallback = Fallback(action: action, kind: .mail)
            }
        case "note":
            saveNote(action)
        default:
            break
        }
    }

    private func saveNote(_ action: PhoneAction) {
        NotesStore.shared.add(title: action.payload["title"] ?? "",
                              body: action.payload["body"] ?? "",
                              sourceActionID: action.id)
        Haptics.success()
        UIAccessibility.post(notification: .announcement, argument: "Saved to Notes")
        Task {
            await model.complete(action, status: "done",
                                 result: "Saved to Notes on the phone",
                                 client: appState.client)
        }
    }

    private func discard(_ action: PhoneAction) {
        Haptics.tap()
        Task {
            await model.complete(action, status: "failed",
                                 result: "Dismissed on the phone",
                                 client: appState.client)
        }
    }

    private func copy(_ f: Fallback) {
        switch f.kind {
        case .text:
            UIPasteboard.general.string = f.action.payload["body"] ?? ""
        case .mail:
            let subject = f.action.payload["subject"] ?? ""
            let body = f.action.payload["body"] ?? ""
            UIPasteboard.general.string = subject.isEmpty ? body : "\(subject)\n\n\(body)"
        }
        Haptics.success()
        UIAccessibility.post(notification: .announcement, argument: "Copied")
    }

    // MARK: Composers

    @ViewBuilder
    private func composerSheet(_ route: ComposerRoute) -> some View {
        switch route {
        case .text(let action):
            MessageComposer(recipient: action.payload["to"],
                            body: action.payload["body"] ?? "") { result in
                composerRoute = nil
                switch result {
                case .sent:
                    Haptics.success()
                    Task {
                        await model.complete(action, status: "done",
                                             result: "Sent from the phone",
                                             client: appState.client)
                    }
                case .failed:
                    Haptics.error()
                    Task {
                        await model.complete(action, status: "failed",
                                             result: "Message failed to send",
                                             client: appState.client)
                    }
                default:
                    break   // cancelled: stays in the inbox
                }
            }
            .ignoresSafeArea()
        case .mail(let action):
            MailComposer(recipient: action.payload["to"],
                         subject: action.payload["subject"] ?? "",
                         body: action.payload["body"] ?? "") { result in
                composerRoute = nil
                switch result {
                case .sent:
                    Haptics.success()
                    Task {
                        await model.complete(action, status: "done",
                                             result: "Emailed from the phone",
                                             client: appState.client)
                    }
                case .saved:
                    Haptics.success()
                    Task {
                        await model.complete(action, status: "done",
                                             result: "Saved as a draft in Mail",
                                             client: appState.client)
                    }
                case .failed:
                    Haptics.error()
                    Task {
                        await model.complete(action, status: "failed",
                                             result: "Mail failed to send",
                                             client: appState.client)
                    }
                default:
                    break   // cancelled: stays in the inbox
                }
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - Routing types

private enum ComposerRoute: Identifiable {
    case text(PhoneAction)
    case mail(PhoneAction)

    var id: Int {
        switch self {
        case .text(let a), .mail(let a): return a.id
        }
    }
}

private struct Fallback: Identifiable {
    enum Kind { case text, mail }
    let action: PhoneAction
    let kind: Kind
    var id: Int { action.id }
}

// MARK: - Row

private struct InboxRow: View {
    let action: PhoneAction

    private var title: String {
        switch action.type {
        case "send_text":
            return firstLine(action.payload["body"]) ?? "Text message"
        case "email_draft":
            let subject = action.payload["subject"]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return subject.isEmpty ? (firstLine(action.payload["body"]) ?? "Email draft") : subject
        case "note":
            let t = action.payload["title"]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return t.isEmpty ? (firstLine(action.payload["body"]) ?? "Note") : t
        default:
            return InboxStyle.label(for: action.type)
        }
    }

    private var subtitle: String {
        let to = action.payload["to"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch action.type {
        case "send_text":
            return to.isEmpty ? "Text message — add a recipient" : "Text to \(to)"
        case "email_draft":
            return to.isEmpty ? "Email draft — add a recipient" : "Email to \(to)"
        case "note":
            return "Tap to save to Notes"
        default:
            return InboxStyle.label(for: action.type)
        }
    }

    private var trailingIcon: String {
        action.type == "note" ? "square.and.arrow.down" : "square.and.pencil"
    }

    private var accessibilityHintText: String {
        switch action.type {
        case "send_text": return "Opens a prefilled message ready to send."
        case "email_draft": return "Opens a prefilled email ready to send."
        case "note": return "Saves this note on the phone."
        default: return ""
        }
    }

    private func firstLine(_ text: String?) -> String? {
        let line = (text ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        return line.isEmpty ? nil : line
    }

    var body: some View {
        HStack(spacing: DS.Space.m) {
            IconTile(icon: InboxStyle.icon(for: action.type))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Text(subtitle)
                    Text("·")
                    Text(TimestampFormat.relative(action.ts))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: trailingIcon)
                .font(.title3)
                .foregroundStyle(DS.Palette.accent)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(InboxStyle.label(for: action.type)), \(TimestampFormat.relative(action.ts)). \(title)")
        .accessibilityHint(accessibilityHintText)
    }
}

// MARK: - MessageUI wrappers

private struct MessageComposer: UIViewControllerRepresentable {
    let recipient: String?
    let body: String
    let onFinish: (MessageComposeResult) -> Void

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onFinish: (MessageComposeResult) -> Void

        init(onFinish: @escaping (MessageComposeResult) -> Void) {
            self.onFinish = onFinish
        }

        func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                          didFinishWith result: MessageComposeResult) {
            onFinish(result)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.messageComposeDelegate = context.coordinator
        if let recipient = recipient, !recipient.isEmpty {
            vc.recipients = [recipient]
        }
        vc.body = body
        return vc
    }

    func updateUIViewController(_ vc: MFMessageComposeViewController, context: Context) {}
}

private struct MailComposer: UIViewControllerRepresentable {
    let recipient: String?
    let subject: String
    let body: String
    let onFinish: (MFMailComposeResult) -> Void

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: (MFMailComposeResult) -> Void

        init(onFinish: @escaping (MFMailComposeResult) -> Void) {
            self.onFinish = onFinish
        }

        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult,
                                   error: Error?) {
            onFinish(result)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        if let recipient = recipient, !recipient.isEmpty {
            vc.setToRecipients([recipient])
        }
        vc.setSubject(subject)
        vc.setMessageBody(body, isHTML: false)
        return vc
    }

    func updateUIViewController(_ vc: MFMailComposeViewController, context: Context) {}
}
