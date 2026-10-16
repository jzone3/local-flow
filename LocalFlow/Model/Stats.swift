import Combine
import Foundation

struct DictationRecord: Codable, Equatable {
    let date: Date
    let words: Int
    let seconds: Double

    var wordsPerMinute: Double { seconds > 0 ? Double(words) / (seconds / 60) : 0 }
}

/// Lifetime dictation counts (date, word count, seconds spoken per dictation) and the typing speed from the speed
/// test. Lives in its own stats.json in Application Support — not in the History folder, which is wiped on quit.
/// Never stores any transcript text.
final class StatsStore: ObservableObject {
    static let shared = StatsStore()
    static let defaultTypingWPM = 40.0

    @Published private(set) var records: [DictationRecord] = []
    /// Words per minute measured by the speed test; nil until the user has run it.
    @Published var measuredTypingWPM: Double? { didSet { save() } }

    private let fileURL: URL
    private struct File: Codable { var records: [DictationRecord]; var typingWPM: Double? }

    init(fileURL: URL = AppSettings.supportDirectory.appendingPathComponent("stats.json")) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL), let file = try? JSONDecoder().decode(File.self, from: data) {
            records = file.records
            measuredTypingWPM = file.typingWPM
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["LOCALFLOW_SEED_STATS"] != nil, records.isEmpty { seedSampleData() }
        #endif
    }

    func record(words: Int, seconds: Double, date: Date = Date()) {
        guard words > 0, seconds > 0 else { return }
        records.append(DictationRecord(date: date, words: words, seconds: seconds))
        save()
    }

    func reset() {
        records = []
        measuredTypingWPM = nil
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    // MARK: Derived numbers

    var totalWords: Int { records.reduce(0) { $0 + $1.words } }
    var totalDictations: Int { records.count }
    var totalSeconds: Double { records.reduce(0) { $0 + $1.seconds } }
    var latest: DictationRecord? { records.last }

    /// Lifetime average speaking speed: all words over all seconds spoken.
    var speakingWPM: Double { totalSeconds > 0 ? Double(totalWords) / (totalSeconds / 60) : 0 }

    var typingWPM: Double { measuredTypingWPM ?? Self.defaultTypingWPM }

    /// Seconds saved versus typing the same words: words/typingWPM − words/speakingWPM, never negative.
    var secondsSaved: Double {
        guard totalWords > 0, speakingWPM > 0 else { return 0 }
        let typingMinutes = Double(totalWords) / typingWPM
        let speakingMinutes = Double(totalWords) / speakingWPM
        return max(0, (typingMinutes - speakingMinutes) * 60)
    }

    struct Day: Identifiable {
        let date: Date
        let words: Int
        var id: Date { date }
    }

    /// Words per day for the last `days` days, oldest first, zero-filled.
    func dailyWords(days: Int = 30, calendar: Calendar = .current, now: Date = Date()) -> [Day] {
        let today = calendar.startOfDay(for: now)
        var buckets: [Date: Int] = [:]
        for record in records {
            let day = calendar.startOfDay(for: record.date)
            buckets[day, default: 0] += record.words
        }
        return (0..<days).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return Day(date: day, words: buckets[day] ?? 0)
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(File(records: records, typingWPM: measuredTypingWPM)) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }

    #if DEBUG
    /// `LOCALFLOW_SEED_STATS=1` fills in a month of made-up dictations so the Stats tab can be checked without a mic.
    private func seedSampleData() {
        var generator = SystemRandomNumberGenerator()
        for offset in stride(from: 29, through: 0, by: -1) where offset % 7 != 3 {
            let day = Calendar.current.date(byAdding: .day, value: -offset, to: Date())!
            for _ in 0..<Int.random(in: 1...6, using: &generator) {
                let words = Int.random(in: 8...90, using: &generator)
                let wpm = Double.random(in: 120...170, using: &generator)
                records.append(DictationRecord(date: day, words: words, seconds: Double(words) / wpm * 60))
            }
        }
    }
    #endif
}
