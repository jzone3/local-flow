import SwiftUI

/// First-run setup: welcome → permissions → local model → cloud models (optional) → dictionary → done.
struct OnboardingView: View {
    static let windowSize = NSSize(width: 540, height: 600)

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var controller = DictationController.shared
    @ObservedObject private var downloader = ModelDownloader.shared
    @State private var step = 0
    @State private var foundKeys: [EnvironmentKeys.Found]?  // nil until the user asks to import
    @State private var keyChanged = 0

    private let stepCount = 6

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: permissions
                case 2: localModel
                case 3: cloudModels
                case 4: dictionary
                default: done
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
                if step < stepCount - 1 {
                    Button(step == 3 && settings.engineMode == .local ? "Skip" : "Continue") { step += 1 }
                        .actionButton(prominent: true)
                        .keyboardShortcut(.defaultAction)
                        .disabled(step == 1 && !hasPermissions)
                } else {
                    Button("Start Dictating") {
                        settings.onboardingDone = true
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
                        Task { _ = await AudioRecorder.requestPermission(); controller.refreshPermissions() }
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
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in controller.refreshPermissions() }
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

    private var cloudModels: some View {
        VStack(spacing: 18) {
            header("Set up Frontier cloud models", "Optional", icon: "cloud")
            Text("Cloud models are more accurate for hard audio. Local Flow never saves your audio or transcripts and has no server or database of its own — audio goes straight from your Mac to the provider you pick. The providers may store what you send and use it for training, under their own terms.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                Section {
                    if let foundKeys {
                        HStack {
                            Text("Keys found on this Mac").font(.headline)
                            Spacer()
                            if foundKeys.filter({ provider(for: $0) != nil }).count > 1 {
                                Button("Use all") { foundKeys.forEach(use) }.actionButton().controlSize(.small)
                            }
                        }
                        Text("Local Flow found these in your shell files. Nothing is used until you click Use.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(CloudProviderID.allCases) { provider in
                            foundKeyRow(provider, found: foundKeys.first { self.provider(for: $0) == provider })
                        }
                    } else {
                        Button("Import API keys from your shell…") { foundKeys = EnvironmentKeys.scan() }
                            .actionButton()
                        Text("Looks for OPENAI_API_KEY, ELEVENLABS_API_KEY and GEMINI_API_KEY in your shell files. Nothing is saved until you click Use.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Or paste a key") {
                    ForEach(CloudProviderID.allCases) { provider in
                        ProviderKeyField(provider: provider) { keyChanged += 1 }
                    }
                }
                Section {
                    Picker("Mode", selection: $settings.engineMode) {
                        ForEach(EngineMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if settings.engineMode == .cloud {
                        MixtureOfExpertsToggle()
                    }
                }
                .id(keyChanged)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, -20)
        }
    }

    private func foundKeyRow(_ provider: CloudProviderID, found: EnvironmentKeys.Found?) -> some View {
        HStack(spacing: 10) {
            if provider.apiKey != nil || found != nil {
                Icon("check-circle", size: 16).foregroundStyle(.green)
            } else {
                Icon("x-circle", size: 16).foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.title)
                Group {
                    if provider.apiKey != nil {
                        Text("Saved in your Keychain")
                    } else if let found {
                        Text("Found \(found.name) in \(found.source) (\(EnvironmentKeys.masked(found.value)))")
                    } else {
                        Text("Not found")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if provider.apiKey == nil, let found {
                Button("Use") { use(found) }.actionButton().controlSize(.small)
            }
        }
        .id("\(provider.rawValue)-\(keyChanged)")
    }

    private func provider(for found: EnvironmentKeys.Found) -> CloudProviderID? {
        CloudProviderID.allCases.first { $0.environmentVariables.contains(found.name) }
    }

    private func use(_ found: EnvironmentKeys.Found) {
        guard let provider = provider(for: found) else { return }
        Keychain.set(found.value, for: provider.keychainAccount)
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
    @State private var tryText = ""
    @State private var sawHotkey = false

    private var done: some View {
        VStack(spacing: 18) {
            header("You're set", "Hold \(settings.hotkey.displayName) anywhere and talk. Let go to paste.\nDouble-tap it to keep listening hands-free; Esc cancels.", icon: "check-circle")
            KeyboardDemo(hotkey: settings.hotkey, held: controller.state == .listening)
            VStack(spacing: 8) {
                TextField("Say “I talk faster than I type.”", text: $tryText, axis: .vertical)
                    .textFieldStyle(.plain)
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
                        if sawHotkey {
                            Icon("check-circle", size: 13).foregroundStyle(.green)
                            Text(tryText.isEmpty ? "\(settings.hotkey.displayName) works. Try it again in any app." : "That's it. Works the same in any app.")
                        } else {
                            Text("Click the box, then press and hold \(settings.hotkey.displayName) to check it's working.")
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
            if controller.permissionProblem != nil {
                Label { Text("A permission is still missing; the key won't work until it's granted.") } icon: { Icon("warning", size: 14) }
                    .font(.callout).foregroundStyle(.orange)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fnConflict = Hotkey.systemDictationUsesFnTwice
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
