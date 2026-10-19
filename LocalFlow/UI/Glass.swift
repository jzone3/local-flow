import AppKit
import SwiftUI

/// Window styling: solid windows, stock macOS controls. On macOS 26 buttons and cards pick up the system
/// glass button style / a glass card surface; older systems get the plain equivalents.
extension View {
    func card(cornerRadius: CGFloat = 16) -> some View { modifier(Card(cornerRadius: cornerRadius)) }

    func actionButton(prominent: Bool = false) -> some View {
        modifier(ActionButton(prominent: prominent))
    }
}

struct Card: ViewModifier {
    var cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(.separator))
        }
    }
}

struct ActionButton: ViewModifier {
    var prominent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { content.buttonStyle(.glassProminent) } else { content.buttonStyle(.glass) }
        } else {
            if prominent { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
        }
    }
}

/// Fixed off-white (#F5F5F7, #1C1C1E in dark mode) behind every content window: no effect view, no tint from the
/// desktop, so the windows look the same on every wallpaper. The bar keeps its real glass.
private let windowBackground = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        : NSColor(srgbRed: 0.961, green: 0.961, blue: 0.965, alpha: 1)
}

extension View {
    func windowMaterial() -> some View { background(Color(nsColor: windowBackground).ignoresSafeArea()) }
}
