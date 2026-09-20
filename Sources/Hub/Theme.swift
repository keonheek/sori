import SwiftUI

// MARK: - Hub design tokens (Wispr-like: near-white surfaces, one accent, 12px radius, SF Pro)
// Dynamic colors resolve per appearance so the Hub follows the system light/dark setting.
enum Theme {
    private static func dyn(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { app in
            app.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
    private static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
    static let bg        = dyn(hex(0xF7F7F5), hex(0x1C1C1E))   // window background
    static let sidebar   = dyn(hex(0xF0EFEC), hex(0x171719))
    static let card      = dyn(hex(0xFFFFFF), hex(0x262628))
    static let cardHover = dyn(hex(0xFAFAF8), hex(0x2C2C2F))
    static let border    = dyn(hex(0xE6E4DF), hex(0x363639))
    static let text      = dyn(hex(0x1A1A1A), hex(0xF2F2F2))
    static let text2     = dyn(hex(0x6B6B6B), hex(0xA0A0A5))
    static let text3     = dyn(hex(0x9A9A9A), hex(0x6E6E73))
    static let accent    = dyn(hex(0x2F5BEA), hex(0x6B8CFF))
    static let danger    = dyn(hex(0xC93B3B), hex(0xFF6B6B))
    static let radius: CGFloat = 12
}

struct CardStyle: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }
}
extension View { func card(padding: CGFloat = 16) -> some View { modifier(CardStyle(padding: padding)) } }

// Small text button used for row hover actions — plain text, no chip background.
struct RowAction: View {
    let title: String
    var role: ButtonRole? = nil
    let action: () -> Void
    var body: some View {
        Button(role: role, action: action) {
            Text(title).font(.system(size: 12, weight: .medium))
                .foregroundStyle(role == .destructive ? Theme.danger : Theme.accent)
        }
        .buttonStyle(.plain)
    }
}
