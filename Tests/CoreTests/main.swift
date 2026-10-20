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

// CleanupProfile
expect(CleanupProfile.for(bundleID: "com.apple.Terminal", focusedRole: nil, focusedDescription: nil) == .code, "profile: Terminal")
expect(CleanupProfile.for(bundleID: "com.jetbrains.intellij", focusedRole: "AXTextArea", focusedDescription: nil) == .code, "profile: JetBrains prefix")
expect(CleanupProfile.for(bundleID: "com.apple.Safari", focusedRole: "AXTextField", focusedDescription: "Address and Search") == .code, "profile: Safari address bar")
expect(CleanupProfile.for(bundleID: "com.google.Chrome", focusedRole: "AXTextField", focusedDescription: "Address and search bar") == .code, "profile: Chrome omnibox")
expect(CleanupProfile.for(bundleID: "com.apple.Safari", focusedRole: "AXTextArea", focusedDescription: nil) == .standard, "profile: Safari textarea")
expect(CleanupProfile.for(bundleID: "com.apple.Safari", focusedRole: "AXTextField", focusedDescription: "Email") == .standard, "profile: Safari plain field")
expect(CleanupProfile.for(bundleID: "com.apple.MobileSMS", focusedRole: nil, focusedDescription: nil) == .casual, "profile: Messages")
expect(CleanupProfile.for(bundleID: "com.apple.TextEdit", focusedRole: "AXTextArea", focusedDescription: nil) == .standard, "profile: TextEdit")
expect(CleanupProfile.for(bundleID: nil, focusedRole: nil, focusedDescription: nil) == .standard, "profile: unknown")

let codeVocab = Vocabulary(text: "GitHub\nDevin\nLocal Flow")
expect(TextCleanup.clean("echo hello from local flow", profile: .code), "echo hello from local flow", "code: lowercase, no period")
expect(TextCleanup.clean("Echo Hello from Local Flow.", profile: .code), "echo hello from local flow", "code: every word lowercased, period dropped")
expect(TextCleanup.clean("Echo Hello from Local Flow.", profile: .code, vocabulary: codeVocab), "echo hello from Local Flow", "code: dictionary term keeps its spelling")
expect(TextCleanup.clean("echo hello from local flow", profile: .code, vocabulary: codeVocab), "echo hello from Local Flow", "code: dictionary spelling applied to lowercase input")
expect(TextCleanup.clean("Export PATH and parse the JSON from the API.", profile: .code), "export PATH and parse the JSON from the API", "code: all-caps tokens stay")
expect(TextCleanup.clean("Run It On A Mac", profile: .code), "run it on a mac", "code: single capitals are not acronyms")
expect(TextCleanup.clean("GitHub status, um, please", profile: .code, vocabulary: codeVocab), "GitHub status please", "code: dictionary capital kept, filler removed")
expect(TextCleanup.clean("git push [BLANK_AUDIO]  origin   main", profile: .code), "git push origin main", "code: tags and whitespace")
expect(TextCleanup.clean("key:value a.b", profile: .code), "key:value a.b", "code: punctuation untouched")
expect(TextCleanup.clean("example dot com", profile: .code), "example.com", "code: spoken domain")
expect(TextCleanup.clean("Example dot com.", profile: .code), "example.com", "code: spoken domain as Whisper gives it")
expect(TextCleanup.clean("a dot product", profile: .code), "a dot product", "code: dot before a plain word stays")
expect(TextCleanup.clean("is it done?", profile: .code), "is it done?", "code: question mark stays")
expect(TextCleanup.clean("hey are you coming", profile: .casual), "Hey are you coming", "casual: capitalised, no period")
expect(TextCleanup.clean("hey are you coming.", profile: .casual), "Hey are you coming", "casual: model's period dropped")
expect(TextCleanup.clean("are you coming?", profile: .casual), "Are you coming?", "casual: question mark kept")
expect(TextCleanup.clean("wait...", profile: .casual), "Wait...", "casual: ellipsis kept")
expect(TextCleanup.clean("hey are you coming.", profile: .standard), "Hey are you coming.", "standard: unchanged")
expect(TextCleanup.clean("hey are you coming."), "Hey are you coming.", "standard is the default")

expect(TextCleanup.isHallucination("Thanks for watching!"), "hallucination: thanks for watching")
expect(TextCleanup.isHallucination(" you "), "hallucination: lone you")
expect(TextCleanup.isHallucination(""), "hallucination: empty")
expect(!TextCleanup.isHallucination("Thank you for the help today."), "real sentence kept")
expect(!TextCleanup.isHallucination("Thank you."), "short real reply kept")
expect(TextCleanup.dropTrailingSilenceEcho([" The house has a yellow door.", " You"]) == [" The house has a yellow door."], "trailing lone You dropped")
expect(TextCleanup.dropTrailingSilenceEcho([" Door.", " you.", " "]) == [" Door."], "trailing you + blank dropped")
expect(TextCleanup.dropTrailingSilenceEcho([" I will send it to you"]) == [" I will send it to you"], "you inside a sentence kept")
expect(TextCleanup.dropTrailingSilenceEcho([" Please send it today.", " Thank you."]) == [" Please send it today.", " Thank you."], "trailing Thank you kept")
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

// MixtureOfExperts
let moe = [MixtureOfExperts.Transcript(service: "OpenAI", text: "I pushed to git hub today."),
           MixtureOfExperts.Transcript(service: "ElevenLabs", text: " I pushed to GitHub today. "),
           MixtureOfExperts.Transcript(service: "Google Gemini", text: "I pushed to GitHub today")]
let prompt = MixtureOfExperts.mergePrompt(moe, terms: ["GitHub", "Devin"])
expect(prompt.contains("3 transcripts"), "prompt counts transcripts")
expect(prompt.contains("Transcript 2 (ElevenLabs):\nI pushed to GitHub today."), "prompt lists trimmed transcripts")
expect(prompt.contains("GitHub, Devin."), "prompt carries dictionary terms")
expect(!MixtureOfExperts.mergePrompt(moe, terms: []).contains("Spell these"), "no dictionary line without terms")
expect(MixtureOfExperts.cleanAnswer("```\nHello there.\n```"), "Hello there.", "clean: fences")
expect(MixtureOfExperts.cleanAnswer("```text\nHello there.\n```\n"), "Hello there.", "clean: fence with language")
expect(MixtureOfExperts.cleanAnswer("\"Hello there.\""), "Hello there.", "clean: quotes")
expect(MixtureOfExperts.cleanAnswer("“Hello there.”"), "Hello there.", "clean: curly quotes")
expect(MixtureOfExperts.cleanAnswer("Transcript: Hello there."), "Hello there.", "clean: label")
expect(MixtureOfExperts.cleanAnswer("He said \"hi\" and left."), "He said \"hi\" and left.", "clean: inner quotes kept")
expect(MixtureOfExperts.cleanAnswer("  Plain.  "), "Plain.", "clean: trim")
expect(MixtureOfExperts.engineLabel(services: ["OpenAI", "ElevenLabs", "Google Gemini"], merger: "gpt-5.4-mini"),
       "Mixture of experts (OpenAI + ElevenLabs + Google Gemini → gpt-5.4-mini)", "engine label merged")
expect(MixtureOfExperts.engineLabel(services: ["ElevenLabs"], merger: nil), "Mixture of experts (ElevenLabs only)", "engine label single")
expect(MixtureOfExperts.engineLabel(services: ["ElevenLabs", "Google Gemini"], merger: nil), "Mixture of experts (ElevenLabs + Google Gemini, not merged)", "engine label unmerged")
expect(MixtureOfExperts.bestSingle(Array(moe[1...]), preference: ["OpenAI", "ElevenLabs", "Google Gemini"])?.service == "ElevenLabs", "best single by preference")
expect(MixtureOfExperts.bestSingle([], preference: ["OpenAI"]) == nil, "best single of nothing")
expect(MixtureOfExperts.transcribingLabel(modelCount: 3), "Transcribing with 3 models…", "bar label")
expect(MixtureOfExperts.transcribingLabel(modelCount: 1), "Transcribing…", "bar label single")

// Version
expect(Version("v1.2.3")! > Version("1.2")!, "version compare")
expect(Version("0.10.0")! > Version("0.9.9")!, "version numeric compare")
expect(Version("abc") == nil, "bad version")


// Hotkey
let ctrl = Hotkey.controlFlag, opt = Hotkey.optionFlag, shift = Hotkey.shiftFlag, cmd = Hotkey.commandFlag, fnFlag = Hotkey.functionFlag
expect(Hotkey(keyCode: 49, modifiers: ctrl).displayName, "⌃Space", "displayName ctrl space")
expect(Hotkey(keyCode: 2, modifiers: opt | cmd).displayName, "⌥⌘D", "displayName opt cmd D")
expect(Hotkey(keyCode: 49, modifiers: shift | opt).displayName, "⌥⇧Space", "displayName macOS modifier order")
expect(Hotkey(keyCode: 123, modifiers: ctrl).displayName, "⌃←", "displayName arrow")
expect(Hotkey(keyCode: 96, modifiers: 0).displayName, "F5", "displayName bare F-key")
expect(Hotkey(keyCode: 36, modifiers: cmd | shift).displayName, "⇧⌘↩", "displayName return")
expect(Hotkey.fn.displayName, "Fn", "displayName fn")
expect(Hotkey.rightOption.displayName, "Right ⌥", "displayName right option")
expect(Hotkey.comboModifiers(ctrl | fnFlag | Hotkey.numericPadFlag | Hotkey.capsLockFlag | 0x1234) == ctrl, "comboModifiers strips fn/keypad/capslock/device bits")

var rec = HotkeyRecording()
expect(rec.handle(.flagsChanged(keyCode: 59, flags: ctrl)) == .recording(modifiers: ctrl), "ctrl down shows live, no commit")
expect(rec.handle(.keyDown(keyCode: 49, flags: ctrl)) == .committed(Hotkey(keyCode: 49, modifiers: ctrl)), "ctrl space commits combo")

rec = HotkeyRecording()
_ = rec.handle(.flagsChanged(keyCode: 58, flags: opt))
expect(rec.handle(.flagsChanged(keyCode: 55, flags: opt | cmd)) == .recording(modifiers: opt | cmd), "second modifier adds live")
expect(rec.handle(.keyDown(keyCode: 2, flags: opt | cmd)) == .committed(Hotkey(keyCode: 2, modifiers: opt | cmd)), "opt cmd D commits")

rec = HotkeyRecording()
_ = rec.handle(.flagsChanged(keyCode: 56, flags: shift))
_ = rec.handle(.flagsChanged(keyCode: 58, flags: shift | opt))
expect(rec.handle(.keyDown(keyCode: 49, flags: shift | opt | Hotkey.capsLockFlag)) == .committed(Hotkey(keyCode: 49, modifiers: shift | opt)), "shift opt space commits, caps lock ignored")

rec = HotkeyRecording()
expect(rec.handle(.flagsChanged(keyCode: 61, flags: opt)) == .recording(modifiers: opt), "right option down waits")
expect(rec.handle(.flagsChanged(keyCode: 61, flags: 0)) == .committed(.rightOption), "right option released alone commits modifier-only")

rec = HotkeyRecording()
_ = rec.handle(.flagsChanged(keyCode: 63, flags: fnFlag))
expect(rec.handle(.flagsChanged(keyCode: 63, flags: 0)) == .committed(.fn), "fn alone still records as Fn")

rec = HotkeyRecording()
_ = rec.handle(.flagsChanged(keyCode: 56, flags: shift))
_ = rec.handle(.flagsChanged(keyCode: 58, flags: shift | opt))
expect(rec.handle(.flagsChanged(keyCode: 58, flags: shift)) == .recording(modifiers: shift), "releasing one of two modifiers keeps recording")
expect(rec.handle(.flagsChanged(keyCode: 56, flags: 0)) == .recording(modifiers: 0), "two modifiers released with no key: nothing committed")

rec = HotkeyRecording()
_ = rec.handle(.flagsChanged(keyCode: 59, flags: ctrl))
expect(rec.handle(.keyDown(keyCode: 53, flags: ctrl)) == .cancelled, "esc cancels")

rec = HotkeyRecording()
expect(rec.handle(.keyDown(keyCode: 49, flags: 0)) == .recording(modifiers: 0), "bare space is refused")
expect(rec.handle(.keyDown(keyCode: 96, flags: fnFlag)) == .committed(Hotkey(keyCode: 96, modifiers: 0)), "bare F5 is allowed, fn bit dropped")

rec = HotkeyRecording()
_ = rec.handle(.flagsChanged(keyCode: 59, flags: ctrl))
expect(rec.handle(.keyDown(keyCode: 123, flags: ctrl | fnFlag | Hotkey.numericPadFlag)) == .committed(Hotkey(keyCode: 123, modifiers: ctrl)), "ctrl left arrow drops the fn/keypad bits")

let tapped: UInt = ctrl | 0x2000_0000  // NSEvent(cgEvent:) carries undocumented high bits
expect(Hotkey.comboModifiers(tapped) == ctrl, "tapped events' extra bits are dropped for matching")
rec = HotkeyRecording()
_ = rec.handle(.flagsChanged(keyCode: 59, flags: tapped))
expect(rec.handle(.flagsChanged(keyCode: 59, flags: 0x2000_0000)) == .committed(Hotkey(keyCode: 59, modifiers: ctrl)), "release with extra bits still counts as all-up")

// ModelSource: Hugging Face links
let hfResolve = ModelSource.parseHuggingFace("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin")
expect(try! hfResolve.get().downloadURL.absoluteString, "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin", "hf resolve link kept")
expect(try! hfResolve.get().fileName, "ggml-base.en.bin", "hf file name")
expect(try! hfResolve.get().repo, "ggerganov/whisper.cpp", "hf repo")
let hfBlob = ModelSource.parseHuggingFace("https://huggingface.co/ggerganov/whisper.cpp/blob/main/ggml-tiny.bin")
expect(try! hfBlob.get().downloadURL.absoluteString, "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin", "hf blob rewritten to resolve")
let hfQuery = ModelSource.parseHuggingFace(" huggingface.co/someone/models/resolve/v2/sub/dir/ggml-custom.bin?download=true ")
expect(try! hfQuery.get().downloadURL.absoluteString, "https://huggingface.co/someone/models/resolve/v2/sub/dir/ggml-custom.bin", "hf scheme added, query dropped, subdir kept")
expect(try! hfQuery.get().revision, "v2", "hf revision")
expect(ModelSource.parseHuggingFace("https://hf.co/a/b/blob/main/ggml-x.bin").map(\.downloadURL.host) == .success("huggingface.co"), "hf.co maps to huggingface.co")
expect(ModelSource.parseHuggingFace("https://example.com/a/b/resolve/main/ggml-x.bin") == .failure(.notHuggingFace), "non-HF host refused")
expect(ModelSource.parseHuggingFace("https://huggingface.co/ggerganov/whisper.cpp") == .failure(.notAFile), "repo page refused")
expect(ModelSource.parseHuggingFace("https://huggingface.co/ggerganov/whisper.cpp/tree/main") == .failure(.notAFile), "tree page refused")
expect(ModelSource.parseHuggingFace("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/README.md") == .failure(.notBin), "non-.bin refused")
expect(ModelSource.parseHuggingFace("https://huggingface.co/a/b/resolve/main/model.gguf") == .failure(.notBin), "gguf refused")
expect(ModelSource.parseHuggingFace("") == .failure(.notAURL), "empty refused")
expect(ModelSource.parseHuggingFace("not a url at all") == .failure(.notAURL), "garbage refused")

// ModelSource: ggml magic (0x67676d6c little-endian = bytes "lmgg")
expect(ModelSource.hasGgmlMagic(Data("lmgg....".utf8)), "ggml magic accepted")
expect(ModelSource.hasGgmlMagic(Data([0x6c, 0x6d, 0x67, 0x67])), "ggml magic bytes accepted")
expect(!ModelSource.hasGgmlMagic(Data("ggml....".utf8)), "big-endian spelling refused")
expect(!ModelSource.hasGgmlMagic(Data("GGUF....".utf8)), "gguf refused")
expect(!ModelSource.hasGgmlMagic(Data("<!DOCTYPE html>".utf8)), "html page refused")
expect(!ModelSource.hasGgmlMagic(Data([0x6c, 0x6d])), "short file refused")
let magicFile = FileManager.default.temporaryDirectory.appendingPathComponent("lf-magic-\(UUID().uuidString).bin")
try! Data("lmgg".utf8 + [UInt8](repeating: 0, count: 64)).write(to: magicFile)
expect(ModelSource.isGgmlModel(at: magicFile), "magic read from disk")
try! Data("nope".utf8).write(to: magicFile)
expect(!ModelSource.isGgmlModel(at: magicFile), "bad file on disk refused")
try? FileManager.default.removeItem(at: magicFile)
expect(!ModelSource.isGgmlModel(at: magicFile), "missing file refused")
expect(ModelSource.displayName(forFile: "ggml-base.en.bin"), "base.en", "display name strips ggml-/.bin")
expect(ModelSource.displayName(forFile: "my-model.bin"), "my-model", "display name without prefix")
expect(ModelSource.displayName(forFile: "ggml-large-v3-turbo-q5_0.bin"), "large-v3-turbo-q5_0", "display name quantised")

// TranscriptionDetails: the History "Details" text
var local = TranscriptionDetails(mode: .local, seconds: 1.42, finalFrom: "Whisper Best")
expect(local.text, "Local · Whisper Best · 1.4 s", "details: local is model + seconds only")
var cloud = TranscriptionDetails(mode: .cloud, seconds: 5.2, finalFrom: "Whisper Best (local)")
cloud.attempts = [
    .init(service: "OpenAI", model: "gpt-4o-transcribe", tries: 3, error: "Server error 429", seconds: 4.0, transcript: nil),
    .init(service: "Whisper Best (local)", model: nil, tries: 1, error: nil, seconds: 1.1, transcript: nil),
]
cloud.usedLocalFallback = true
cloud.fallbackReason = "OpenAI failed (Server error 429). Used the local model instead."
expect(cloud.text, """
Cloud · 5.2 s
✗ OpenAI (gpt-4o-transcribe) — failed after 3 tries: Server error 429
✓ Whisper Best (local) — 1 try, 1.1 s
Local fallback used: Whisper Best (local)
Why: OpenAI failed (Server error 429). Used the local model instead.
""".trimmingCharacters(in: .newlines), "details: cloud fallback")
var mix = TranscriptionDetails(mode: .mixture, seconds: 12.0, finalFrom: "ElevenLabs")
mix.attempts = [
    .init(service: "ElevenLabs", model: "scribe_v2", tries: 1, error: nil, seconds: 0.7, transcript: "hello there "),
    .init(service: "Google Gemini", model: "gemini-3.5-flash", tries: 0, error: "The request timed out.", seconds: 25, transcript: nil),
]
mix.mergeError = "no OpenAI key; used ElevenLabs alone"
expect(mix.text, """
Mixture of experts · 2 services, 1 answered · 12 s
✓ ElevenLabs (scribe_v2) — 1 try, 0.7 s
    “hello there”
✗ Google Gemini (gemini-3.5-flash) — The request timed out.
Merge: no OpenAI key; used ElevenLabs alone
Final text from ElevenLabs
""".trimmingCharacters(in: .newlines), "details: mixture unmerged")
mix.merger = "OpenAI gpt-5.4-mini (0.9 s)"
mix.mergeError = nil
expect(mix.text.hasSuffix("Merged by OpenAI gpt-5.4-mini (0.9 s) → final text"), "details: merged line last")
// Old history entries (no details) still decode
struct OldEntry: Codable { let text: String; let details: TranscriptionDetails? }
let decoded = try! JSONDecoder().decode(OldEntry.self, from: Data(#"{"text":"hi"}"#.utf8))
expect(decoded.details == nil && decoded.text == "hi", "details: optional decodes from old JSON")
let roundTrip = try! JSONDecoder().decode(TranscriptionDetails.self, from: try! JSONEncoder().encode(cloud))
expect(roundTrip == cloud, "details: Codable round trip")

if failures == 0 { print("core tests passed") } else { print("\(failures) failure(s)"); exit(1) }
