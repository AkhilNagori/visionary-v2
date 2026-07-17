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
    @Environment(\.dismiss) private var dismiss

    @State private var isFlipped = false
    @State private var isGrading = false

    var body: some View {
        NavigationStack {
            content
                .background(DS.Palette.canvas)
                .navigationTitle("Flashcards")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
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
                .padding(.horizontal, DS.Space.xxl)
        }
        .refreshable { await model.loadDue(client: appState.client) }
    }

    private var emptyState: some View {
        VStack(spacing: DS.Space.m) {
            EmptyStateView(
                icon: "rectangle.on.rectangle.angled",
                title: "Turn today into a deck",
                message: "Everything the glasses read today can become question-and-answer cards."
            )
            if let notice = model.generateNotice {
                Label(notice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            generateFooterButton
        }
    }

    private var celebration: some View {
        VStack(spacing: DS.Space.m) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(DS.Palette.online)
                .accessibilityHidden(true)
            Text("All caught up")
                .font(DS.Text.cardTitle)
            Text(model.reviewedCount == 1
                 ? "You reviewed 1 card. It'll come back when it's due."
                 : "You reviewed \(model.reviewedCount) cards. They'll come back when they're due.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let notice = model.generateNotice {
                Label(notice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            generateFooterButton
        }
        .accessibilityElement(children: .combine)
    }

    private var generateFooterButton: some View {
        Button {
            Haptics.tap()
            Task { await model.generate(client: appState.client) }
        } label: {
            Label("Generate from Today", systemImage: "wand.and.stars")
                .font(DS.Text.subhead.weight(.semibold))
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .disabled(model.isGenerating || appState.client == nil)
        .padding(.top, DS.Space.xs)
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
        .animation(DS.Motion.spring, value: model.queue.first?.id)
    }

    private var header: some View {
        HStack {
            Label(model.queue.count == 1 ? "1 to go" : "\(model.queue.count) to go",
                  systemImage: "rectangle.stack")
                .monospacedDigit()
            Spacer()
            if model.reviewedCount > 0 {
                Text("\(model.reviewedCount) reviewed")
                    .monospacedDigit()
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func cardView(_ card: Flashcard) -> some View {
        ZStack {
            face(tag: "Question", text: card.question, flipHint: "Tap to reveal")
                .opacity(isFlipped ? 0 : 1)
                .rotation3DEffect(.degrees(isFlipped ? 180 : 0), axis: (x: 0, y: 1, z: 0))
            face(tag: "Answer", text: card.answer, flipHint: nil)
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

    private func face(tag: String, text: String, flipHint: String?) -> some View {
        VStack(spacing: DS.Space.m) {
            Text(tag)
                .font(.caption.weight(.semibold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(DS.Palette.accent)
            ScrollView(showsIndicators: false) {
                Text(text)
                    .font(.title3.weight(.medium))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.Space.xs)
            }
            if let flipHint = flipHint {
                Label(flipHint, systemImage: "hand.tap")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, minHeight: 320)
        .background(
            DS.Palette.card,
            in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
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

    /// One accent: "Good" (the default) is the filled button; the rest are
    /// quiet fills, with "Again" carrying the destructive voice.
    private func gradeBar(_ card: Flashcard) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: DS.Space.s))
            : AnyLayout(HStackLayout(spacing: DS.Space.s))
        return layout {
            ForEach(ReviewGrade.allCases) { g in
                Button {
                    grade(g, for: card)
                } label: {
                    Text(g.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(gradeForeground(g))
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(
                            gradeBackground(g),
                            in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        )
                }
                .buttonStyle(.pressable)
                .disabled(isGrading)
                .accessibilityHint(g.hint)
            }
        }
        .opacity(isGrading ? 0.6 : 1)
    }

    private func gradeForeground(_ g: ReviewGrade) -> Color {
        switch g {
        case .good: return .white
        case .again: return DS.Palette.danger
        default: return .primary
        }
    }

    private func gradeBackground(_ g: ReviewGrade) -> Color {
        g == .good ? DS.Palette.accent : DS.Palette.fill
    }

    private func flip() {
        Haptics.tap()
        withAnimation(DS.Motion.spring) {
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
