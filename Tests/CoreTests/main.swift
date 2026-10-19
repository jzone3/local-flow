import Foundation

var failures = 0
func expect(_ actual: String, _ expected: String, _ label: String, line: Int = #line) {
    if actual != expected {
        failures += 1
        print("FAIL \(label) (line \(line))\n  expected: \(expected.debugDescription)\n  actual:   \(actual.debugDescription)")
    }
}
func expect(_ condition: Bool, _ label: String, line: Int = #line) {
    if !condition { failures += 1; print("FAIL \(label) (line \(line))") }
}

// TextCleanup
expect(TextCleanup.clean("Um, so I pushed the fix and, uh, asked for a review."), "So I pushed the fix and asked for a review.", "fillers")
expect(TextCleanup.clean("I I think the the fix works."), "I think the fix works.", "stutters")
expect(TextCleanup.clean("He had had enough."), "He had had enough.", "long repeats kept")
expect(TextCleanup.clean("[BLANK_AUDIO] hello there (laughs)"), "Hello there", "non-speech tags")
expect(TextCleanup.clean("first point. new paragraph. second point"), "First point.\n\nSecond point", "new paragraph")
expect(TextCleanup.clean("one, new line, two"), "One,\nTwo", "new line")
expect(TextCleanup.clean("hello .  world ,again"), "Hello. World, again", "punctuation spacing")
expect(TextCleanup.clean("the umbrella is here"), "The umbrella is here", "filler not inside words")
expect(TextCleanup.clean("Umm, uhh... yes"), "Yes", "leading fillers with ellipsis")
expect(TextCleanup.clean("hmm"), "", "only filler")
expect(TextCleanup.clean("ok. um. fine"), "Ok. Fine", "filler as sentence")
expect(TextCleanup.clean("Um, so I pushed", options: .init(removeFillers: false)), "Um, so I pushed", "fillers kept when off")

expect(TextCleanup.isHallucination("Thanks for watching!"), "hallucination: thanks for watching")
expect(TextCleanup.isHallucination(" you "), "hallucination: lone you")
expect(TextCleanup.isHallucination(""), "hallucination: empty")
expect(!TextCleanup.isHallucination("Thank you for the help today."), "real sentence kept")
expect(!TextCleanup.isHallucination("Thank you."), "short real reply kept")
expect(TextCleanup.fit("And more words.", before: "re", after: ""), " And more words.", "fit: space after word")
expect(TextCleanup.fit("Middle.", before: "rt", after: " end"), " Middle.", "fit: space before, none before existing space")
expect(TextCleanup.fit("Middle", before: "rt", after: "end"), " Middle ", "fit: space both sides")
expect(TextCleanup.fit("Hello", before: "", after: ""), "Hello", "fit: empty field untouched")
expect(TextCleanup.fit("Hello", before: "e ", after: ""), "Hello", "fit: after a space untouched")
expect(TextCleanup.fit("Hello", before: "e\n", after: ""), "Hello", "fit: after newline untouched")
expect(TextCleanup.fit("quoted", before: "(\"", after: "\")"), "quoted", "fit: inside quotes/brackets untouched")

// Vocabulary
let vocab = Vocabulary(text: """
# comment
GitHub
ChatGPT
Next.js
iPhone
Devin
OKR
jay zed => JZ
Local Flow
""")
expect(vocab.terms.count == 8, "terms parsed (\(vocab.terms.count))")
expect(vocab.rules.count == 1, "rules parsed")
expect(vocab.applySpelling(to: "I pushed to git hub and github and GITHUB."), "I pushed to GitHub and GitHub and GitHub.", "github variants")
expect(vocab.applySpelling(to: "ask chat gpt or chat g p t or chatgpt"), "ask ChatGPT or ChatGPT or ChatGPT", "chatgpt variants")
expect(vocab.applySpelling(to: "use nextjs or next js or next.js"), "use Next.js or Next.js or Next.js", "next.js variants")
expect(vocab.applySpelling(to: "my i phone and iphone"), "my iPhone and iPhone", "iphone")
expect(vocab.applySpelling(to: "devin opened it"), "Devin opened it", "capitalized name")
expect(vocab.applySpelling(to: "the o k r and okr"), "the OKR and OKR", "acronym letters")
expect(vocab.applySpelling(to: "ask jay zed"), "ask JZ", "explicit rule")
expect(vocab.applySpelling(to: "local flow and local-flow"), "Local Flow and Local Flow", "multi-word")
expect(vocab.applySpelling(to: "devinsdinner"), "devinsdinner", "no partial word match")
expect(vocab.promptHint(limit: 3), "Okay, so here are some names and terms I use a lot: GitHub, ChatGPT and Next.js. Let's get started.", "prompt hint")
expect(Vocabulary.isPromptEcho(" Okay, so here are some names and terms I use a lot."), "prompt echo: opener")
expect(Vocabulary.isPromptEcho(vocab.promptHint(limit: 3)), "prompt echo: whole hint")
expect(!Vocabulary.isPromptEcho(" Here are some names for the team: GitHub and ChatGPT."), "prompt echo: real speech kept")
expect(!Vocabulary.isPromptEcho(" Let's get started."), "prompt echo: short overlap kept")
expect(Vocabulary(text: vocab.text) == vocab, "round trip")
expect(!Vocabulary(text: Vocabulary.defaultText).terms.isEmpty, "default list parses")

// Vocabulary packs
let base = Vocabulary.defaultText + "\nMyOwnWord"
let withEng = VocabularyPack.apply(selected: ["engineering"], previouslySelected: [], to: base)
expect(Vocabulary(text: withEng).terms.contains("Terraform"), "pack adds its terms")
expect(Vocabulary(text: withEng).terms.filter { $0.lowercased() == "github" }.count == 1, "pack does not duplicate base terms")
let withBoth = VocabularyPack.apply(selected: ["engineering", "founder"], previouslySelected: ["engineering"], to: withEng)
expect(Vocabulary(text: withBoth).terms.contains("cap table"), "second pack adds")
let backToFounder = VocabularyPack.apply(selected: ["founder"], previouslySelected: ["engineering", "founder"], to: withBoth)
let t = Vocabulary(text: backToFounder).terms
expect(!t.contains("Terraform"), "deselected pack's terms removed")
expect(t.contains("cap table") && t.contains("MyOwnWord") && t.contains("GitHub"), "other pack, user and base terms kept")
expect(t.contains("QuickBooks"), "term shared with a still-selected pack kept")
let none = VocabularyPack.apply(selected: [], previouslySelected: ["founder"], to: backToFounder)
expect(Vocabulary(text: none) == Vocabulary(text: base), "removing all packs restores the original list")
for p in VocabularyPack.all { expect(Set(p.terms.map { $0.lowercased() }).count == p.terms.count, "no duplicates inside pack \(p.id)") }
expect(vocab.keyterms().contains("Local Flow"), "keyterms")

// EnvironmentKeys
let env = EnvironmentKeys.parse("""
# export OPENAI_API_KEY=sk-commented-out-1234
export OPENAI_API_KEY="sk-test-1234567890"
ELEVENLABS_API_KEY='el-abcdefghij' # trailing comment
set -gx GEMINI_API_KEY AIza-fish-key-12345
export OTHER=1
""", source: "~/.zshrc")
expect(env.map(\.name) == ["OPENAI_API_KEY", "ELEVENLABS_API_KEY", "GEMINI_API_KEY"], "env names \(env.map(\.name))")
expect(env.first?.value == "sk-test-1234567890", "env value")
expect(EnvironmentKeys.masked("sk-test-1234567890") == "sk-t…7890", "mask")

// Version
expect(Version("v1.2.3")! > Version("1.2")!, "version compare")
expect(Version("0.10.0")! > Version("0.9.9")!, "version numeric compare")
expect(Version("abc") == nil, "bad version")

if failures == 0 { print("core tests passed") } else { print("\(failures) failure(s)"); exit(1) }
