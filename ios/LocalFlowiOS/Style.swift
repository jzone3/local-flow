import SwiftUI
import UIKit

/// The Mac app's look on iPhone: its glyphs, its off-white window color, its cards and setup headers.

/// The Mac app's own glyphs (LocalFlow/Resources/Assets.xcassets/Icons), tinted like any template image.
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
}

extension Color {
    /// Same fixed off-white as the Mac windows (#F5F5F7, #1C1C1E in dark mode).
    static let window = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        : UIColor(red: 0.961, green: 0.961, blue: 0.965, alpha: 1) })
}

extension View {
    /// A solid card, the Mac setup window's pre-glass card.
    func card(cornerRadius: CGFloat = 16) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(Color(.secondarySystemGroupedBackground), in: shape)
            .overlay(shape.strokeBorder(Color(.separator).opacity(0.6)))
    }

    func windowBackground() -> some View { background(Color.window.ignoresSafeArea()) }
}

/// The Mac setup window's step heading: optional glyph, 24 pt semibold title, secondary subtitle.
struct SetupHeader: View {
    let title: String
    let subtitle: String
    var icon: String?

    var body: some View {
        VStack(spacing: 8) {
            if let icon {
                Icon(icon, size: 40)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
            Text(title).font(.system(size: 24, weight: .semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A row in a setup card: glyph (or step number), title, detail, optional trailing control.
struct SetupRow<Trailing: View>: View {
    let leading: AnyView
    let title: String
    let detail: String
    @ViewBuilder var trailing: () -> Trailing

    init(icon: String, _ title: String, _ detail: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.leading = AnyView(Icon(icon, size: 20).foregroundStyle(.secondary))
        self.title = title
        self.detail = detail
        self.trailing = trailing
    }

    init(step: Int, _ title: String, _ detail: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.leading = AnyView(Text("\(step)").font(.system(size: 17, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary))
        self.title = title
        self.detail = detail
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 14) {
            leading.frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }
}

struct RowDivider: View {
    var body: some View { Divider().padding(.leading, 58) }
}

/// The app icon, for the welcome heading. AppIconArt is a symlink to the icon PNG, so there is one copy.
struct AppIconImage: View {
    var size: CGFloat = 104

    var body: some View {
        Group {
            if let image = UIImage(named: "AppIconArt") {
                Image(uiImage: image).resizable()
            } else {
                RoundedRectangle(cornerRadius: size * 0.22).fill(Color.primary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 14, y: 8)
    }
}
