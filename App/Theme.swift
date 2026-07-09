import SwiftUI

/// Design system for a modern "avionics" look that adapts to light and dark
/// mode — airy paper-white in light, deep navy in dark, one sky-blue accent.
enum Theme {

    // MARK: - Adaptive palette (Apple system colors)

    /// iOS system blue — the most "Apple made this" choice there is.
    static let accent = Color(light: 0x007AFF, dark: 0x0A84FF)
    static let accent2 = Color(light: 0x0066D6, dark: 0x0A6CD9)
    static let success = Color(light: 0x34C759, dark: 0x30D158)   // system green
    static let failure = Color(light: 0xFF3B30, dark: 0xFF453A)   // system red
    static let amber = Color(light: 0xC93400, dark: 0xFF9F0A)     // system orange (darkened for light bg)
    static let purple = Color(light: 0xAF52DE, dark: 0xBF5AF2)    // system purple

    /// Text on top of an accent-filled control (e.g. the listening PTT button).
    static let onAccent = Color.white

    /// System fills — the same colors native controls use.
    static let chipFill = Color(uiColor: .tertiarySystemFill)
    static let cardFill = Color(uiColor: .secondarySystemGroupedBackground)
    static let stroke = Color(light: 0x000000, dark: 0xFFFFFF).opacity(0.10)

    // MARK: - Background

    /// System grouped background — flat and native, like Settings or Health.
    @ViewBuilder
    static var background: some View {
        Color(uiColor: .systemGroupedBackground)
            .ignoresSafeArea()
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }

    /// A color that resolves per color scheme (light hex / dark hex).
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: 1)
        })
    }
}

/// Grouped-style card, exactly like a Settings/Health section: flat secondary
/// background, 16pt corners, no border.
struct CardModifier: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(CardModifier(padding: padding)) }
}
