import SwiftUI

struct HistoryView: View {
    @ObservedObject private var history = HistoryStore.shared

    var body: some View {
        VStack(spacing: 0) {
            if history.entries.isEmpty {
                ContentUnavailableView("Nothing yet", systemImage: "clock", description: Text("Dictations from the last 12 hours show up here, then disappear."))
            } else {
                List(history.entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
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
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            }
            Divider()
            HStack {
                Text("Kept on this Mac only. Auto-deleted after 12 hours.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Delete All", role: .destructive) { history.clear() }.disabled(history.entries.isEmpty)
            }
            .padding(10)
        }
    }
}
