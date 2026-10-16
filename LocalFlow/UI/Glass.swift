import AppKit
import SwiftUI

/// Liquid Glass helpers. macOS 26 gets the real thing; 14/15 get the closest material look.
extension View {
    func glassCard(cornerRadius: CGFloat = 16) -> some View { modifier(GlassCard(cornerRadius: cornerRadius)) }
    func glassButton(prominent: Bool = false) -> some View { modifier(GlassButton(prominent: prominent)) }
}

struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.separator))
        }
    }
}

struct GlassButton: ViewModifier {
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

/// Translucent window backdrop so the glass controls have something to refract.
struct WindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
