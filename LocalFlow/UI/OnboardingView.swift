import SwiftUI

/// First-run setup: welcome → permissions → local model → cloud? → (cloud keys) → dictionary → done.
struct OnboardingView: View {
    static let windowSize = NSSize(width: 540, height: 600)

    enum Step: Hashable { case welcome, permissions, localModel, cloudIntro, cloudKeys, dictionary, done }

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var controller = DictationController.shared
    @ObservedObject private var downloader = ModelDownloader.shared
    @State private var step = 0
    @State private var wantsCloud = false  // adds the cloud-keys step after "Set up cloud?"
    @State private var foundKeys: [EnvironmentKeys.Found] = []
    @State private var keyChanged = 0

    private var steps: [Step] {
        wantsCloud ? [.welcome, .permissions, .localModel, .cloudIntro, .cloudKeys, .dictionary, .done]
                   : [.welcome, .permissions, .localModel, .cloudIntro, .dictionary, .done]
    }
    private var stepCount: Int { steps.count }
    private var current: Step { steps[min(step, steps.count - 1)] }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch current {
                case .welcome: welcome
                case .permissions: permissions
                case .localModel: localModel
                case .cloudIntro: cloudIntro
                case .cloudKeys: cloudKeys
                case .dictionary: dictionary
                case .done: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
            .id(step)
            footer
        }
        .padding(.horizontal, 36)
        .padding(.top, 40)
        .padding(.bottom, 24)
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        .animation(.easeInOut(duration: 0.2), value: step)
        .transcribesDroppedFiles()
    }

    // MARK: Footer

    private var footer: some View {
        ZStack {
            HStack(spacing: 7) {
                ForEach(0..<stepCount, id: \.self) { i in
                    Capsule()
                        .fill(i == step ? Color.secondary : Color.secondary.opacity(0.3))
                        .frame(width: i == step ? 22 : 7, height: 7)
                }
            }
            .animation(.spring(duration: 0.3), value: step)
            HStack {
                if step > 0 {
                    Button("Back") { step -= 1 }.actionButton()
                }
                Spacer()
                if current == .cloudIntro {
                    EmptyView()  // the choice sits on the page; two footer buttons would run into the dots
                } else if step < stepCount - 1 {
                    Button(current == .cloudKeys && settings.cloudProvidersWithKeys.isEmpty ? "Skip" : "Continue") { step += 1 }
                        .actionButton(prominent: true)
                        .keyboardShortcut(.defaultAction)
                        .disabled(current == .permissions && !hasPermissions)
                } else {
                    Button("Start Dictating") {
                        settings.onboardingDone = true
                        if !settings.playSoundsChosen { settings.playSounds = false }
                        settings.setOpenAtLogin(true)
                        LocalWhisper.shared.preload()
                        WindowManager.shared.close("onboarding")
                    }
                    .actionButton(prominent: true)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .controlSize(.large)
        .padding(.top, 20)
    }

    // MARK: Pieces

    private func header(_ title: String, _ subtitle: String, icon: String? = nil) -> some View {
        VStack(spacing: 8) {
            if let icon {
                Icon(icon, size: 40)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
            Text(title).font(.system(size: 24, weight: .semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
    }

    private func row(_ icon: String, _ title: String, _ detail: String, @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View {
        HStack(spacing: 14) {
            Icon(icon, size: 20)
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)  // wrap instead of truncating in the fixed-size window
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private var rowDivider: some View { Divider().padding(.leading, 58) }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 26) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 104, height: 104)
                .shadow(color: .black.opacity(0.2), radius: 14, y: 8)
            header("Local Flow", "Hold a key, talk, let go.\nYour words appear wherever your cursor is.")
            VStack(spacing: 0) {
                row("lock", "Private by default", "Whisper runs on your Mac. Nothing leaves it unless you pick a cloud model.")
                rowDivider
                row("clock", "Nothing kept", "Transcripts and recordings are deleted when you quit, or after 12 hours.")
                rowDivider
                row("code", "Open source", "Add your own models and providers.")
            }
            .card()
        }
    }

    private var hasPermissions: Bool { controller.hasMicrophone && controller.hasAccessibility }

    private var permissions: some View {
        VStack(spacing: 26) {
            header("Two permissions", "macOS asks for these so Local Flow can hear you and type for you.", icon: "hand")
            VStack(spacing: 0) {
                permissionRow("mic", "Microphone", granted: controller.hasMicrophone, detail: "To record while you hold the key.") {
                    if AudioRecorder.isDenied {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    } else {
                        Task {
                            _ = await AudioRecorder.requestPermission()
                            controller.refreshPermissions()
                            // The system prompt belongs to another process; when it closes, focus goes back to whatever app was
                            // active before setup, not to this menu-bar app. Pull the window forward again.
                            WindowManager.shared.bringToFront("onboarding")
                        }
                    }
                }
                rowDivider
                permissionRow("accessibility", "Accessibility", granted: controller.hasAccessibility, detail: "To notice the hotkey in any app and paste the text.") {
                    HotkeyMonitor.requestAccessibility()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
            .card()
            VStack(spacing: 8) {
                if !hasPermissions {
                    Text("Both are needed to dictate.").font(.callout).foregroundStyle(.secondary)
                }
                Button("Re-check") { controller.refreshPermissions() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
        .onAppear { controller.refreshPermissions() }
        // Grants happen in System Settings, so poll while this step is showing; the rows flip to a check on their own.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            let hadAccessibility = controller.hasAccessibility
            controller.refreshPermissions()
            // Accessibility is granted over in System Settings; once the switch flips, come back so the user isn't left there.
            if !hadAccessibility && controller.hasAccessibility { WindowManager.shared.bringToFront("onboarding") }
        }
    }

    private func permissionRow(_ icon: String, _ name: String, granted: Bool, detail: String, action: @escaping () -> Void) -> some View {
        row(icon, name, detail) {
            if granted {
                Icon("check-circle", size: 20).foregroundStyle(.green)
            } else {
                Button("Allow", action: action).actionButton()
            }
        }
    }

    private var localModel: some View {
        VStack(spacing: 18) {
            header("Download a local model", "Whisper runs on your GPU and audio never leaves this Mac.", icon: "waveform")
            Form { ModelList(showsCustom: false) }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, -20)
        }
    }

    private var cloudIntro: some View {
        VStack(spacing: 18) {
            header("Want a cloud option too?", "Optional", icon: "cloud")
            VStack(alignment: .leading, spacing: 14) {
                Text("Local Flow also works with cloud speech models (OpenAI, ElevenLabs, Google), which are more accurate on hard audio. You bring your own API keys.")
                Text("Nothing is stored. Local Flow has no backend: your audio goes straight from this Mac to the provider you pick, with your key. The code is open source, so you can check for yourself. The providers may keep what you send under their own terms.")
                VStack(alignment: .leading, spacing: 4) {
                    Text(MixtureOfExperts.title).font(.headline)
                    Text(MixtureOfExperts.explanation)
                }
                Text("You can set this up later in Settings → Transcription.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
            .card(cornerRadius: 12)
            HStack(spacing: 12) {
                Button("Not now") { wantsCloud = false; step += 1 }
                    .actionButton()
                Button("Set up cloud") { wantsCloud = true; step += 1 }
                    .actionButton(prominent: true)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var importable: [EnvironmentKeys.Found] {
        foundKeys.filter { found in provider(for: found).map { $0.apiKey == nil } ?? false }
    }

    private var cloudKeys: some View {
        VStack(spacing: 18) {
            header("Add your API keys", "Keys stay in your Keychain and are only sent to their own provider.", icon: "key")
            Form {
                Section {
                    HStack {
                        Text("Keys").font(.headline)
                        Spacer()
                        if importable.count > 1 {
                            Button("Import all from shell") { importable.forEach(use) }.actionButton().controlSize(.small)
                        }
                    }
                    ForEach(CloudProviderID.allCases) { provider in
                        ProviderKeyRow(provider: provider, found: foundKeys.first { self.provider(for: $0) == provider }) { keyChanged += 1 }
                            .id("\(provider.rawValue)-\(keyChanged)")
                    }
                    Text("Local Flow looks for OPENAI_API_KEY, ELEVENLABS_API_KEY and GEMINI_API_KEY in your shell files (and the files they source). Nothing is saved until you click Import.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !settings.cloudProvidersWithKeys.isEmpty {
                    Section {
                        Picker("Mode", selection: $settings.engineMode) {
                            ForEach(EngineMode.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        if settings.engineMode == .cloud {
                            MixtureOfExpertsToggle()
                        }
                    } header: {
                        Text("Turn on \(MixtureOfExperts.title)?")
                    }
                    .id(keyChanged)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, -20)
        }
        .onAppear { foundKeys = EnvironmentKeys.scan() }
    }

    private func provider(for found: EnvironmentKeys.Found) -> CloudProviderID? {
        CloudProviderID.allCases.first { $0.environmentVariables.contains(found.name) }
    }

    private func use(_ found: EnvironmentKeys.Found) {
        guard let provider = provider(for: found) else { return }
        Keychain.set(found.value, for: provider.keychainAccount)
        AppSettings.shared.preferProviderWithKey()
        keyChanged += 1
    }

    private var dictionary: some View {
        VStack(spacing: 20) {
            header("What do you do?", "Pick any that apply. Each adds the names and jargon of that field\nto your dictionary, on top of the default list.", icon: "book")
            PackPicker()
            Text("\(settings.vocabulary.terms.count) terms. Edit any time in Settings → Dictionary.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @State private var fnConflict = Hotkey.systemDictationUsesFnTwice
    @State private var fnKeyAction = Hotkey.systemFnKeyAction
    @State private var tryText = ""
    @State private var sawHotkey = false
    @FocusState private var tryFocused: Bool

    /// Anything that can turn speech into text yet? Otherwise the test box would ask the user to talk into nothing.
    private var canTranscribe: Bool {
        WhisperModel.allIncludingCustom.contains(where: { $0.isDownloaded })
            || (settings.engineMode == .cloud && settings.cloudProvider.apiKey != nil)
    }

    private var done: some View {
        VStack(spacing: 18) {
            header("You're set", "Hold \(settings.hotkey.displayName) anywhere and talk. Let go to paste.\nDouble-tap it to keep listening hands-free; Esc cancels.", icon: "check-circle")
            KeyboardDemo(hotkey: settings.hotkey, held: controller.state == .listening)
            VStack(spacing: 8) {
                TextField(canTranscribe ? "Say “I talk faster than I type.”" : "No model downloaded yet", text: $tryText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($tryFocused)
                    .onAppear {
                        // Focus the box for them: holding the hotkey should type here without a click first.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            WindowManager.shared.bringToFront("onboarding")
                            tryFocused = true
                        }
                    }
                    .font(.system(size: 15))
                    .lineLimit(2...3)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: 380)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(controller.state == .listening ? Color.red.opacity(0.7) : Color.primary.opacity(0.2), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
                    .animation(.easeInOut(duration: 0.15), value: controller.state == .listening)
                    .onChange(of: controller.state) { _, state in if state == .listening { sawHotkey = true } }
                HStack(spacing: 6) {
                    switch controller.state {
                    case .listening:
                        Circle().fill(.red).frame(width: 7, height: 7)
                        Text("Listening…")
                    case .transcribing:
                        ProgressView().controlSize(.mini)
                        Text(controller.transcribingText)
                    default:
                        if !canTranscribe {
                            Icon("warning", size: 13).foregroundStyle(.orange)
                            Text("No model yet: go Back and download one, or add a cloud key.")
                        } else if sawHotkey {
                            Icon("check-circle", size: 13).foregroundStyle(.green)
                            Text(tryText.isEmpty ? "\(settings.hotkey.displayName) works. Try it again in any app." : "That's it. Works the same in any app.")
                        } else {
                            Text("Press and hold \(settings.hotkey.displayName) and say something to check it's working.")
                        }
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
                .frame(height: 18)
            }
            if settings.hotkey.isFn, fnConflict {
                HStack(spacing: 8) {
                    Icon("warning", size: 13).foregroundStyle(.orange)
                    Text("macOS also uses a double-tap of Fn for its own Dictation. For hands-free, set System Settings → Keyboard → Dictation shortcut to Off.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                    }
                    .actionButton().controlSize(.small)
                }
                .padding(12)
                .card(cornerRadius: 10)
            }
            if settings.hotkey.isFn, let clash = fnKeyAction.clash {
                HStack(spacing: 8) {
                    Icon("warning", size: 13).foregroundStyle(.orange)
                    Text("Pressing Fn also \(clash). Set System Settings → Keyboard → “Press 🌐 key to” to Do Nothing. Fn+E still opens emoji.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                    }
                    .actionButton().controlSize(.small)
                }
                .padding(12)
                .card(cornerRadius: 10)
            }
            if controller.permissionProblem != nil {
                Label { Text("A permission is still missing; the key won't work until it's granted.") } icon: { Icon("warning", size: 14) }
                    .font(.callout).foregroundStyle(.orange)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fnConflict = Hotkey.systemDictationUsesFnTwice
            fnKeyAction = Hotkey.systemFnKeyAction
        }
    }
}

/// A line drawing of a Mac keyboard. The hotkey's key is labelled and presses itself on a loop until the user
/// really holds it, then it stays down for as long as they do.
struct KeyboardDemo: View {
    let hotkey: Hotkey
    let held: Bool
    @State private var demoDown = false
    @State private var ticker: Timer?

    private let key: CGFloat = 24
    private let gap: CGFloat = 5
    private let rows: [[CGFloat]] = [  // key widths in units; the bottom row holds fn/ctrl/opt/cmd/space/cmd/opt
        Array(repeating: 1, count: 13) + [1.6],
        [1.6] + Array(repeating: 1, count: 13),
        [1.9] + Array(repeating: 1, count: 11) + [1.7],
        [2.4] + Array(repeating: 1, count: 10) + [2.2],
        [1, 1, 1, 1.3, 5.6, 1.3, 1, 1, 1],
    ]

    private var down: Bool { held || demoDown }

    /// (row, column) of the key that stands for the hotkey.
    private var target: (Int, Int) {
        switch hotkey.keyCode {
        case Hotkey.fn.keyCode: return (4, 0)
        case Hotkey.rightOption.keyCode: return (4, 6)
        case Hotkey.rightCommand.keyCode: return (4, 5)
        case 58: return (4, 2)   // left option
        case 55: return (4, 3)   // left command
        default: return (2, 6)   // some letter key: show it on the home row
        }
    }

    private let line = Color.primary.opacity(0.28)

    var body: some View {
        VStack(spacing: gap) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: gap) {
                    ForEach(rows[r].indices, id: \.self) { c in
                        let isTarget = (r, c) == target
                        keycap(width: rows[r][c] * key + (rows[r][c] - 1) * gap, label: isTarget ? hotkey.displayName : nil, pressed: isTarget && down)
                    }
                }
            }
        }
        .padding(14)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(line, lineWidth: 1))
        .animation(.easeInOut(duration: 0.14), value: down)
        .onAppear {
            ticker = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: true) { _ in
                demoDown.toggle()
            }
        }
        .onDisappear { ticker?.invalidate() }
        .onChange(of: held) { _, isHeld in
            if isHeld { ticker?.invalidate(); ticker = nil; demoDown = false }
        }
        .accessibilityLabel("Keyboard with the \(hotkey.displayName) key highlighted")
    }

    /// Plain keys are a single thin outline; the hotkey key is drawn solid and sinks when pressed.
    private func keycap(width: CGFloat, label: String?, pressed: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        return ZStack {
            if label == nil {
                shape.strokeBorder(line, lineWidth: 1)
            } else {
                shape.fill(pressed ? Color.accentColor : Color.primary)
            }
            if let label {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(.horizontal, 2)
            }
        }
        .frame(width: width, height: key)
        .shadow(color: .black.opacity(label == nil || pressed ? 0 : 0.18), radius: 3, y: 2)
        .offset(y: pressed ? 2 : 0)
        .scaleEffect(pressed ? 0.95 : 1)
    }
}
