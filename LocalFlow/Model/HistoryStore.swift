import AppKit
import Combine
import Foundation

struct HistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    var date: Date
    var text: String
    var rawText: String
    var engine: String
    var durationSeconds: Double
    var audioFileName: String?
    /// Added later; entries written by older builds decode without it.
    var details: TranscriptionDetails?
    /// Set when the dictation failed: the recording is kept so it can be retried; `text` is empty.
    var error: String?

    var failed: Bool { error != nil }
}

/// Transcripts and their recordings: kept only on this Mac, only while the app is running (wiped on quit and on
/// launch), and never longer than 12 hours.
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var entries: [HistoryEntry] = []
    let directory: URL
    private let indexURL: URL
    private var purgeTimer: Timer?

    init(directory: URL = AppSettings.supportDirectory.appendingPathComponent("History", isDirectory: true)) {
        self.directory = directory
        indexURL = directory.appendingPathComponent("history.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        excludeFromBackups()
        wipe()
        purgeTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in self?.purge() }
        for name in [NSApplication.didBecomeActiveNotification, NSWorkspace.didWakeNotification] {
            let center = name == NSWorkspace.didWakeNotification ? NSWorkspace.shared.notificationCenter : NotificationCenter.default
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.purge() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.wipe()
        }
    }

    /// Removes everything in the History folder, index included. Called on launch and on quit.
    func wipe() {
        entries = []
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        files.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    /// Time Machine would otherwise keep copies of recordings long after the app deleted them.
    private func excludeFromBackups() {
        var dir = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }

    func audioURL(for entry: HistoryEntry) -> URL? {
        entry.audioFileName.map { directory.appendingPathComponent($0) }
    }

    func newAudioURL(id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).wav")
    }

    func add(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        save()
    }

    /// Replaces an entry; the list stays newest-first, so a re-dated (retried) entry moves to the top.
    func update(_ entry: HistoryEntry) {
        guard entries.contains(where: { $0.id == entry.id }) else { return }
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: entries.firstIndex { $0.date < entry.date } ?? entries.endIndex)
        save()
    }

    func remove(_ entry: HistoryEntry) {
        if let url = audioURL(for: entry) { try? FileManager.default.removeItem(at: url) }
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        entries.forEach { if let url = audioURL(for: $0) { try? FileManager.default.removeItem(at: url) } }
        entries = []
        save()
        purgeOrphans(olderThan: Date())
    }

    /// Drops everything older than the retention window, including audio files with no index entry.
    func purge(now: Date = Date(), retention: TimeInterval = AppSettings.historyRetention) {
        let cutoff = now.addingTimeInterval(-retention)
        let expired = entries.filter { $0.date < cutoff }
        guard !expired.isEmpty || hasOrphans(olderThan: cutoff) else { return }
        expired.forEach { if let url = audioURL(for: $0) { try? FileManager.default.removeItem(at: url) } }
        entries.removeAll { $0.date < cutoff }
        save()
        purgeOrphans(olderThan: cutoff)
    }

    private func hasOrphans(olderThan cutoff: Date) -> Bool {
        audioFiles().contains { ($0.modified ?? .distantPast) < cutoff }
    }

    private func purgeOrphans(olderThan cutoff: Date) {
        let known = Set(entries.compactMap(\.audioFileName))
        for file in audioFiles() where !known.contains(file.url.lastPathComponent) || (file.modified ?? .distantPast) < cutoff {
            try? FileManager.default.removeItem(at: file.url)
        }
    }

    private func audioFiles() -> [(url: URL, modified: Date?)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "wav" }.map {
            ($0, try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: indexURL, options: [.atomic, .completeFileProtection])
    }
}
