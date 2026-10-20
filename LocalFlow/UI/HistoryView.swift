import AVFoundation
import SwiftUI

/// Plays one history recording at a time, inline; stops when the row, the entry or the window goes away.
final class HistoryPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = HistoryPlayer()
    @Published private(set) var playingID: UUID?
    private var player: AVAudioPlayer?

    func toggle(_ url: URL, id: UUID) {
        if playingID == id { stop(); return }
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.delegate = self
        self.player = player
        playingID = id
        player.play()
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { if self.player === player { self.stop() } }
    }
}

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
                Button("Delete All", role: .destructive) { HistoryPlayer.shared.stop(); history.clear() }
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
    @ObservedObject private var player = HistoryPlayer.shared

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
                    Button(player.playingID == entry.id ? "Stop" : "Play") { player.toggle(url, id: entry.id) }
                }
                Button("Delete", role: .destructive) {
                    if player.playingID == entry.id { player.stop() }
                    history.remove(entry)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .actionButton()
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
