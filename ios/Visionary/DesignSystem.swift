import SwiftUI
import UIKit

// The Visionary design language. One brand accent, semantic status colors, a
// neutral ramp, and a single elevation style. Feature identity comes from
// SF Symbols and typography, never from per-feature tints.

// MARK: - Tokens

enum DS {

    /// 8pt spacing grid.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    /// One corner-radius language. Always used with `.continuous`.
    enum Radius {
        static let control: CGFloat = 12
        static let card: CGFloat = 20
    }

    /// Physical motion: springs for things that move, ease for things that
    /// fade. Nothing bouncy — transitions should feel inevitable.
    enum Motion {
        static let spring = Animation.spring(response: 0.35, dampingFraction: 0.85)
        static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.9)
        static let gentle = Animation.easeOut(duration: 0.25)
    }

    /// Semantic colors. Backgrounds ride UIKit dynamic colors so dark mode is
    /// automatic. `accent` is the one brand color; green/orange/red are status.
    enum Palette {
        static let canvas = Color(.systemGroupedBackground)
        static let card = Color(.secondarySystemGroupedBackground)
        static let fill = Color(.tertiarySystemFill)

        static let accent = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.33, green: 0.57, blue: 1.00, alpha: 1.0)
                : UIColor(red: 0.00, green: 0.35, blue: 0.87, alpha: 1.0)
        })

        static let online = Color.green
        static let attention = Color.orange
        static let danger = Color.red
    }

    /// Type scale on system text styles so Dynamic Type scales everything.
    enum Text {
        static let hero = Font.largeTitle.weight(.bold)
        static let title = Font.title2.weight(.bold)
        static let cardTitle = Font.headline
        static let body = Font.body
        static let subhead = Font.subheadline
        static let caption = Font.caption
    }
}

// MARK: - Haptics

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

// MARK: - Card

struct CardBackground: ViewModifier {
    var padding: CGFloat = DS.Space.l

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                DS.Palette.card,
                in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            )
    }
}

extension View {
    func cardStyle(padding: CGFloat = DS.Space.l) -> some View {
        modifier(CardBackground(padding: padding))
    }
}

// MARK: - Section header

/// The one section-label voice: quiet uppercase caption, used for on-page
/// sections and labeled blocks inside detail screens.
struct SectionHeader: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Icon tile

/// The app's one icon container: a continuous rounded square, soft accent
/// tint by default, solid accent when prominent. Radius scales with size so
/// every tile shares the same geometry.
struct IconTile: View {
    let icon: String
    var tint: Color = DS.Palette.accent
    var size: CGFloat = 40
    var prominent: Bool = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(prominent ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.12)))
                .frame(width: size, height: size)
            Image(systemName: icon)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(prominent ? Color.white : tint)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Badge

struct DSBadge: View {
    let text: String
    var tint: Color = DS.Palette.accent
    var icon: String? = nil
    var filled: Bool = false

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.caption2.weight(.semibold))
            }
            Text(text)
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
        }
        .textCase(.uppercase)
        .foregroundStyle(filled ? Color.white : tint)
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.xs)
        .background(filled ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.12)), in: Capsule())
    }
}

// MARK: - Status dot

/// A small presence indicator. When `breathing`, a soft ring exhales outward
/// on repeat — the glasses feel alive without demanding attention.
struct StatusDot: View {
    let color: Color
    var breathing: Bool = false

    @State private var pulse = false

    var body: some View {
        ZStack {
            if breathing {
                Circle()
                    .fill(color.opacity(0.4))
                    .frame(width: 18, height: 18)
                    .scaleEffect(pulse ? 1.9 : 0.6)
                    .opacity(pulse ? 0 : 0.8)
            }
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
        }
        .frame(width: 18, height: 18)
        .onAppear {
            guard breathing else { return }
            withAnimation(.easeOut(duration: 2.0).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Pressable button style

/// Buttons compress slightly under the finger and settle back — the whole app
/// shares this one press physics.
struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(DS.Motion.snappy, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

// MARK: - State moments

/// Loading, designed once: a large spinner and a quiet line of context.
struct LoadingStateView: View {
    let label: String

    var body: some View {
        VStack(spacing: DS.Space.m) {
            ProgressView()
                .controlSize(.large)
            Text(label)
                .font(DS.Text.subhead)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Empty and error states share one quiet moment: a single symbol, a title,
/// one line of context, and an optional action. No illustration, no pop.
struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: DS.Space.m) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            VStack(spacing: DS.Space.xs) {
                Text(title)
                    .font(DS.Text.cardTitle)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(DS.Text.subhead)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle = actionTitle, let action = action {
                Button {
                    Haptics.tap()
                    action()
                } label: {
                    Text(actionTitle)
                        .font(DS.Text.subhead.weight(.semibold))
                        .padding(.horizontal, DS.Space.s)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .padding(.top, DS.Space.xs)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Toast

private struct ToastModifier: ViewModifier {
    @Binding var toast: String?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let toast = toast {
                    Label(toast, systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, DS.Space.l)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, DS.Space.m)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .accessibilityElement(children: .combine)
                }
            }
            .animation(DS.Motion.spring, value: toast)
            .task(id: toast) {
                guard let message = toast else { return }
                UIAccessibility.post(notification: .announcement, argument: message)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if toast == message { toast = nil }
            }
    }
}

extension View {
    /// Confirmation toast: set the binding and it announces itself to
    /// VoiceOver, floats up from the bottom, and dismisses after 3 seconds.
    func dsToast(_ toast: Binding<String?>) -> some View {
        modifier(ToastModifier(toast: toast))
    }
}
