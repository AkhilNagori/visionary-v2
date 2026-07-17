import SwiftUI

/// First-launch introduction: what the glasses do, the one-button language,
/// pairing, and the privacy promise. Gated by @AppStorage("has_onboarded") in
/// RootView — already-paired users never see it — and fully skippable.
struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var page = 0

    private struct PageRow: Identifiable {
        let icon: String
        let text: String
        var id: String { text }
    }

    private struct Page {
        let icon: String
        let tint: Color
        let title: String
        let message: String
        let rows: [PageRow]
    }

    private static let pages: [Page] = [
        Page(icon: "eyeglasses",
             tint: .blue,
             title: "Glasses that talk",
             message: "Visionary reads any text, describes any scene, and answers questions about whatever you're looking at — out loud, hands-free. Modes turn it into a tour guide, recipe copilot, translator, and more.",
             rows: []),
        Page(icon: "hand.tap",
             tint: .purple,
             title: "One button does everything",
             message: "No screen on your face. The temple button speaks the world:",
             rows: [
                PageRow(icon: "1.circle", text: "Single press reads the text in front of you"),
                PageRow(icon: "2.circle", text: "Double press describes the scene"),
                PageRow(icon: "3.circle", text: "Triple press records a voice note"),
                PageRow(icon: "hand.raised", text: "Hold, ask a question, let go"),
             ]),
        Page(icon: "qrcode.viewfinder",
             tint: .teal,
             title: "Pairing takes seconds",
             message: "The app talks to the glasses directly over your Wi-Fi — no account, no sign-up.",
             rows: [
                PageRow(icon: "power", text: "Power on — the glasses speak a 6-digit code"),
                PageRow(icon: "camera.viewfinder", text: "Scan their QR code, or type the code in"),
                PageRow(icon: "wifi", text: "Keep phone and glasses on the same network"),
             ]),
        Page(icon: "lock.shield",
             tint: .green,
             title: "Private by design",
             message: "A camera on your face has to earn trust.",
             rows: [
                PageRow(icon: "hand.tap", text: "It captures only when you press the button"),
                PageRow(icon: "internaldrive", text: "History stays on the glasses, not in a cloud"),
                PageRow(icon: "antenna.radiowaves.left.and.right.slash",
                        text: "Local-only mode runs everything on-device"),
             ]),
    ]

    private var isLastPage: Bool { page == Self.pages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip") {
                    Haptics.tap()
                    onFinish()
                }
                .font(.body.weight(.medium))
                .padding(.horizontal, 20)
                .frame(minHeight: 44)
                .opacity(isLastPage ? 0 : 1)
                .disabled(isLastPage)
                .accessibilityHidden(isLastPage)
                .accessibilityHint("Skips the introduction.")
            }
            .padding(.top, 8)

            TabView(selection: $page) {
                ForEach(Self.pages.indices, id: \.self) { index in
                    pageView(Self.pages[index])
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            dots
                .padding(.vertical, 12)

            Button {
                if isLastPage {
                    Haptics.success()
                    onFinish()
                } else {
                    Haptics.tap()
                    withAnimation { page += 1 }
                }
            } label: {
                Text(isLastPage ? "Get Started" : "Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(Self.pages[page].tint)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .accessibilityHint(isLastPage ? "Finishes the introduction." : "Shows the next page.")
        }
        .background(DS.Palette.canvas.ignoresSafeArea())
    }

    private func pageView(_ p: Page) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(colors: [p.tint.opacity(0.25), p.tint.opacity(0.08)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .frame(width: 140, height: 140)
                    Image(systemName: p.icon)
                        .font(.system(size: 56, weight: .medium))
                        .foregroundStyle(p.tint)
                }
                .padding(.top, 24)
                .accessibilityHidden(true)

                Text(p.title)
                    .font(DS.Text.hero)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)

                Text(p.message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if !p.rows.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(p.rows) { row in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: row.icon)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(p.tint)
                                    .frame(width: 26)
                                Text(row.text)
                                    .font(.subheadline)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .cardStyle(padding: 18)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 12)
        }
    }

    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(Self.pages.indices, id: \.self) { index in
                Capsule()
                    .fill(index == page ? Self.pages[page].tint : Color(.systemFill))
                    .frame(width: index == page ? 22 : 8, height: 8)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: page)
        .accessibilityElement()
        .accessibilityLabel("Page \(page + 1) of \(Self.pages.count)")
    }
}
