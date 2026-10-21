import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

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
                    HistoryList(history: history).padding(16)
                }
            }
            Divider()
            HStack {
                Text("Kept on this Mac only. Gone when you quit, or after 12 hours. Drop an audio or video file here to transcribe it.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Choose File…") { FilePicker.chooseAndTranscribe() }
                    .actionButton()
                Button("Delete All", role: .destructive) { HistoryPlayer.shared.stop(); history.clear() }
                    .actionButton()
                    .disabled(history.entries.isEmpty)
            }
            .padding(12)
        }
        .onAppear { history.purge() }
        .transcribesDroppedFiles()
    }
}

extension View {
    /// Any of our windows accepts an audio/video file dropped on it and transcribes it into History.
    func transcribesDroppedFiles() -> some View { modifier(DropToTranscribe()) }
}

/// The drop target, with a "Drop to transcribe" cover while a file is dragged over the window so it's obvious
/// the window takes files.
private struct DropToTranscribe: ViewModifier {
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if targeted {
                    ZStack {
                        Color(nsColor: .windowBackgroundColor).opacity(0.92)
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                            .padding(12)
                        VStack(spacing: 10) {
                            Icon("waveform", size: 34).foregroundStyle(Color.accentColor)
                            Text("Drop to transcribe").font(.title3.weight(.semibold))
                            Text("Audio or video · the text goes to History and your clipboard").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: targeted)
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                for provider in providers {
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                        guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                        DispatchQueue.main.async { DictationController.shared.transcribeFiles([url]) }
                    }
                }
                return !providers.isEmpty
            }
    }
}

/// The entries as cards, newest first. Used by the History window and inline in Settings → Privacy.
struct HistoryList: View {
    @ObservedObject var history: HistoryStore

    var body: some View {
        LazyVStack(spacing: 10) {
            ForEach(history.entries) { entry in
                HistoryRow(entry: entry, history: history).card(cornerRadius: 14)
            }
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    @ObservedObject var history: HistoryStore
    @ObservedObject private var player = HistoryPlayer.shared
    @ObservedObject private var controller = DictationController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = entry.error {
                Label { Text(error) } icon: { Icon("x-circle", size: 14).foregroundStyle(.red) }
                    .foregroundStyle(.secondary)
            } else {
                Text(entry.text).textSelection(.enabled)
            }
            if let source = entry.source {
                Label { Text(source).lineLimit(1).truncationMode(.middle) } icon: { Icon("text-lines", size: 11) }
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(entry.date, style: .relative) + Text(" ago")
                if !entry.failed {
                    Text("·")
                    Text(entry.engine)
                }
                Text("·")
                Text(String(format: "%.0fs", entry.durationSeconds))
                Spacer()
                if entry.audioFileName != nil {
                    Button("Retry") { controller.retry(entry) }
                        .help(entry.failed ? "Transcribe this recording again" : "Transcribe again; the result goes to the clipboard")
                        .disabled(controller.state.isActive)
                }
                if !entry.failed {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.text, forType: .string)
                    }
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
            .lineLimit(1)
            .actionButton()
            .controlSize(.small)
            if let details = entry.details {
                DisclosureGroup("Details") {
                    Text(details.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .font(.caption)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
