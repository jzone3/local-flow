import Foundation

/// The dictionary: one list of words and phrases the user wants spelled their way.
/// Each line is a term ("GitHub"); a line "misheard => Correct" is an explicit replacement.
struct Vocabulary: Equatable {
    struct Rule: Equatable {
        let heard: String
        let correct: String
    }

    var terms: [String]
    var rules: [Rule]

    static let empty = Vocabulary(terms: [], rules: [])

    init(terms: [String], rules: [Rule]) {
        self.terms = terms
        self.rules = rules
    }

    init(text: String) {
        var terms: [String] = []
        var rules: [Rule] = []
        var ruleTargets: [String] = []
        var seen = Set<String>()
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if let range = line.range(of: "=>") {
                let heard = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                let correct = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                guard !heard.isEmpty, !correct.isEmpty else { continue }
                rules.append(Rule(heard: heard, correct: correct))
                ruleTargets.append(correct)
            } else if seen.insert(line.lowercased()).inserted {
                terms.append(line)
            }
        }
        // Rule targets go last so `text` → `init(text:)` round-trips in the same order.
        for target in ruleTargets where seen.insert(target.lowercased()).inserted { terms.append(target) }
        self.terms = terms
        self.rules = rules
    }

    var text: String {
        let ruleTargets = Set(rules.map { $0.correct.lowercased() })
        var lines = terms.filter { !ruleTargets.contains($0.lowercased()) }
        lines += rules.map { "\($0.heard) => \($0.correct)" }
        return lines.joined(separator: "\n")
    }

    /// Terms as a hint for the speech model. Whisper's prompt window is ~224 tokens, so the list is capped.
    func promptHint(limit: Int = 80) -> String {
        let picked = Array(terms.prefix(limit))
        guard !picked.isEmpty else { return "" }
        // A plain spoken sentence, not a bare list: a comma list of capitalized terms biases Whisper into Title Case.
        let list = picked.count > 1 ? picked.dropLast().joined(separator: ", ") + " and " + picked.last! : picked[0]
        return "Okay, so here are some names and terms I use a lot: " + list + ". Let's get started."
    }

    /// Terms safe for keyword/keyterm API fields (ElevenLabs: ≤5 words, <50 chars, no brackets).
    func keyterms(limit: Int = 200) -> [String] {
        terms.compactMap { term in
            let cleaned = term.replacingOccurrences(of: #"[<>{}\[\]\\]"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty, cleaned.count < 50, cleaned.split(separator: " ").count <= 5 else { return nil }
            return cleaned
        }.prefix(limit).map { $0 }
    }

    /// Fixes spelling of known terms in a transcript: explicit rules first, then every term whose spelling the
    /// model is likely to miss (mixed case, digits or punctuation inside, multi-word) matched case-insensitively
    /// against its spoken forms ("git hub", "chat g p t", "nextjs").
    func applySpelling(to text: String) -> String {
        var out = text
        for rule in rules {
            out = replaceWholeWords(in: out, pattern: NSRegularExpression.escapedPattern(for: rule.heard), with: rule.correct)
        }
        for term in terms where needsCorrection(term) {
            let variants = spokenVariants(of: term)
            guard !variants.isEmpty else { continue }
            let pattern = variants.map { NSRegularExpression.escapedPattern(for: $0) }
                .map { $0.replacingOccurrences(of: " ", with: #"[\s-]*"#) }
                .joined(separator: "|")
            out = replaceWholeWords(in: out, pattern: "(?:\(pattern))", with: term)
        }
        return out
    }

    private func needsCorrection(_ term: String) -> Bool {
        let letters = term.filter { $0.isLetter }
        guard letters.count >= 3 else { return false }
        let lower = term.lowercased(), upper = term.uppercased()
        let hasInnerCapital = term.dropFirst().contains { $0.isUppercase }
        let isAllCaps = term == upper && term != lower
        let hasOddChars = term.contains { $0 == "." || $0 == "-" || $0.isNumber }
        return hasInnerCapital || isAllCaps || hasOddChars || term.contains(" ") || term.first?.isUppercase == true
    }

    private func spokenVariants(of term: String) -> [String] {
        var variants = Set<String>()
        let lower = term.lowercased()
        variants.insert(lower)
        variants.insert(lower.replacingOccurrences(of: #"[.\-]"#, with: " ", options: .regularExpression))
        variants.insert(lower.replacingOccurrences(of: #"[.\- ]"#, with: "", options: .regularExpression))
        // camelCase / PascalCase boundaries: "ChatGPT" → "chat gpt", "iPhone" → "i phone"
        let split = term.replacingOccurrences(of: #"([a-z])([A-Z])"#, with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: #"([A-Z]+)([A-Z][a-z])"#, with: "$1 $2", options: .regularExpression)
        variants.insert(split.lowercased())
        // Acronyms are often heard letter by letter: "OKR" → "o k r", "ChatGPT" → "chat g p t"
        let spelled = split.split(separator: " ").map { word -> String in
            let w = String(word)
            let isAcronym = w == w.uppercased() && w != w.lowercased() && w.count <= 6
            return isAcronym ? w.lowercased().map(String.init).joined(separator: " ") : w.lowercased()
        }.joined(separator: " ")
        variants.insert(spelled)
        return variants.filter { !$0.isEmpty && $0.count >= 2 }.sorted { $0.count > $1.count }
    }

    private func replaceWholeWords(in text: String, pattern: String, with replacement: String) -> String {
        let full = #"(?i)(?<![A-Za-z0-9])"# + pattern + #"(?![A-Za-z0-9])"#
        guard let regex = try? NSRegularExpression(pattern: full) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let escaped = NSRegularExpression.escapedTemplate(for: replacement)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: escaped)
    }
}

extension Vocabulary {
    /// Shipped with the app; words speech models most often misspell for people who work on computers.
    static let defaultText = """
    # One term per line. Add your own names, products and jargon.
    # Use "heard => Correct" to force a replacement, e.g. "jay zed => JZ".
    ChatGPT
    OpenAI
    Claude
    Anthropic
    Gemini
    Devin
    Cognition
    Cursor
    GitHub
    GitLab
    iPhone
    iPad
    macOS
    iOS
    Slack
    Notion
    Figma
    Linear
    Jira
    Zoom
    Gmail
    Google Docs
    LinkedIn
    TikTok
    YouTube
    WhatsApp
    Vercel
    Next.js
    TypeScript
    JavaScript
    Python
    Kubernetes
    PostgreSQL
    SQL
    API
    SDK
    OKR
    KPI
    PR
    CI/CD
    Wi-Fi
    Bluetooth
    Stripe
    Shopify
    HubSpot
    Salesforce
    Airtable
    Zapier
    Loom
    Calendly
    Superhuman
    Whisper
    LLM
    GPU
    SaaS
    """
}
