import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gear") }
            TranscriptionSettings().tabItem { Label("Transcription", systemImage: "waveform") }
            DictionarySettings().tabItem { Label("Dictionary", systemImage: "character.book.closed") }
            PrivacySettings().tabItem { Label("Privacy", systemImage: "lock") }
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(20)
    }
}

struct GeneralSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var controller = DictationController.shared

    var body: some View {
        Form {
            Section("Hotkey") {
                HotkeyRecorder(hotkey: $settings.hotkey)
                Text("Hold it to talk, let go to paste. Press Esc while holding to cancel.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Feedback") {
                Toggle("Play a sound when recording starts and stops", isOn: $settings.playSounds)
            }
            Section("Permissions") {
                if let problem = controller.permissionProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    HStack {
                        Button("Open Accessibility Settings") {
                            HotkeyMonitor.requestAccessibility()
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                        Button("Open Microphone Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                        }
                        Button("Re-check") { controller.refreshPermissions() }
                    }
                } else {
                    Label("Accessibility and microphone access granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { controller.refreshPermissions() }
    }
}

struct TranscriptionSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Picker("Mode", selection: $settings.engineMode) {
                    ForEach(EngineMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(settings.engineMode == .local
                     ? "Audio never leaves this Mac. Whisper runs on your GPU."
                     : "Audio is sent to the provider you pick with your own key. Nothing else is shared.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Language", selection: $settings.language) {
                    Text("Detect automatically").tag("auto")
                    ForEach(["en", "es", "fr", "de", "it", "pt", "ja", "zh", "ko", "hi", "nl", "ru", "ar"], id: \.self) { code in
                        Text(Locale.current.localizedString(forLanguageCode: code) ?? code).tag(code)
                    }
                }
            }
            if settings.engineMode == .cloud {
                CloudSettings()
            }
            Section(settings.engineMode == .cloud ? "Local fallback" : "Local model") {
                if settings.engineMode == .cloud {
                    Toggle("Fall back to the local model if the cloud fails", isOn: $settings.fallbackToLocal)
                }
                ModelList()
            }
        }
        .formStyle(.grouped)
    }
}

struct CloudSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var key = ""
    @State private var saved = false
    @State private var keyChanged = 0  // bumps so the "Key stored" line re-reads the Keychain

    private var provider: CloudProviderID { settings.cloudProvider }

    var body: some View {
        Section("Provider") {
            Picker("Service", selection: $settings.cloudProviderID) {
                ForEach(CloudProviderID.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Picker("Model", selection: Binding(get: { settings.cloudModel(for: provider) },
                                               set: { settings.setCloudModel($0, for: provider) })) {
                ForEach(provider.models, id: \.id) { Text($0.title).tag($0.id) }
            }
            HStack {
                SecureField("API key", text: $key)
                    .textFieldStyle(.roundedBorder)
                Button(saved ? "Saved" : "Save") {
                    Keychain.set(key.trimmingCharacters(in: .whitespacesAndNewlines), for: provider.keychainAccount)
                    saved = true
                    keyChanged += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { saved = false }
                }
                .disabled(key.isEmpty)
            }
            HStack {
                if provider.apiKey != nil {
                    Label("Key stored in your Keychain", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("Remove") { Keychain.delete(provider.keychainAccount); key = ""; keyChanged += 1 }
                } else {
                    Label("No key saved", systemImage: "key").foregroundStyle(.secondary)
                }
                Spacer()
                Link("Get a key", destination: provider.keyURL)
            }
            .font(.caption)
            EnvironmentKeyPicker(provider: provider) { keyChanged += 1 }
                .id("\(provider.rawValue)-\(keyChanged)")
        }
        .onChange(of: settings.cloudProviderID) { _, _ in key = "" }
    }
}

/// Offers keys found in the shell environment for the selected provider. The scan happens in `init` because
/// `onAppear` never fires on an empty `ForEach`; the parent re-creates the view (`.id`) when the key or provider changes.
struct EnvironmentKeyPicker: View {
    let provider: CloudProviderID
    var onUse: () -> Void
    @State private var found: [EnvironmentKeys.Found]

    init(provider: CloudProviderID, onUse: @escaping () -> Void = {}) {
        self.provider = provider
        self.onUse = onUse
        _found = State(initialValue: Self.scan(for: provider))
    }

    var body: some View {
        ForEach(found, id: \.name) { item in
            HStack {
                Text("Found \(item.name) in \(item.source) (\(EnvironmentKeys.masked(item.value)))").font(.caption)
                Spacer()
                Button("Use it") { Keychain.set(item.value, for: provider.keychainAccount); found = []; onUse() }
                    .controlSize(.small)
            }
        }
    }

    private static func scan(for provider: CloudProviderID) -> [EnvironmentKeys.Found] {
        guard provider.apiKey == nil else { return [] }
        let names = provider.environmentVariables
        return EnvironmentKeys.scan().filter { names.contains($0.name) }
    }
}

struct ModelList: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var downloader = ModelDownloader.shared

    var body: some View {
        ForEach(WhisperModel.all) { model in
            HStack(alignment: .firstTextBaseline) {
                Button {
                    settings.localModelID = model.id
                    LocalWhisper.shared.preload()
                } label: {
                    Image(systemName: settings.localModelID == model.id ? "largecircle.fill.circle" : "circle")
                }
                .buttonStyle(.plain)
                .disabled(!model.isDownloaded)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title).fontWeight(settings.localModelID == model.id ? .semibold : .regular)
                    Text("\(model.detail) \(model.sizeText).").font(.caption).foregroundStyle(.secondary)
                    if let error = downloader.errors[model.id] {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
                Spacer()
                if let progress = downloader.progress[model.id] {
                    ProgressView(value: progress).frame(width: 90)
                    Button("Cancel") { downloader.cancel(model) }.controlSize(.small)
                } else if model.isDownloaded {
                    Label("Downloaded", systemImage: "checkmark").font(.caption).foregroundStyle(.green)
                    Button("Delete") { downloader.delete(model) }.controlSize(.small)
                } else {
                    Button("Download") { downloader.download(model) }.controlSize(.small)
                }
            }
            .id("\(model.id)-\(downloader.installedVersion)")
        }
    }
}

struct DictionarySettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var showBuilder = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Words and names spelled your way. One per line; `heard => Correct` forces a replacement. The list is sent to the speech model as a hint and used to fix spelling on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $settings.vocabularyText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 240)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            HStack {
                Text("\(settings.vocabulary.terms.count) terms").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Suggest Terms for Me…") { showBuilder = true }
                Button("Reset to Default") { settings.vocabularyText = Vocabulary.defaultText }
            }
        }
        .sheet(isPresented: $showBuilder) { DictionaryBuilderSheet(onDone: { showBuilder = false }) }
    }
}

/// The "who are you / what do you do" question. The answer is used once for the suggestion request and discarded.
struct DictionaryBuilderSheet: View {
    var onDone: () -> Void
    @ObservedObject private var settings = AppSettings.shared
    @State private var answer = ""
    @State private var suggestions: [String] = []
    @State private var selected: Set<String> = []
    @State private var busy = false
    @State private var error: String?

    private var provider: CloudProviderID? {
        let configured = CloudProviderID.allCases.filter { $0.supportsTextGeneration && $0.apiKey != nil }
        return configured.first { $0 == settings.cloudProvider } ?? configured.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Build your dictionary").font(.title2.bold())
            Text("Tell us who you are and what you do (your job, company, tools, the people and products you talk about). This is used once to suggest words for your dictionary and is not saved anywhere.")
                .foregroundStyle(.secondary)
            if let provider {
                Text("Sent to \(provider.title) with your key.").font(.caption).foregroundStyle(.secondary)
            } else {
                Label("Add an OpenAI or Gemini key in Transcription to get suggestions. You can still edit the list by hand.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextEditor(text: $answer)
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            if !suggestions.isEmpty {
                ScrollView {
                    FlowLayout(spacing: 6) {
                        ForEach(suggestions, id: \.self) { term in
                            Toggle(term, isOn: Binding(get: { selected.contains(term) },
                                                       set: { if $0 { selected.insert(term) } else { selected.remove(term) } }))
                                .toggleStyle(.button).controlSize(.small)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("Cancel") { onDone() }
                Spacer()
                if suggestions.isEmpty {
                    Button(busy ? "Thinking…" : "Suggest Terms") { suggest() }
                        .disabled(busy || answer.trimmingCharacters(in: .whitespaces).count < 8 || provider == nil)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Add \(selected.count) Terms") {
                        settings.vocabularyText = DictionaryBuilder.merge(suggestions.filter { selected.contains($0) }, into: settings.vocabularyText)
                        onDone()
                    }
                    .disabled(selected.isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func suggest() {
        guard let provider else { return }
        busy = true
        error = nil
        let text = answer
        Task {
            do {
                let terms = try await DictionaryBuilder.suggestTerms(about: text, provider: provider)
                suggestions = terms
                selected = Set(terms)
                answer = ""
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

struct PrivacySettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var history = HistoryStore.shared

    var body: some View {
        Form {
            Section("Cleanup") {
                Toggle("Clean up transcripts", isOn: $settings.cleanupEnabled)
                Text("Removes ums and uhs, fixes capitalisation and punctuation, and turns \"new paragraph\" into a line break. This is done with rules on this Mac; your text is never sent anywhere for cleanup. Turn it off to keep transcripts exactly as the model heard them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("History") {
                Text("Transcripts and recordings are kept only on this Mac and deleted automatically 12 hours after each dictation.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("\(history.entries.count) items in the last 12 hours")
                    Spacer()
                    Button("Show History") { WindowManager.shared.showHistory() }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([history.directory]) }
                    Button("Delete All Now", role: .destructive) { history.clear() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct AboutSettings: View {
    @ObservedObject private var checker = UpdateChecker.shared

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.circle.fill").font(.system(size: 56))
            Text("Local Flow").font(.title.bold())
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                .foregroundStyle(.secondary)
            Text("Open-source, privacy-first dictation for the Mac.").foregroundStyle(.secondary)
            HStack {
                Button(checker.isChecking ? "Checking…" : "Check for Updates") { checker.check(userInitiated: true) }
                    .disabled(checker.isChecking)
                Link("GitHub", destination: URL(string: "https://github.com/jzone3/local-flow")!)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Click, then press the key (or hold a modifier) you want.
struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text("Hold to talk")
            Spacer()
            Button(recording ? "Press a key…" : hotkey.displayName) { recording ? stop() : begin() }
                .frame(minWidth: 120)
            Menu("Presets") {
                Button("Fn") { hotkey = .fn }
                Button("Right ⌥") { hotkey = .rightOption }
                Button("Right ⌘") { hotkey = .rightCommand }
            }
            .frame(width: 90)
        }
    }

    private func begin() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                guard Hotkey.modifierKeyCodes[event.keyCode] != nil,
                      !event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return nil }
                let flag: NSEvent.ModifierFlags
                switch event.keyCode {
                case 63: flag = .function
                case 54, 55: flag = .command
                case 58, 61: flag = .option
                case 59, 62: flag = .control
                case 56, 60: flag = .shift
                default: flag = .capsLock
                }
                hotkey = Hotkey(keyCode: event.keyCode, modifiers: flag.rawValue)
            } else {
                if event.keyCode == 53 { stop(); return nil }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
                hotkey = Hotkey(keyCode: event.keyCode, modifiers: flags.rawValue)
            }
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Wraps chips onto multiple lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, origin) in layout(proposal: proposal, subviews: subviews).origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        let maxWidth = proposal.width ?? 400
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: maxWidth, height: y + rowHeight), origins)
    }
}
