import Foundation

/// Deterministic, on-device cleanup of a raw transcript. No model is involved, so the text never leaves the Mac.
enum TextCleanup {
    struct Options {
        var removeFillers = true
        var collapseStutters = true
        var voiceCommands = true
        static let all = Options()
    }

    static let fillerWords: Set<String> = ["um", "umm", "ummm", "uh", "uhh", "uhm", "er", "erm", "ah", "ahh", "hmm", "hm", "mm", "mhm", "mmm"]

    static func clean(_ raw: String, options: Options = .all) -> String {
        var text = raw
        text = removeNonSpeechTags(text)
        if options.removeFillers { text = removeFillers(text) }
        if options.collapseStutters { text = collapseStutters(text) }
        if options.voiceCommands { text = applyVoiceCommands(text) }
        text = fixPunctuationSpacing(text)
        text = normalizeWhitespace(text)
        text = capitalizeSentences(text)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lines Whisper tends to invent for silence or noise (trained on subtitled videos). A transcript that is nothing
    /// but one of these is treated as "nothing said".
    static let hallucinations: Set<String> = [
        "thanks for watching", "thank you for watching", "thanks for listening", "thank you for listening",
        "please subscribe", "like and subscribe", "don't forget to subscribe", "see you in the next video",
        "see you next time", "subtitles by the amara org community", "subtitles by amara org", "transcribed by",
        "the end", "you", "bye", "music", "silence", "blank audio", "inaudible", "foreign",
    ]

    static func isHallucination(_ text: String) -> Bool {
        let key = text.lowercased().unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) || $0 == " " ? Character($0) : Character(" ") }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ").joined(separator: " ")
        return key.isEmpty || hallucinations.contains(key)
    }

    /// Spacing for pasting at a caret: a space before when the text would otherwise glue onto a word or punctuation,
    /// and a space after when it would run into a following word.
    static func fit(_ text: String, before: String, after: String) -> String {
        guard !text.isEmpty else { return text }
        var out = text
        if let last = before.last, !last.isWhitespace, !last.isNewline, !"([{\"'“‘/-–—".contains(last) {
            out = " " + out
        }
        if let next = after.first, next.isLetter || next.isNumber {
            out += " "
        }
        return out
    }

    /// Whisper-style annotations such as `[BLANK_AUDIO]`, `(laughs)`, `*music*`, `♪`.
    static func removeNonSpeechTags(_ text: String) -> String {
        var out = text.replacingOccurrences(of: #"\[[^\]\n]{0,40}\]"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\((?:[a-z ,'-]{1,30})\)"#, with: " ", options: [.regularExpression, .caseInsensitive])
        out = out.replacingOccurrences(of: #"\*[^*\n]{1,30}\*"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: "♪", with: " ")
        return out
    }

    /// "I, um, think" → "I think"; "Um, so" → "So". Only whole words, with any punctuation glued to the filler.
    static func removeFillers(_ text: String) -> String {
        let words = fillerWords.sorted { $0.count > $1.count }.joined(separator: "|")
        // Group 1: what comes before the filler (start or space/punctuation). Group 2: punctuation glued to its end.
        let pattern = #"(?i)(^|[\s,;:—–-]+)(?:"# + words + #")(?=[\s,.!?;:—–-]|$)(\.{2,}|…|[,;:—–-]|[.!?])?(?=\s|$|[.!?])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let lead = ns.substring(with: match.range(at: 1))
            let trail = match.range(at: 2).location == NSNotFound ? "" : ns.substring(with: match.range(at: 2))
            let endsSentence = trail.count == 1 && ".!?".contains(trail)
            if trail.isEmpty {
                out += lead  // "and, uh asked" → "and, asked"
            } else if endsSentence {
                // "ok. um. fine" → "ok. fine"; "I think um." → "I think."
                let before = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if let last = before.last, !".!?".contains(last) { out += trail }
            }
            // otherwise ", uh," / "Um," / "uhh..." disappear entirely
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        out = out.replacingOccurrences(of: #"\s*,\s*,"#, with: ",", options: .regularExpression)
        out = out.replacingOccurrences(of: #"^\s*[,;:]\s*"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"([.!?])\s*[,;:]\s*"#, with: "$1 ", options: .regularExpression)
        return out
    }

    /// "I I think the the fix" → "I think the fix". Only short words repeat as stutters; "had had" is left alone.
    static func collapseStutters(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?i)\b(?!had\b)([A-Za-z']{1,3})(?:[,\s]+\1\b)+"#, with: "$1", options: .regularExpression)
    }

    /// Spoken "new line" / "new paragraph" become line breaks; punctuation before them stays, punctuation glued after goes.
    static func applyVoiceCommands(_ text: String) -> String {
        var out = text.replacingOccurrences(of: #"(?i)\s*\bnew paragraph\b[,.;:]?\s*"#, with: "\n\n", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?i)\s*\bnew line\b[,.;:]?\s*"#, with: "\n", options: .regularExpression)
        return out
    }

    static func normalizeWhitespace(_ text: String) -> String {
        var out = text.replacingOccurrences(of: #"[ \t\x{00A0}]+"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #" *\n *"#, with: "\n", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return out
    }

    static func fixPunctuationSpacing(_ text: String) -> String {
        var out = text.replacingOccurrences(of: #"[ \t]+([,.!?;:])"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"([,;:])(?=[A-Za-z])"#, with: "$1 ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"([.!?])(?=[A-Z])"#, with: "$1 ", options: .regularExpression)
        return out
    }

    /// Uppercases the first letter of the text and of every sentence/paragraph.
    static func capitalizeSentences(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var chars = Array(text)
        var capitalizeNext = true
        for i in chars.indices {
            let c = chars[i]
            if capitalizeNext, c.isLetter {
                chars[i] = Character(String(c).uppercased())
                capitalizeNext = false
            } else if c == "." || c == "!" || c == "?" || c == "\n" {
                capitalizeNext = true
            } else if !c.isWhitespace, c != "\"", c != "'", c != "(" {
                capitalizeNext = false
            }
        }
        return String(chars)
    }
}
