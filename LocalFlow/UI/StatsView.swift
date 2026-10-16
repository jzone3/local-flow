import Charts
import SwiftUI

/// Settings → Stats: lifetime numbers, words per day for the last 30 days, and a typing-vs-speaking speed test.
struct StatsView: View {
    @ObservedObject private var stats = StatsStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    StatTile(value: Self.compact(stats.totalWords), label: "Words dictated")
                    StatTile(value: stats.speakingWPM > 0 ? "\(Int(stats.speakingWPM.rounded()))" : "–",
                             label: "Avg speaking speed", unit: stats.speakingWPM > 0 ? "WPM" : nil)
                    StatTile(value: Self.duration(stats.secondsSaved), label: "Time saved")
                    StatTile(value: Self.compact(stats.totalDictations), label: "Dictations")
                }
                WordsChart(days: stats.dailyWords())
                SpeedTestCard()
                if stats.totalDictations == 0 {
                    Text("Hold \(AppSettings.shared.hotkey.displayName) and talk anywhere — your numbers show up here. Counts and timings only; no transcripts are kept.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(stats.measuredTypingWPM == nil
                         ? "Time saved assumes \(Int(StatsStore.defaultTypingWPM)) WPM typing until you take the speed test. Counts and timings only; no transcripts are kept."
                         : "Time saved uses your measured \(Int(stats.typingWPM.rounded())) WPM typing speed. Counts and timings only; no transcripts are kept.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    static func compact(_ n: Int) -> String {
        switch n {
        case ..<10_000: return n.formatted()
        case ..<1_000_000: return String(format: "%.1fk", Double(n) / 1_000).replacingOccurrences(of: ".0k", with: "k")
        default: return String(format: "%.1fM", Double(n) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
        }
    }

    static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return seconds > 0 ? "<1 min" : "0 min" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = Double(minutes) / 60
        return hours < 10 ? String(format: "%.1f h", hours).replacingOccurrences(of: ".0 h", with: " h") : "\(Int(hours.rounded())) h"
    }
}

struct StatTile: View {
    let value: String
    let label: String
    var unit: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                if let unit { Text(unit).font(.caption).foregroundStyle(.secondary) }
            }
            .lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card(cornerRadius: 12)
    }
}

struct WordsChart: View {
    let days: [StatsStore.Day]

    private var total: Int { days.reduce(0) { $0 + $1.words } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Last 30 days").font(.subheadline).fontWeight(.medium)
                Spacer()
                Text(total > 0 ? "\(total.formatted()) words" : "No dictations yet").font(.caption).foregroundStyle(.secondary)
            }
            Chart(days) { day in
                BarMark(x: .value("Day", day.date, unit: .day), y: .value("Words", day.words), width: .ratio(0.6))
                    .foregroundStyle(day.words > 0 ? Color.accentColor : Color.secondary.opacity(0.25))
                    .cornerRadius(2)
            }
            .chartYScale(domain: 0...max(10, (days.map(\.words).max() ?? 0)))
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                    AxisGridLine().foregroundStyle(.clear)
                    AxisTick().foregroundStyle(.clear)
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day()).font(.caption2)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(.separator)
                    AxisValueLabel().font(.caption2)
                }
            }
            .frame(height: 120)
        }
        .padding(14)
        .card(cornerRadius: 12)
    }
}

/// Type a sentence (timed from the first keystroke), then dictate the same sentence into the second field.
struct SpeedTestCard: View {
    static let sample = "I talk faster than I type. The meeting moved to Thursday afternoon. Please send the notes when you get a chance."

    @ObservedObject private var stats = StatsStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var typed = ""
    @State private var typingStart: Date?
    @State private var typingWPM: Double?
    @State private var dictated = ""
    @State private var dictationBaseline: Int?
    @State private var speakingWPM: Double?
    @FocusState private var focus: Field?

    enum Field { case typing, speaking }

    private var sampleWords: Int { StatsStore.wordCount(Self.sample) }
    private var typingDone: Bool { typingWPM != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Speed test").font(.subheadline).fontWeight(.medium)
                Spacer()
                if typingStart != nil || typingDone || speakingWPM != nil {
                    Button("Start Over") { reset() }.actionButton().controlSize(.small)
                }
            }
            Text(Self.sample)
                .font(.body)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            step(number: 1, title: "Type it", result: typingWPM.map { "\(Int($0.rounded())) WPM" }) {
                TextField(typingDone ? "Done" : "Start typing — the clock starts on your first key", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .typing)
                    .disabled(typingDone)
                    .onChange(of: typed) { _, text in typingChanged(text) }
                if let typingStart, !typingDone {
                    TimelineView(.periodic(from: typingStart, by: 0.1)) { context in
                        Text(String(format: "%.1f s", context.date.timeIntervalSince(typingStart)))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }

            step(number: 2, title: "Say it", result: speakingWPM.map { "\(Int($0.rounded())) WPM" }) {
                TextField(typingDone ? "Click here, then hold \(settings.hotkey.displayName) and read the sentence" : "Finish step 1 first",
                          text: $dictated)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .speaking)
                    .disabled(!typingDone || speakingWPM != nil)
            }
            .onChange(of: stats.records.count) { _, count in dictationArrived(count: count) }
            .onChange(of: focus) { _, field in
                if field == .speaking, dictationBaseline == nil { dictationBaseline = stats.records.count }
            }

            if let typingWPM, let speakingWPM {
                let ratio = speakingWPM / max(typingWPM, 1)
                Text(ratio >= 1.05
                     ? "You speak \(Self.ratioText(ratio)) faster than you type."
                     : "You speak about as fast as you type.")
                    .font(.body).fontWeight(.medium)
                Text("Time saved now uses your \(Int(typingWPM.rounded())) WPM typing speed.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !typingDone {
                Text("Punctuation and capitals don't count against you.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .card(cornerRadius: 12)
    }

    @ViewBuilder
    private func step<Content: View>(number: Int, title: String, result: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(number). \(title)").font(.caption).fontWeight(.medium).foregroundStyle(.secondary)
                Spacer()
                if let result {
                    Label { Text(result) } icon: { Icon("check-circle", size: 12) }
                        .font(.caption).monospacedDigit().foregroundStyle(.green)
                }
            }
            content()
        }
    }

    private func typingChanged(_ text: String) {
        guard !typingDone else { return }
        if typingStart == nil, !text.isEmpty { typingStart = Date() }
        guard let typingStart, Self.normalize(text) == Self.normalize(Self.sample) else { return }
        let minutes = max(Date().timeIntervalSince(typingStart), 1) / 60
        let wpm = Double(sampleWords) / minutes
        typingWPM = wpm
        stats.measuredTypingWPM = wpm
        dictationBaseline = stats.records.count
        DispatchQueue.main.async { focus = .speaking }
    }

    private func dictationArrived(count: Int) {
        guard typingDone, speakingWPM == nil, let baseline = dictationBaseline, count > baseline, let latest = stats.latest else { return }
        speakingWPM = latest.wordsPerMinute
        focus = nil
    }

    private func reset() {
        typed = ""
        typingStart = nil
        typingWPM = nil
        dictated = ""
        dictationBaseline = nil
        speakingWPM = nil
        focus = .typing
    }

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted).joined()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func ratioText(_ ratio: Double) -> String {
        let rounded = (ratio * 10).rounded() / 10
        return rounded == rounded.rounded() ? "\(Int(rounded))×" : String(format: "%.1f×", rounded)
    }
}
