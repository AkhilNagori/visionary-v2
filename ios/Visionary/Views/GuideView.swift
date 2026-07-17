import SwiftUI
import UIKit

/// Remote sighted guide: you see the wearer's camera and everything you send
/// is spoken directly into their ear. Type (or use the keyboard's mic
/// dictation) and hit send; the Listen button records the wearer's reply
/// through the glasses and shows the transcript here.
struct GuideView: View {
    private struct Exchange: Identifiable {
        enum Role { case guide, wearer }
        let id = UUID()
        let role: Role
        let text: String
    }

    @EnvironmentObject private var appState: AppState

    @State private var streamID = UUID()
    @State private var message = ""
    @State private var isSending = false
    @State private var isListening = false
    @State private var log: [Exchange] = []
    @State private var guideError: String?
    @FocusState private var composerFocused: Bool

    private static let quickPhrases = [
        "Stop.",
        "All clear ahead.",
        "Slightly left.",
        "Slightly right.",
        "Obstacle ahead.",
        "Step up ahead.",
        "Step down ahead.",
        "Doorway on your right.",
        "Doorway on your left.",
    ]

    var body: some View {
        NavigationStack {
            Group {
                if let client = appState.client {
                    guideStage(client)
                } else {
                    unpairedState
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Guide")
            .navigationBarTitleDisplayMode(.inline)
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
            .alert("Couldn't reach the glasses", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(guideError ?? "")
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { guideError != nil }, set: { if !$0 { guideError = nil } })
    }

    // MARK: - Stage

    private func guideStage(_ client: APIClient) -> some View {
        VStack(spacing: 0) {
            // .id ties the stream's lifetime to the Restart button:
            // a new UUID recreates MJPEGView, whose onAppear reconnects
            MJPEGView(request: client.liveRequest())
                .id(streamID)
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
            conversation
            quickPhraseRow
            composer
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    framingCard
                    ForEach(log) { exchange in
                        bubble(exchange)
                            .id(exchange.id)
                    }
                    if isListening {
                        listeningIndicator
                            .id("guide-listening")
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
                .animation(DS.Motion.spring, value: log.count)
            }
            .onChange(of: log.last?.id) { _ in
                withAnimation(DS.Motion.gentle) {
                    proxy.scrollTo(log.last?.id, anchor: .bottom)
                }
            }
            .onChange(of: isListening) { listening in
                guard listening else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo("guide-listening", anchor: .bottom)
                }
            }
        }
    }

    private var framingCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "eye.fill")
                .font(.subheadline)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("You are their eyes")
                    .font(.subheadline.weight(.semibold))
                Text("Everything you send is spoken aloud in the wearer's ear. Be calm and specific: distances, directions, one instruction at a time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
        .accessibilityElement(children: .combine)
    }

    private func bubble(_ exchange: Exchange) -> some View {
        HStack {
            if exchange.role == .guide { Spacer(minLength: 40) }
            VStack(alignment: exchange.role == .guide ? .trailing : .leading, spacing: 2) {
                Text(exchange.role == .guide ? "Spoken in their ear" : "They said")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(exchange.text)
                    .font(.body)
                    .foregroundStyle(exchange.role == .guide ? .white : .primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                            .fill(exchange.role == .guide
                                  ? AnyShapeStyle(Color.accentColor.gradient)
                                  : AnyShapeStyle(DS.Palette.card))
                    )
                    .transition(.scale(scale: 0.9, anchor: exchange.role == .guide ? .bottomTrailing : .bottomLeading)
                        .combined(with: .opacity))
            }
            if exchange.role == .wearer { Spacer(minLength: 40) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(exchange.role == .guide
                            ? "You said: \(exchange.text)"
                            : "The wearer said: \(exchange.text)")
    }

    private var listeningIndicator: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Listening through the glasses…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Quick phrases

    private var quickPhraseRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.quickPhrases, id: \.self) { phrase in
                    Button {
                        send(phrase)
                    } label: {
                        Text(phrase)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background(
                                Capsule().strokeBorder(Color.accentColor.opacity(0.4))
                            )
                    }
                    .buttonStyle(.pressable)
                    .disabled(isSending || appState.client == nil)
                    .accessibilityHint("Speaks this phrase in the wearer's ear immediately.")
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Guide them — spoken in their ear", text: $message, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .focused($composerFocused)
                .onSubmit(sendFromField)
                .accessibilityHint("What you type is spoken aloud by the glasses. Use the keyboard's microphone to dictate.")
            Button(action: sendFromField) {
                if isSending {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
            }
            .frame(minWidth: 44, minHeight: 44)
            .disabled(trimmedMessage.isEmpty || isSending || appState.client == nil)
            .accessibilityLabel("Speak in their ear")
            Button(action: listen) {
                if isListening {
                    ProgressView()
                } else {
                    Image(systemName: "ear")
                        .font(.title2)
                }
            }
            .frame(minWidth: 44, minHeight: 44)
            .disabled(isListening || appState.client == nil)
            .accessibilityLabel("Listen for their reply")
            .accessibilityHint("The glasses record until the wearer stops talking and the transcript appears here.")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sendFromField() {
        let text = trimmedMessage
        guard !text.isEmpty else { return }
        send(text)
        message = ""
    }

    private func send(_ text: String) {
        guard !isSending, let client = appState.client else { return }
        Haptics.tap()
        isSending = true
        Task { @MainActor in
            do {
                try await client.speak(text)
                log.append(Exchange(role: .guide, text: text))
                Haptics.success()
            } catch {
                Haptics.error()
                guideError = error.localizedDescription
            }
            isSending = false
        }
    }

    private func listen() {
        guard !isListening, let client = appState.client else { return }
        Haptics.tap()
        isListening = true
        composerFocused = false
        Task { @MainActor in
            do {
                let text = try await client.listen(maxS: 10)
                let heard = text.trimmingCharacters(in: .whitespacesAndNewlines)
                log.append(Exchange(role: .wearer,
                                    text: heard.isEmpty ? "(nothing heard)" : heard))
                Haptics.success()
                if !heard.isEmpty {
                    UIAccessibility.post(notification: .announcement,
                                         argument: "They said: \(heard)")
                }
            } catch {
                Haptics.error()
                guideError = error.localizedDescription
            }
            isListening = false
        }
    }

    // MARK: - Unpaired

    private var unpairedState: some View {
        EmptyStateView(
            icon: "eye.slash",
            tint: DS.Palette.guide,
            title: "No glasses connected",
            message: "Pair with your Visionary glasses to see what the wearer sees and speak in their ear."
        )
        .padding(.horizontal, DS.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
