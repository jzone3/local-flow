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
                        .fill(i == step ? Color.primary : Color.primary.opacity(0.18))
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
            Text(title).font(.system(size: 26, weight: .bold))
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
                row("clock", "Nothing kept for long", "Transcripts and recordings are deleted after 12 hours.")
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

    private var done: some View {
        VStack(spacing: 26) {
            header("You're set", "Hold \(settings.hotkey.displayName) anywhere and start talking.", icon: "check-circle")
            VStack(spacing: 0) {
                row("keyboard", "Let go to paste", "Press Esc while holding to cancel.")
                rowDivider
                row("text-lines", "Breaks", "Say \"new paragraph\" or \"new line\".")
                rowDivider
                row("sparkles", "Cleanup is on", "Ums, caps and punctuation are fixed on this Mac. Turn it off in Settings → Privacy.")
                rowDivider
                row("menubar", "Menu bar", "Settings, History and updates live there.")
            }
            .card()
            if controller.permissionProblem != nil {
                Label { Text("A permission is still missing; the key won't work until it's granted.") } icon: { Icon("warning", size: 14) }
                    .font(.callout).foregroundStyle(.orange)
            }
        }
    }
}
