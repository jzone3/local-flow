import SwiftUI

/// "What do you do?" — multi-select of the built-in word packs. Shared by setup and Settings → Dictionary.
struct PackPicker: View {
    @ObservedObject private var settings = AppSettings.shared
    var columns = 2

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
            ForEach(VocabularyPack.all) { pack in
                let on = settings.dictionaryPacks.contains(pack.id)
                Button {
                    settings.setPack(pack.id, on: !on)
                } label: {
                    HStack(spacing: 8) {
                        Icon(pack.icon, size: 16)
                            .foregroundStyle(on ? Color.accentColor : .secondary)
                            .frame(width: 18)
                        Text(pack.name).lineLimit(1)
                        Spacer(minLength: 4)
                        if on {
                            Icon("check-circle", size: 15).foregroundStyle(Color.accentColor)
                        } else {
                            Circle().strokeBorder(Color.secondary.opacity(0.45), lineWidth: 1).frame(width: 15, height: 15)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected] : [])
                .background(on ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(on ? Color.accentColor.opacity(0.7) : Color(nsColor: .separatorColor), lineWidth: on ? 1.5 : 1)
                )
                .help("\(pack.terms.count) terms")
            }
        }
    }
}
