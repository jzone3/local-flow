import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label { Text("General") } icon: { Image(nsImage: Icon.nsImage("gear", size: 16)) } }
            TranscriptionSettings().tabItem { Label { Text("Transcription") } icon: { Image(nsImage: Icon.nsImage("waveform", size: 16)) } }
            DictionarySettings().tabItem { Label { Text("Dictionary") } icon: { Image(nsImage: Icon.nsImage("book", size: 16)) } }
            StatsView().tabItem { Label { Text("Stats") } icon: { Image(nsImage: Icon.nsImage("chart", size: 16)) } }
            PrivacySettings().tabItem { Label { Text("Privacy") } icon: { Image(nsImage: Icon.nsImage("lock", size: 16)) } }
            AboutSettings().tabItem { Label { Text("About") } icon: { Image(nsImage: Icon.nsImage("info", size: 16)) } }
        }
        .padding(20)
    }
}

struct GeneralSettings: View {
    @State private var fnConflict = Hotkey.systemDictationUsesFnTwice
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var controller = DictationController.shared

    var body: some View {
        Form {
            Section("Hotkey") {
                HotkeyRecorder(hotkey: $settings.hotkey)
                Text("Hold it to talk, let go to paste. Double-tap to keep listening hands-free; tap again to stop. Esc cancels.")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.hotkey.isFn, fnConflict {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Icon("warning", size: 13).foregroundStyle(.orange)
                        Text("macOS also uses a double-tap of Fn for its own Dictation. For hands-free to work, set System Settings → Keyboard → Dictation shortcut to Off.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Keyboard Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                        }
                        .actionButton().controlSize(.small)
                    }
                }
            }
            .onAppear { fnConflict = Hotkey.systemDictationUsesFnTwice }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                fnConflict = Hotkey.systemDictationUsesFnTwice
            }
            Section("Microphone") {
                MicrophonePicker()
            }
            Section("Feedback") {
                Toggle("Play a sound when recording starts and stops", isOn: $settings.playSounds)
            }
            Section("Permissions") {
                if let problem = controller.permissionProblem {
                    Label { Text(problem) } icon: { Icon("warning", size: 14) }.foregroundStyle(.orange)
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
                    .actionButton()
                } else {
                    Label { Text("Accessibility and microphone access granted") } icon: { Icon("check-circle", size: 14) }.foregroundStyle(.green)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
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
        .scrollContentBackground(.hidden)
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
                .actionButton(prominent: true)
            }
            HStack {
                if provider.apiKey != nil {
                    Label { Text("Key stored in your Keychain") } icon: { Icon("check-circle", size: 14) }.foregroundStyle(.green)
                    Button("Remove") { Keychain.delete(provider.keychainAccount); key = ""; keyChanged += 1 }
                        .actionButton().controlSize(.small)
                } else {
                    Label { Text("No key saved") } icon: { Icon("key", size: 14) }.foregroundStyle(.secondary)
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
                    .actionButton().controlSize(.small)
            }
        }
    }

    private static func scan(for provider: CloudProviderID) -> [EnvironmentKeys.Found] {
        guard provider.apiKey == nil else { return [] }
        let names = provider.environmentVariables
        return EnvironmentKeys.scan().filter { names.contains($0.name) }
    }
}

/// Pick which microphone to record from; live level meter shows it is the right one.
struct MicrophonePicker: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var recorder = DictationController.shared.recorder
    @State private var devices = AudioInputDevice.all
    @State private var systemDefault = AudioInputDevice.systemDefault

    var body: some View {
        Picker("Microphone", selection: Binding(
            get: { settings.inputDeviceUID ?? "" },
            set: { settings.inputDeviceUID = $0.isEmpty ? nil : $0 }
        )) {
            Text("System default" + (systemDefault.map { " (\($0.name))" } ?? "")).tag("")
            ForEach(devices) { device in Text(device.name).tag(device.uid) }
        }
        HStack(spacing: 10) {
            Icon("mic", size: 14).foregroundStyle(.secondary)
            LevelMeter(level: recorder.monitorLevel)
            Text(recorder.isRecording ? "Recording" : "Say something to test").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { recorder.startMonitoring(); refresh() }
        .onDisappear { recorder.stopMonitoring() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        devices = AudioInputDevice.all
        systemDefault = AudioInputDevice.systemDefault
        if let uid = settings.inputDeviceUID, !devices.contains(where: { $0.uid == uid }) { settings.inputDeviceUID = nil }
    }
}

struct LevelMeter: View {
    let level: Float
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(nsColor: .separatorColor))
                Capsule().fill(Color.green).frame(width: geo.size.width * CGFloat(min(1, max(0, level))))
            }
        }
        .frame(width: 160, height: 6)
        .animation(.linear(duration: 0.08), value: level)
    }
}

struct ModelList: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var downloader = ModelDownloader.shared

    var body: some View {
        VStack(spacing: 8) {
            ForEach(WhisperModel.all) { model in
                let selected = settings.localModelID == model.id
                HStack(spacing: 12) {
                    Radio(on: selected)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(model.title).fontWeight(.semibold)
                            Text(model.sizeText).font(.caption).foregroundStyle(.secondary)
                            if model == WhisperModel.recommended {
                                Text("Default").font(.caption2.weight(.medium)).foregroundStyle(Color.accentColor)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                            }
                        }
                        Text(model.detail).font(.caption).foregroundStyle(.secondary)
                        if let error = downloader.errors[model.id] {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                    }
                    Spacer(minLength: 8)
                    trailing(model)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard model.isDownloaded else { return }
                    settings.localModelID = model.id
                    LocalWhisper.shared.preload()
                }
                .background(selected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor.opacity(0.7) : Color(nsColor: .separatorColor), lineWidth: selected ? 1.5 : 1)
                )
                .id("\(model.id)-\(downloader.installedVersion)")
            }
        }
    }

    @ViewBuilder
    private func trailing(_ model: WhisperModel) -> some View {
        if let progress = downloader.progress[model.id] {
            ProgressView(value: progress).frame(width: 90)
            Button("Cancel") { downloader.cancel(model) }.actionButton().controlSize(.small)
        } else if model.isDownloaded {
            Label { Text("Downloaded") } icon: { Icon("check", size: 11) }.font(.caption).foregroundStyle(.green)
            Button("Delete") { downloader.delete(model) }.actionButton().controlSize(.small)
        } else {
            Button("Download") { downloader.download(model) }.actionButton(prominent: true).controlSize(.small)
        }
    }
}

struct DictionarySettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Words and names spelled your way. One per line; `heard => Correct` forces a replacement. The list is sent to the speech model as a hint and used to fix spelling on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Word packs").font(.subheadline).fontWeight(.medium).padding(.top, 4)
            PackPicker(columns: 2)
            TextEditor(text: $settings.vocabularyText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 240)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            HStack {
                Text("\(settings.vocabulary.terms.count) terms").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reset to Default") {
                    settings.vocabularyText = Vocabulary.defaultText
                    settings.dictionaryPacks = []
                }.actionButton()
            }
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
                Text("Transcripts and recordings are kept only on this Mac, only while Local Flow is running. Quitting deletes them; nothing lives longer than 12 hours either way.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("\(history.entries.count) items this session")
                    Spacer()
                    Button("Show History") { WindowManager.shared.showHistory() }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([history.directory]) }
                    Button("Delete All Now", role: .destructive) { history.clear() }
                }
                .actionButton()
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

struct AboutSettings: View {
    @ObservedObject private var checker = UpdateChecker.shared

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
            Text("Local Flow").font(.title2.weight(.semibold))
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                .foregroundStyle(.secondary)
            Text("Open-source, privacy-first dictation for the Mac.").foregroundStyle(.secondary)
            HStack {
                Button(checker.isChecking ? "Checking…" : "Check for Updates") { checker.check(userInitiated: true) }
                    .disabled(checker.isChecking)
                    .actionButton(prominent: true)
                Button("Source Code") { NSWorkspace.shared.open(Welcome.repoURL) }
                    .actionButton()
                Button("@imjaredz") { NSWorkspace.shared.open(Welcome.authorURL) }
                    .actionButton()
            }
            .padding(.top, 8)
            Button("Built with Devin") { NSWorkspace.shared.open(Welcome.devinURL) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.callout)
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
                .actionButton(prominent: recording)
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
