import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label { Text("General") } icon: { Image(nsImage: Icon.nsImage("gear", size: 16)) } }
            TranscriptionSettings().tabItem { Label { Text("Transcription") } icon: { Image(nsImage: Icon.nsImage("waveform", size: 16)) } }
            DictionarySettings().tabItem { Label { Text("Dictionary") } icon: { Image(nsImage: Icon.nsImage("book", size: 16)) } }
            PrivacySettings().tabItem { Label { Text("Privacy") } icon: { Image(nsImage: Icon.nsImage("lock", size: 16)) } }
            AboutSettings().tabItem { Label { Text("About") } icon: { Image(nsImage: Icon.nsImage("info", size: 16)) } }
        }
        .padding(20)
        .transcribesDroppedFiles()
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
                controller.refreshPermissions()   // the user usually comes back from System Settings
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
            ProviderKeyRow(provider: provider, found: EnvironmentKeys.scan().first { provider.environmentVariables.contains($0.name) },
                           showsRemove: true) { keyChanged += 1 }
                .id("\(provider.rawValue)-\(keyChanged)")
        }
        Section {
            MixtureOfExpertsToggle()
                .id(keyChanged)
        }
        Section("What gets sent") {
            WhatGetsSent()
                .id(keyChanged)
        }
    }
}

/// Exactly what leaves this Mac in Cloud mode, per service, so the user can check it before dictating.
struct WhatGetsSent: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if settings.mixtureOfExperts {
                Text("Your audio clip (16 kHz WAV) and your dictionary words go to every service below that has a key, each with its own key. Nothing else.")
                ForEach(CloudProviderID.allCases) { provider in
                    let keyed = provider.apiKey != nil
                    Text("\(keyed ? "✓" : "–") \(provider.title) · \(provider.modelTitle(settings.cloudModel(for: provider)))\(keyed ? "" : " · no key, skipped")")
                        .foregroundStyle(keyed ? .primary : .secondary)
                }
                if CloudProviderID.openAI.apiKey != nil {
                    Text("Then the transcripts (not the audio) and your dictionary words go to OpenAI \(OpenAIChat.mergeModel), which merges them.")
                } else {
                    Text("Needs an OpenAI key to merge; without one the best single transcript is used as is.")
                }
            } else {
                let provider = settings.cloudProvider
                Text("Your audio clip (16 kHz WAV) and your dictionary words go to \(provider.title) (\(provider.modelTitle(settings.cloudModel(for: provider)))) with your key. Nothing else.")
            }
            Text(fallbackLine)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var fallbackLine: String {
        let model = WhisperModel.active
        guard settings.fallbackToLocal else { return "If the cloud fails, nothing is pasted (local fallback is off)." }
        return model.isDownloaded
            ? "If the cloud fails, Whisper \(model.title) on this Mac transcribes instead."
            : "If the cloud fails, nothing is pasted: the local fallback model (\(model.title)) isn't downloaded."
    }
}

/// "Mixture of experts" toggle with its explanation; the captions re-read the Keychain whenever the parent re-creates it.
struct MixtureOfExpertsToggle: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Toggle(MixtureOfExperts.title, isOn: $settings.mixtureOfExperts)
        VStack(alignment: .leading, spacing: 4) {
            Text(MixtureOfExperts.explanation)
            if settings.cloudProvidersWithKeys.count < 2 {
                Text(MixtureOfExperts.needMoreKeys)
            }
            if CloudProviderID.openAI.apiKey == nil {
                Text(MixtureOfExperts.needOpenAIKey)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

/// One provider's key: a green check + Replace once a key is saved, otherwise a paste field — or, when the key is
/// already in a shell file, an "Import from shell" button. Shared by Settings and the setup flow.
struct ProviderKeyRow: View {
    let provider: CloudProviderID
    var found: EnvironmentKeys.Found?
    var showsRemove = false
    var onChange: () -> Void = {}
    @State private var key = ""
    @State private var editing = false

    private var hasKey: Bool { provider.apiKey != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if hasKey {
                    Icon("check-circle", size: 16).foregroundStyle(.green)
                } else if found != nil {
                    Icon("key", size: 16).foregroundStyle(.secondary)
                } else {
                    Icon("x-circle", size: 16).foregroundStyle(.tertiary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.title)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if hasKey, !editing {
                    if showsRemove {
                        Button("Remove") { Keychain.delete(provider.keychainAccount); onChange() }.actionButton().controlSize(.small)
                    }
                    Button("Replace") { editing = true }.actionButton().controlSize(.small)
                } else if !hasKey, let found {
                    Button("Import from shell") { save(found.value) }.actionButton(prominent: true).controlSize(.small)
                    if !editing {
                        Button("Paste instead") { editing = true }.actionButton().controlSize(.small)
                    }
                } else if !hasKey, !editing {
                    Link("Get a key", destination: provider.keyURL).font(.caption)
                }
            }
            if editing || (!hasKey && found == nil) {
                HStack {
                    SecureField("Paste your \(provider.title) API key", text: $key)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") { save(key) }
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .actionButton(prominent: true)
                    if editing {
                        Button("Cancel") { editing = false; key = "" }.actionButton()
                    }
                }
            }
        }
    }

    private var detail: String {
        if hasKey { return "Saved in your Keychain" }
        if let found { return "Found \(found.name) in \(found.source) (\(EnvironmentKeys.masked(found.value)))" }
        return "No key"
    }

    private func save(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Keychain.set(trimmed, for: provider.keychainAccount)
        AppSettings.shared.preferProviderWithKey()
        key = ""
        editing = false
        onChange()
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
    /// Settings shows the custom models and the "Custom model…" row; setup shows the three built-ins only.
    var showsCustom = true
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var downloader = ModelDownloader.shared
    @ObservedObject private var customStore = CustomModelStore.shared
    @State private var addingCustom = false

    private var models: [WhisperModel] { showsCustom ? WhisperModel.allIncludingCustom : WhisperModel.all }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(models) { model in
                let selected = settings.localModelID == model.id
                HStack(spacing: 12) {
                    Radio(on: selected)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(model.title).fontWeight(.semibold)
                            Text(model.isCustom ? model.sizeText : "\(model.sizeText) · \(model.shortName)").font(.caption).foregroundStyle(.secondary)
                            if model == WhisperModel.recommended {
                                Text("Recommended").font(.caption2.weight(.medium)).foregroundStyle(Color.accentColor)
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
                .modifier(ModelRowChrome(selected: selected))
                .onTapGesture {
                    guard model.isDownloaded else { return }
                    settings.localModelID = model.id
                    LocalWhisper.shared.preload()
                }
                .id("\(model.id)-\(downloader.installedVersion)")
            }
            if showsCustom {
                HStack(spacing: 12) {
                    Icon("download", size: 16).foregroundStyle(.secondary).frame(width: 16)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Custom model…").fontWeight(.semibold)
                        Text("Any Whisper ggml file, from a Hugging Face link or from this Mac.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Add…") { addingCustom = true }.actionButton().controlSize(.small)
                }
                .modifier(ModelRowChrome(selected: false))
                .onTapGesture { addingCustom = true }
                .sheet(isPresented: $addingCustom) { AddCustomModelSheet() }
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
            Button("Delete") { confirmDelete(model) }.actionButton().controlSize(.small)
        } else if model.url != nil {
            Button("Download") { downloader.download(model) }.actionButton(prominent: true).controlSize(.small)
            if model.isCustom {
                Button("Remove") { downloader.delete(model) }.actionButton().controlSize(.small)
            }
        } else {
            Button("Remove") { downloader.delete(model) }.actionButton().controlSize(.small)
        }
    }

    private func confirmDelete(_ model: WhisperModel) {
        let alert = NSAlert()
        alert.messageText = "Delete \(model.title) (\(model.sizeText))?"
        alert.informativeText = model.isCustom ? "The file and its row are removed. You can add it again any time." : "You can download it again any time."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let finish: (NSApplication.ModalResponse) -> Void = { if $0 == .alertFirstButtonReturn { downloader.delete(model) } }
        if let window = NSApp.keyWindow { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }
}

private struct ModelRowChrome: ViewModifier {
    let selected: Bool
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(selected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.7) : Color(nsColor: .separatorColor), lineWidth: selected ? 1.5 : 1)
            )
    }
}

/// Paste a Hugging Face file link or pick a ggml .bin on this Mac; shows the file name and size before "Add".
struct AddCustomModelSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var picked: Candidate?
    @State private var checking = false
    @State private var urlProblem: String?
    @State private var fileProblem: String?
    @State private var lookup: Task<Void, Never>?

    private var problem: String? { fileProblem ?? urlProblem }

    enum Candidate: Equatable {
        case remote(ModelSource.HuggingFaceFile, bytes: Int64?)
        case local(URL, bytes: Int64)
        var fileName: String {
            switch self {
            case .remote(let file, _): return file.fileName
            case .local(let url, _): return url.lastPathComponent
            }
        }
        var bytes: Int64? {
            switch self {
            case .remote(_, let bytes): return bytes
            case .local(_, let bytes): return bytes
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a custom model").font(.title3.weight(.semibold))
            Text("Local Flow runs whisper.cpp, which only loads Whisper models in its ggml format (a .bin file). GGUF, PyTorch and other formats won't work.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                LabeledContent("Hugging Face URL") {
                    TextField("", text: $urlText, prompt: Text("https://huggingface.co/…/ggml-model.bin"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity)
                        .onChange(of: urlText) { _, text in resolve(text) }
                }
                HStack {
                    Text("Or a file on this Mac")
                    Spacer()
                    Button("Choose file…", action: chooseFile).actionButton()
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, -20)
            Group {
                if checking {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking…") }
                } else if let problem {
                    Label { Text(problem) } icon: { Icon("warning", size: 13) }.foregroundStyle(.red)
                } else if let picked {
                    Label {
                        Text(picked.fileName).fontWeight(.medium) + Text(picked.bytes.map { "  " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "").foregroundStyle(.secondary)
                    } icon: { Icon("check-circle", size: 13).foregroundStyle(.green) }
                } else {
                    Text("Paste a link to a .bin file (the “resolve” or “blob” link on Hugging Face), or choose a file.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .frame(minHeight: 18, alignment: .leading)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.actionButton().keyboardShortcut(.cancelAction)
                Button("Add", action: add).actionButton(prominent: true).keyboardShortcut(.defaultAction)
                    .disabled(picked == nil || checking || problem != nil)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onDisappear { lookup?.cancel() }
    }

    /// Clearing the field only forgets the link; typing a link replaces a chosen file.
    private func resolve(_ text: String) {
        lookup?.cancel()
        checking = false
        urlProblem = nil
        if case .remote = picked { picked = nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        picked = nil
        fileProblem = nil
        switch ModelSource.parseHuggingFace(trimmed) {
        case .failure(.notAURL): urlProblem = "That isn't a web address."
        case .failure(.notHuggingFace): urlProblem = "Only huggingface.co links are supported."
        case .failure(.notAFile): urlProblem = "That's a repo page, not a file. Open the .bin file and copy its link."
        case .failure(.notBin): urlProblem = "The link must point to a ggml .bin file."
        case .success(let file):
            if let conflict = CustomModelStore.shared.conflict(fileName: file.fileName) { urlProblem = conflict; return }
            checking = true
            lookup = Task {
                let size = await Self.remoteSize(file.downloadURL)
                guard !Task.isCancelled else { return }
                checking = false
                switch size {
                case .success(let bytes): picked = .remote(file, bytes: bytes)
                case .failure(let message): urlProblem = message
                }
            }
        }
    }

    /// HEAD the file (following Hugging Face's redirect to its CDN) for the size, so the row shows it before downloading.
    private static func remoteSize(_ url: URL) async -> Result<Int64?, String> {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure("No answer from Hugging Face.") }
            switch http.statusCode {
            case 200: return .success(http.expectedContentLength > 0 ? http.expectedContentLength : nil)
            case 401, 403: return .failure("That file needs a Hugging Face login; only public files work.")
            case 404: return .failure("Hugging Face has no file at that link (404).")
            default: return .failure("Hugging Face answered HTTP \(http.statusCode).")
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        panel.message = "Pick a Whisper ggml model (.bin)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        lookup?.cancel()
        checking = false
        picked = nil
        urlProblem = nil
        urlText = ""   // its onChange only clears link state, so the file result below survives it
        guard url.pathExtension.lowercased() == "bin" else { fileProblem = "The file must be a ggml .bin model."; return }
        if let conflict = CustomModelStore.shared.conflict(fileName: url.lastPathComponent) { fileProblem = conflict; return }
        guard ModelSource.isGgmlModel(at: url) else { fileProblem = ModelSource.notWhisperMessage; return }
        fileProblem = nil
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        picked = .local(url, bytes: bytes)
    }

    private func add() {
        guard let picked else { return }
        let failure: String?
        switch picked {
        case .remote(let file, let bytes): failure = ModelDownloader.shared.addRemote(file, bytes: bytes ?? 0)
        case .local(let url, _): failure = ModelDownloader.shared.addLocalFile(url)
        }
        if let failure {
            if case .local = picked { fileProblem = failure } else { urlProblem = failure }
        } else {
            dismiss()
        }
    }
}

extension String: @retroactive Error {}

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
                Text(settings.vocabulary.terms.count == 1 ? "1 term" : "\(settings.vocabulary.terms.count) terms").font(.caption).foregroundStyle(.secondary)
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
                Text("Adapts to the app in front: terminals and editors get it as spoken, chats skip the final period.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("History") {
                Text("Transcripts and recordings are kept only on this Mac, only while Local Flow is running. Quitting deletes them; nothing lives longer than 12 hours either way.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("To transcribe a recording or a video, drop the file on this window, right-click it in Finder → Services → Transcribe with Local Flow, or use Transcribe File… in the menu bar.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(history.entries.isEmpty ? "Nothing yet this session" : "\(history.entries.count) this session")
                    Spacer()
                    Button("Delete All Now", role: .destructive) { HistoryPlayer.shared.stop(); history.clear() }
                        .actionButton()
                        .disabled(history.entries.isEmpty)
                }
                if !history.entries.isEmpty {
                    HistoryList(history: history)
                        .padding(.vertical, 4)
                }
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
                Button("Source Code") { Welcome.openInBackground(Welcome.repoURL) }
                    .actionButton()
                Button("@imjaredz") { Welcome.openInBackground(Welcome.authorURL) }
                    .actionButton()
            }
            .padding(.top, 8)
            Button("Built with Devin") { Welcome.openInBackground(Welcome.devinURL) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.callout)
            Spacer()
            Button("Remove All Data…") { DataRemoval.confirmAndRemove() }
                .actionButton()
                .controlSize(.small)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Click, then press the key combo (or hold a modifier) you want.
struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey
    @State private var recording = false
    @State private var held: UInt = 0
    @State private var hint: String?
    @State private var tap: KeyTap?
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                Text("Hold to talk")
                Spacer()
                Button(label) { recording ? stop() : begin() }
                    .frame(minWidth: 120)
                    .actionButton(prominent: recording)
                Menu("Presets") {
                    Button("Fn") { choose(.fn) }
                    Button("Right ⌥") { choose(.rightOption) }
                    Button("Right ⌘") { choose(.rightCommand) }
                }
                .frame(width: 90)
            }
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func choose(_ key: Hotkey) {
        hotkey = key
        hint = nil
    }

    private var label: String {
        guard recording else { return hotkey.displayName }
        return held == 0 ? "Press a key…" : Hotkey.symbols(for: held) + "…"
    }

    /// Through the event tap when Accessibility is granted, so combos macOS claims (⌃Space, ⌘Space) still reach us;
    /// otherwise a local monitor, which only sees what the system lets through to the window.
    private func begin() {
        recording = true
        held = 0
        hint = nil
        DictationController.shared.hotkeyPaused = true
        var state = HotkeyRecording()
        var swallowUp: UInt16?  // the committed key's key-up, so e.g. ⌘Space doesn't still open Spotlight
        let handle: (NSEvent) -> Bool = { event in
            if event.type == .keyUp {
                guard event.keyCode == swallowUp else { return false }
                stop()
                return true
            }
            let input: HotkeyRecording.Event = event.type == .flagsChanged
                ? .flagsChanged(keyCode: event.keyCode, flags: event.modifierFlags.rawValue)
                : .keyDown(keyCode: event.keyCode, flags: event.modifierFlags.rawValue)
            switch state.handle(input) {
            case let .recording(modifiers):
                held = modifiers
            case let .committed(key):
                hotkey = key
                if key.isUsedBySystem { hint = "\(key.displayName) is also a macOS shortcut; Local Flow takes it over while running." }
                recording = false
                held = 0
                swallowUp = key.isModifierOnly ? nil : key.keyCode
                if swallowUp == nil { stop() }
            case .cancelled:
                stop()
            }
            return event.type != .flagsChanged
        }
        tap = KeyTap(handler: handle)
        if tap == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { handle($0) ? nil : $0 }
        }
    }

    private func stop() {
        recording = false
        held = 0
        DictationController.shared.hotkeyPaused = false
        tap?.stop()
        tap = nil
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
