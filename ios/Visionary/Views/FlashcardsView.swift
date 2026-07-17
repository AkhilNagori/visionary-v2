import SwiftUI
import UIKit

// Wire types + endpoints live in Models.swift (Flashcard) and APIClient.swift
// (flashcardsGenerate / flashcardsDue / reviewFlashcard).

// MARK: - Grades

private enum ReviewGrade: Int, CaseIterable, Identifiable {
    case again = 0, hard, good, easy

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .again: return "Again"
        case .hard: return "Hard"
        case .good: return "Good"
        case .easy: return "Easy"
        }
    }

    var tint: Color {
        switch self {
        case .again: return .red
        case .hard: return .orange
        case .good: return .blue
        case .easy: return .green
        }
    }

    var hint: String {
        switch self {
        case .again: return "You'll see this card again before the session ends."
        case .hard: return "Schedules this card sooner."
        case .good: return "Schedules this card normally."
        case .easy: return "Schedules this card further out."
        }
    }
}

// MARK: - Model

@MainActor
final class FlashcardsModel: ObservableObject {
    @Published private(set) var queue: [Flashcard] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?
    @Published private(set) var isGenerating = false
    @Published private(set) var generateNotice: String?
    @Published private(set) var reviewedCount = 0
    @Published private(set) var finishedSession = false
    @Published var actionError: String?

    private var hasLoaded = false
    var needsInitialLoad: Bool { !hasLoaded }

    func loadDue(client: APIClient?) async {
        guard let client = client, !isLoading else { return }
        isLoading = true
        loadError = nil
        do {
            let cards = try await client.flashcardsDue()
            queue = cards
            if !cards.isEmpty {
                reviewedCount = 0
                finishedSession = false
                generateNotice = nil
            }
            hasLoaded = true
        } catch {
            if !Task.isCancelled { loadError = error.localizedDescription }
        }
        isLoading = false
    }

    func generate(client: APIClient?) async {
        guard let client = client, !isGenerating else { return }
        isGenerating = true
        generateNotice = nil
        do {
            let created = try await client.flashcardsGenerate()
            await loadDue(client: client)
            if queue.isEmpty {
                generateNotice = "Nothing to make cards from yet — read something with the glasses today, then try again."
            } else if created > 0 {
                Haptics.success()
            }
        } catch {
            Haptics.error()
            actionError = error.localizedDescription
        }
        isGenerating = false
    }

    /// Grades the front card; "Again" re-queues it for later in this session.
    /// Returns false when the review didn't reach the glasses.
    func grade(_ grade: Int, client: APIClient?) async -> Bool {
        guard let client = client, let card = queue.first else { return false }
        do {
            try await client.reviewFlashcard(id: card.id, grade: grade)
            reviewedCount += 1
            queue.removeFirst()
            if grade == ReviewGrade.again.rawValue {
                queue.append(card)
            }
            if queue.isEmpty {
                finishedSession = true
                Haptics.success()
            }
            return true
        } catch {
            Haptics.error()
            actionError = error.localizedDescription
            return false
        }
    }
}

// MARK: - Flashcards view

struct FlashcardsView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = FlashcardsModel()
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var isFlipped = false
    @State private var isGrading = false
    @State private var celebrationAppeared = false

    var body: some View {
        NavigationStack {
            content
                .background(Color(.systemGroupedBackground))
                .navigationTitle("Flashcards")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        generateButton
                    }
                }
                .alert("Couldn't complete that", isPresented: errorBinding) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(model.actionError ?? "")
                }
                .task {
                    if model.needsInitialLoad {
                        await model.loadDue(client: appState.client)
                    }
                }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.actionError != nil },
                set: { if !$0 { model.actionError = nil } })
    }

    private var generateButton: some View {
        Button {
            Haptics.tap()
            Task { await model.generate(client: appState.client) }
        } label: {
            if model.isGenerating {
                ProgressView()
            } else {
                Label("Generate from today", systemImage: "wand.and.stars")
            }
        }
        .disabled(model.isGenerating || appState.client == nil)
        .accessibilityLabel("Generate flashcards from today's reading")
    }

    // MARK: States

    @ViewBuilder
    private var content: some View {
        if let card = model.queue.first {
            reviewScreen(card)
        } else if model.isLoading || model.isGenerating {
            centered {
                LoadingStateView(label: model.isGenerating
                                 ? "Reading today's history…"
                                 : "Loading your deck…")
            }
        } else if let error = model.loadError {
            centered {
                EmptyStateView(
                    icon: "wifi.exclamationmark",
                    tint: DS.Palette.attention,
                    title: "Couldn't load flashcards",
                    message: error,
                    actionTitle: "Try Again"
                ) {
                    Task { await model.loadDue(client: appState.client) }
                }
            }
        } else if model.finishedSession {
            centered { celebration }
        } else {
            centered { emptyState }
        }
    }

    private func centered<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
                .padding(.horizontal, 32)
        }
        .refreshable { await model.loadDue(client: appState.client) }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            EmptyStateView(
                icon: "sparkles.rectangle.stack",
                tint: DS.Palette.flashcards,
                title: "Turn today into a deck",
                message: "Everything the glasses read today can become question-and-answer cards. Generate a deck now and review it tonight — spaced repetition schedules the rest."
            )
            if let notice = model.generateNotice {
                Label(notice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.leading)
            }
            Button {
                Haptics.tap()
                Task { await model.generate(client: appState.client) }
            } label: {
                Label("Generate from Today", systemImage: "wand.and.stars")
                    .font(.headline)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isGenerating || appState.client == nil)
            .padding(.top, 4)
        }
    }

    private var celebration: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.12))
                    .frame(width: 120, height: 120)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
            }
            .scaleEffect(celebrationAppeared ? 1 : 0.4)
            .opacity(celebrationAppeared ? 1 : 0)
            Text("All caught up")
                .font(.title2.bold())
            Text(model.reviewedCount == 1
                 ? "You reviewed 1 card. It'll come back when it's due."
                 : "You reviewed \(model.reviewedCount) cards. They'll come back when they're due.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let notice = model.generateNotice {
                Label(notice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.leading)
            }
            Button {
                Haptics.tap()
                Task { await model.generate(client: appState.client) }
            } label: {
                Label("Generate from Today", systemImage: "wand.and.stars")
                    .font(.headline)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isGenerating || appState.client == nil)
            .padding(.top, 4)
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                celebrationAppeared = true
            }
        }
        .onDisappear { celebrationAppeared = false }
        .accessibilityElement(children: .combine)
    }

    // MARK: Review

    private func reviewScreen(_ card: Flashcard) -> some View {
        VStack(spacing: 16) {
            header
            cardView(card)
                .id(card.id)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)))
            Spacer(minLength: 0)
            if isFlipped {
                gradeBar(card)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                showAnswerButton
            }
        }
        .padding()
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.queue.first?.id)
    }

    private var header: some View {
        HStack {
            Label(model.queue.count == 1 ? "1 to go" : "\(model.queue.count) to go",
                  systemImage: "rectangle.stack")
            Spacer()
            if model.reviewedCount > 0 {
                Text("\(model.reviewedCount) reviewed")
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func cardView(_ card: Flashcard) -> some View {
        ZStack {
            face(tag: "Question", text: card.question, tint: .blue, flipHint: "Tap to reveal")
                .opacity(isFlipped ? 0 : 1)
                .rotation3DEffect(.degrees(isFlipped ? 180 : 0), axis: (x: 0, y: 1, z: 0))
            face(tag: "Answer", text: card.answer, tint: .green, flipHint: nil)
                .opacity(isFlipped ? 1 : 0)
                .rotation3DEffect(.degrees(isFlipped ? 0 : -180), axis: (x: 0, y: 1, z: 0))
        }
        .contentShape(Rectangle())
        .onTapGesture { flip() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isFlipped ? "Answer: \(card.answer)" : "Question: \(card.question)")
        .accessibilityHint(isFlipped
                           ? "Grade how well you knew it with the buttons below."
                           : "Double tap to reveal the answer.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { flip() }
    }

    private func face(tag: String, text: String, tint: Color, flipHint: String?) -> some View {
        VStack(spacing: 14) {
            Text(tag)
                .font(.caption.weight(.bold))
                .tracking(1.5)
                .textCase(.uppercase)
                .foregroundStyle(tint)
            ScrollView(showsIndicators: false) {
                Text(text)
                    .font(.title3.weight(.medium))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            if let flipHint = flipHint {
                Label(flipHint, systemImage: "hand.tap")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(DS.Space.l + DS.Space.xs)
        .frame(maxWidth: .infinity, minHeight: 320)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .fill(DS.Palette.card)
                .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
        )
    }

    private var showAnswerButton: some View {
        Button {
            flip()
        } label: {
            Label("Show Answer", systemImage: "eye")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityHint("Flips the card to its answer side.")
    }

    private func gradeBar(_ card: Flashcard) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            ForEach(ReviewGrade.allCases) { g in
                Button {
                    grade(g, for: card)
                } label: {
                    Text(g.label)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                                .fill(g.tint.gradient)
                        )
                }
                .buttonStyle(.pressable)
                .disabled(isGrading)
                .accessibilityHint(g.hint)
            }
        }
        .opacity(isGrading ? 0.6 : 1)
    }

    private func flip() {
        Haptics.tap()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
            isFlipped.toggle()
        }
    }

    private func grade(_ g: ReviewGrade, for card: Flashcard) {
        guard !isGrading else { return }
        isGrading = true
        Haptics.tap()
        Task { @MainActor in
            let ok = await model.grade(g.rawValue, client: appState.client)
            if ok {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { isFlipped = false }
            }
            isGrading = false
        }
    }
}
