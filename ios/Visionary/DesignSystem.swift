import SwiftUI
import UIKit

// The Visionary design language. Every screen draws from these tokens and
// components — no view defines its own radius, spacing, palette, or state
// treatment. One voice.

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
        static let chip: CGFloat = 8
        static let control: CGFloat = 12
        static let card: CGFloat = 20
        static let hero: CGFloat = 28
    }

    /// Physical motion: springs for things that move, ease for things that fade.
    enum Motion {
        static let spring = Animation.spring(response: 0.35, dampingFraction: 0.8)
        static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.85)
        static let bouncy = Animation.spring(response: 0.5, dampingFraction: 0.65)
        static let gentle = Animation.easeOut(duration: 0.25)
    }

    /// Semantic colors. Backgrounds ride UIKit dynamic colors so dark mode is
    /// automatic; feature tints are one hue per job, used identically everywhere.
    enum Palette {
        static let canvas = Color(.systemGroupedBackground)
        static let card = Color(.secondarySystemGroupedBackground)
        static let fill = Color(.tertiarySystemFill)

        static let online = Color.green
        static let attention = Color.orange
        static let danger = Color.red

        static let read = Color.blue
        static let describe = Color.purple
        static let record = Color.pink
        static let captions = Color.teal
        static let guide = Color.green
        static let memory = Color.orange
        static let flashcards = Color.purple
        static let notes = Color.orange
        static let modes = Color.indigo
    }

    /// Type scale: rounded display faces for brand moments, system text styles
    /// underneath so Dynamic Type scales everything.
    enum Text {
        static let hero = Font.system(.largeTitle, design: .rounded).weight(.bold)
        static let title = Font.system(.title2, design: .rounded).weight(.bold)
        static let stateTitle = Font.system(.title3, design: .rounded).weight(.bold)
        static let cardTitle = Font.headline
        static let body = Font.body
        static let subhead = Font.subheadline
        static let caption = Font.caption
        static let badge = Font.caption2.weight(.bold)
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

// MARK: - Icon tile

/// The app's one icon container: a continuous rounded square, soft tint by
/// default, gradient-filled when prominent. Radius scales with size so every
/// tile shares the same geometry.
struct IconTile: View {
    let icon: String
    let tint: Color
    var size: CGFloat = 40
    var prominent: Bool = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(prominent ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(tint.opacity(0.14)))
                .frame(width: size, height: size)
            Image(systemName: icon)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : tint)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Badge

struct DSBadge: View {
    let text: String
    let tint: Color
    var icon: String? = nil
    var filled: Bool = false

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.caption2.weight(.bold))
            }
            Text(text)
                .font(DS.Text.badge)
                .tracking(0.6)
        }
        .textCase(.uppercase)
        .foregroundStyle(filled ? Color.white : tint)
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.xs)
        .background(filled ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.14)), in: Capsule())
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

/// Buttons compress slightly under the finger and spring back — the whole app
/// shares this one press physics.
struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.96

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

/// Empty and error states share one designed moment: a tinted glyph that
/// springs in, a rounded title, a helpful line, and an optional action.
struct EmptyStateView: View {
    let icon: String
    var tint: Color = .accentColor
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    @State private var appeared = false

    var body: some View {
        VStack(spacing: DS.Space.l) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.12))
                    .frame(width: 96, height: 96)
                Image(systemName: icon)
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(tint)
            }
            .scaleEffect(appeared ? 1 : 0.6)
            .opacity(appeared ? 1 : 0)
            .accessibilityHidden(true)
            VStack(spacing: DS.Space.s) {
                Text(title)
                    .font(DS.Text.stateTitle)
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
                        .font(.headline)
                        .padding(.horizontal, DS.Space.s)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            withAnimation(DS.Motion.bouncy) { appeared = true }
        }
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

// MARK: - Segment picker

/// The app's segmented control: a sliding pill that follows the selection with
/// matched geometry. Falls back to a menu at accessibility type sizes, where
/// several segments can't render legibly. Shared by the Library and Live tabs.
struct SegmentPicker<Option: Hashable>: View {
    let title: String
    let options: [Option]
    let label: (Option) -> String
    @Binding var selection: Option

    @Environment(\.dynamicTypeSize) private var typeSize
    @Namespace private var namespace

    var body: some View {
        if typeSize.isAccessibilitySize {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(label(option)).tag(option)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .onChange(of: selection) { _ in Haptics.selection() }
        } else {
            HStack(spacing: DS.Space.xs) {
                ForEach(options, id: \.self) { option in
                    segment(option)
                }
            }
            .padding(DS.Space.xs)
            .background(
                DS.Palette.fill,
                in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
        }
    }

    private func segment(_ option: Option) -> some View {
        let selected = option == selection
        return Button {
            guard !selected else { return }
            Haptics.selection()
            withAnimation(DS.Motion.snappy) { selection = option }
        } label: {
            Text(label(option))
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .foregroundColor(selected ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: DS.Radius.control - DS.Space.xs,
                                         style: .continuous)
                            .fill(DS.Palette.card)
                            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                            .matchedGeometryEffect(id: "segment-pill", in: namespace)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
    }
}
