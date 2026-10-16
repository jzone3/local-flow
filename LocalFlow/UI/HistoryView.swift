import SwiftUI

struct HistoryView: View {
    @ObservedObject private var history = HistoryStore.shared

    var body: some View {
        VStack(spacing: 0) {
            if history.entries.isEmpty {
                ContentUnavailableView { Label { Text("Nothing yet") } icon: { Icon("history", size: 44).foregroundStyle(.secondary) } } description: { Text("Dictations from this session show up here and are gone when you quit, or after 12 hours.") }
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(history.entries) { entry in
                            HistoryRow(entry: entry, history: history).card(cornerRadius: 14)
                        }
                    }
                    .padding(16)
                }
            }
            Divider()
            HStack {
                Text("Kept on this Mac only. Gone when you quit, or after 12 hours.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Delete All", role: .destructive) { history.clear() }
                    .actionButton()
                    .disabled(history.entries.isEmpty)
            }
            .padding(12)
        }
        .onAppear { history.purge() }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    @ObservedObject var history: HistoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.text).textSelection(.enabled)
            HStack(spacing: 8) {
                Text(entry.date, style: .relative) + Text(" ago")
                Text("·")
                Text(entry.engine)
                Text("·")
                Text(String(format: "%.0fs", entry.durationSeconds))
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                }
                if let url = history.audioURL(for: entry), FileManager.default.fileExists(atPath: url.path) {
                    Button("Play") { NSWorkspace.shared.open(url) }
                }
                Button("Delete", role: .destructive) { history.remove(entry) }
            }
            .font(.caption).foregroundStyle(.secondary)
            .actionButton()
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
