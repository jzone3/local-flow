import SwiftUI

/// First-run setup: welcome → permissions → how to transcribe → dictionary → done.
struct OnboardingView: View {
    static let windowSize = NSSize(width: 540, height: 600)

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var controller = DictationController.shared
    @ObservedObject private var downloader = ModelDownloader.shared
    @State private var step = 0
    @State private var foundKeys: [EnvironmentKeys.Found] = []

    private let stepCount = 5

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: permissions
                case 2: transcription
                case 3: dictionary
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
        .onAppear { foundKeys = EnvironmentKeys.scan() }
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
                    Button("Continue") { step += 1 }
                        .actionButton(prominent: true)
                        .keyboardShortcut(.defaultAction)
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

    private var permissions: some View {
        VStack(spacing: 26) {
            header("Two permissions", "macOS asks for these so Local Flow can hear you and type for you.", icon: "hand")
            VStack(spacing: 0) {
                permissionRow("mic", "Microphone", granted: AudioRecorder.hasPermission, detail: "To record while you hold the key.") {
                    Task { _ = await AudioRecorder.requestPermission(); controller.refreshPermissions() }
                }
                rowDivider
                permissionRow("accessibility", "Accessibility", granted: HotkeyMonitor.hasAccessibility, detail: "To notice the hotkey in any app and paste the text.") {
                    HotkeyMonitor.requestAccessibility()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
            .card()
            .id(controller.permissionProblem)
            Button("Re-check") { controller.refreshPermissions() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.callout)
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

    private var transcription: some View {
        VStack(spacing: 18) {
            header("How should it transcribe?", "You can change this any time in Settings.", icon: "waveform")
            Picker("", selection: $settings.engineMode) {
                ForEach(EngineMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)
            Text(settings.engineMode == .local
                 ? "Download a Whisper model. It runs on your GPU and audio never leaves this Mac."
                 : "Audio goes to the provider you pick, with your own key.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                if settings.engineMode == .local {
                    ModelList()
                } else {
                    CloudSettings()
                    if !foundKeys.isEmpty {
                        Section("Keys found on this Mac") {
                            ForEach(foundKeys, id: \.name) { item in
                                HStack {
                                    Text("\(item.name) · \(item.source) · \(EnvironmentKeys.masked(item.value))").font(.caption)
                                    Spacer()
                                    Button("Use") {
                                        guard let provider = CloudProviderID.allCases.first(where: { $0.environmentVariables.contains(item.name) }) else { return }
                                        Keychain.set(item.value, for: provider.keychainAccount)
                                        settings.cloudProviderID = provider.rawValue
                                    }
                                    .actionButton()
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, -20)
        }
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
                TextField("Hold \(settings.hotkey.displayName), say “I talk faster than I type.”, let go", text: $tryText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...3)
                    .controlSize(.large)
                    .onChange(of: controller.state) { _, state in if state == .listening { sawHotkey = true } }
                HStack(spacing: 6) {
                    switch controller.state {
                    case .listening:
                        Circle().fill(.red).frame(width: 7, height: 7)
                        Text("Listening…")
                    case .transcribing:
                        ProgressView().controlSize(.mini)
                        Text("Transcribing…")
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

/// A flat drawing of a Mac keyboard. The hotkey's key is labelled and presses itself on a loop until the user
/// really holds it, then it stays down for as long as they do.
struct KeyboardDemo: View {
    let hotkey: Hotkey
    let held: Bool
    @State private var demoDown = false
    @State private var ticker: Timer?

    private let key: CGFloat = 22
    private let gap: CGFloat = 4
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
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator))
        .animation(.easeInOut(duration: 0.12), value: down)
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

    private func keycap(width: CGFloat, label: String?, pressed: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        return ZStack {
            shape.fill(label == nil ? Color.primary.opacity(0.07) : (pressed ? Color.accentColor : Color.primary.opacity(0.85)))
            if let label {
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(.horizontal, 2)
            }
        }
        .frame(width: width, height: key)
        .shadow(color: .black.opacity(label == nil ? 0 : (pressed ? 0.05 : 0.25)), radius: pressed ? 1 : 4, y: pressed ? 0 : 3)
        .offset(y: pressed ? 2 : 0)
        .scaleEffect(pressed ? 0.96 : 1)
    }
}
