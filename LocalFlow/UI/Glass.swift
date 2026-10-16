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

/// The faintly tinted backdrop System Settings and Finder use (`underWindowBackground`): opaque enough to read,
/// still picks up a hint of the desktop colour. Used behind every content window; the bar keeps its real glass.
struct WindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

extension View {
    func windowMaterial() -> some View { background(WindowMaterial().ignoresSafeArea()) }
}
