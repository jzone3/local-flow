import AppKit
import SwiftUI

/// The app's own glyphs (Assets.xcassets/Icons, template PNGs) — no SF Symbols anywhere in the UI.
/// Tinted by `foregroundStyle` like any template image.
struct Icon: View {
    let name: String
    var size: CGFloat = 16

    init(_ name: String, size: CGFloat = 16) {
        self.name = name
        self.size = size
    }

    var body: some View {
        Image(name)
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }

    /// For AppKit-sized places (menu bar, tab items) where a SwiftUI frame does not control the size.
    static func nsImage(_ name: String, size: CGFloat) -> NSImage {
        let image = NSImage(named: name)?.copy() as? NSImage ?? NSImage(size: NSSize(width: size, height: size))
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        return image
    }
}

/// Radio control drawn from shapes (model list, pack tiles).
struct Radio: View {
    var on: Bool
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            Circle().strokeBorder(on ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: on ? size * 0.3 : 1)
            if on { Circle().fill(Color.white).frame(width: size * 0.4, height: size * 0.4) }
        }
        .frame(width: size, height: size)
    }
}
