import AppKit
import SwiftUI

/// Plain window styling. Liquid Glass is used only on the dictation bar (`DictationBar.swift`).
extension View {
    func card(cornerRadius: CGFloat = 16) -> some View { modifier(Card(cornerRadius: cornerRadius)) }

    func actionButton(prominent: Bool = false) -> some View {
        modifier(ActionButton(prominent: prominent))
    }
}

struct Card: ViewModifier {
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.separator))
    }
}

struct ActionButton: ViewModifier {
    var prominent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if prominent { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
    }
}
