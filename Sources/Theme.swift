import AppKit
import SwiftUI

// MARK: - Colors

extension Color {
    static func adaptive(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                           green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        })
    }

    // Categorical slots 1–4 of the reference data-viz palette, in fixed order
    static let seriesApp = adaptive(light: 0x2a78d6, dark: 0x3987e5)
    static let seriesWired = adaptive(light: 0xeb6834, dark: 0xd95926)
    static let seriesCompressed = adaptive(light: 0x1baf7a, dark: 0x199e70)
    static let seriesCached = adaptive(light: 0xeda100, dark: 0xc98500)

    /// All eight categorical slots, in fixed order; never cycled
    static let categorical: [Color] = [
        seriesApp, seriesWired, seriesCompressed, seriesCached,
        adaptive(light: 0xe87ba4, dark: 0xd55181),
        adaptive(light: 0x008300, dark: 0x008300),
        adaptive(light: 0x6250d6, dark: 0x9085e9),
        adaptive(light: 0xe34948, dark: 0xe66767),
    ]

    static let track = Color.primary.opacity(0.08)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let hairline = Color.primary.opacity(0.07)
}

// MARK: - Motion

extension Animation {
    /// Strong ease-out (cubic-bezier(0.23, 1, 0.32, 1)) for things entering or responding to the user
    static func easeOutStrong(_ duration: Double = 0.22) -> Animation { .timingCurve(0.23, 1, 0.32, 1, duration: duration) }
    /// Exits are faster than entrances
    static let exit = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.14)
}

extension AnyTransition {
    /// Rise in from slightly below; leave quickly with a fade. Never from scale 0.
    static func rise(reduceMotion: Bool) -> AnyTransition {
        .asymmetric(
            insertion: reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 12)).combined(with: .scale(scale: 0.98)),
            removal: .opacity.animation(.exit)
        )
    }
}

// MARK: - Buttons

/// Scale to 0.97 on press so every button feels like it heard the click.
struct PressableButtonStyle: ButtonStyle {
    enum Role { case primary, secondary, plain }
    var role: Role = .secondary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: role == .primary ? .semibold : .medium))
            .padding(.horizontal, role == .plain ? 6 : 14)
            .padding(.vertical, role == .plain ? 4 : 7)
            .foregroundStyle(role == .primary ? Color.white : Color.primary)
            .background {
                switch role {
                case .primary: RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor)
                case .secondary: RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07))
                case .plain: Color.clear
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var primary: PressableButtonStyle { .init(role: .primary) }
    static var secondary: PressableButtonStyle { .init(role: .secondary) }
    static var quiet: PressableButtonStyle { .init(role: .plain) }
}

// MARK: - Cards

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.card))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.hairline))
            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
    }
}

struct CardHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if let subtitle {
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 22, weight: .bold))
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Icons

/// The app's real icon when there is one, otherwise an SF Symbol tile.
struct ItemIcon: View {
    let appPath: String?
    let symbol: String
    var size: CGFloat = 28

    var body: some View {
        if let appPath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: appPath))
                .resizable()
                .frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(Color.primary.opacity(0.07))
                .frame(width: size, height: size)
                .overlay(Image(systemName: symbol).font(.system(size: size * 0.45, weight: .medium)).foregroundStyle(.secondary))
        }
    }
}

// MARK: - Formatting

func gbText(_ v: Double) -> String { v >= 10 ? String(format: "%.1f GB", v) : String(format: "%.2f GB", v) }

func mbText(_ mb: Int) -> String { mb >= 1024 ? String(format: "%.1f GB", Double(mb) / 1024) : "\(mb) MB" }
