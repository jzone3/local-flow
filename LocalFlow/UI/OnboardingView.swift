import SwiftUI

/// First-run setup: permissions → how to transcribe → dictionary → done.
struct OnboardingView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var controller = DictationController.shared
    @ObservedObject private var downloader = ModelDownloader.shared
    @State private var step = 0
    @State private var foundKeys: [EnvironmentKeys.Found] = []
    @State private var showBuilder = false

    private let steps = ["Welcome", "Permissions", "Transcription", "Dictionary", "Done"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                ForEach(steps.indices, id: \.self) { i in
                    Capsule().fill(i <= step ? Color.primary : Color.secondary.opacity(0.25)).frame(height: 3)
                }
            }
            Group {
                switch step {
                case 0: welcome
                case 1: permissions
                case 2: transcription
                case 3: dictionary
                default: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                if step < steps.count - 1 {
                    Button("Continue") { step += 1 }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Start Dictating") {
                        settings.onboardingDone = true
                        LocalWhisper.shared.preload()
                        WindowManager.shared.close("onboarding")
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(28)
        .onAppear { foundKeys = EnvironmentKeys.scan() }
        .sheet(isPresented: $showBuilder) { DictionaryBuilderSheet(onDone: { showBuilder = false }) }
    }

    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title.bold())
            Text(subtitle).foregroundStyle(.secondary)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Local Flow", "Hold a key, talk, let go. Your words appear wherever your cursor is.")
            VStack(alignment: .leading, spacing: 10) {
                Label("Runs Whisper on your Mac. Nothing leaves it unless you choose a cloud model.", systemImage: "lock.shield")
                Label("Transcripts and recordings are deleted after 12 hours.", systemImage: "clock.arrow.circlepath")
                Label("Open source. Add your own models and providers.", systemImage: "chevron.left.forwardslash.chevron.right")
            }
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Two permissions", "macOS asks for these so Local Flow can hear you and type for you.")
            permissionRow("Microphone", granted: AudioRecorder.hasPermission, detail: "To record while you hold the key.") {
                Task { _ = await AudioRecorder.requestPermission(); controller.refreshPermissions() }
            }
            permissionRow("Accessibility", granted: HotkeyMonitor.hasAccessibility, detail: "To notice the hotkey in any app and paste the text.") {
                HotkeyMonitor.requestAccessibility()
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
            Button("Re-check") { controller.refreshPermissions() }.controlSize(.small)
        }
    }

    private func permissionRow(_ name: String, granted: Bool, detail: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle").foregroundStyle(granted ? .green : .secondary)
            VStack(alignment: .leading) {
                Text(name).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button("Allow", action: action) }
        }
        .id(controller.permissionProblem)
    }

    private var transcription: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("How should it transcribe?", "You can change this any time in Settings.")
            Picker("", selection: $settings.engineMode) {
                ForEach(EngineMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            if settings.engineMode == .local {
                Text("Download a Whisper model. It runs on your GPU and audio never leaves this Mac.").font(.callout)
                ScrollView { Form { ModelList() }.formStyle(.grouped) }
            } else {
                Form {
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
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
    }

    private var dictionary: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Your dictionary", "Names, products and jargon spelled your way. You start with a default list.")
            Text("Answer one question about who you are and what you do, and Local Flow suggests words to add. Your answer is only used for that request and is not saved.")
                .foregroundStyle(.secondary)
            Button("Answer the Question…") { showBuilder = true }
            Text("\(settings.vocabulary.terms.count) terms in your dictionary. Edit them any time in Settings → Dictionary.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("You're set", "Hold \(settings.hotkey.displayName) anywhere and start talking.")
            VStack(alignment: .leading, spacing: 8) {
                Label("Let go to paste. Press Esc while holding to cancel.", systemImage: "keyboard")
                Label("Say \"new paragraph\" or \"new line\" for breaks.", systemImage: "text.alignleft")
                Label("Cleanup (ums, caps, punctuation) is on and happens on this Mac. Turn it off in Settings → Privacy.", systemImage: "sparkles")
                Label("The menu bar icon has Settings, History and updates.", systemImage: "menubar.rectangle")
            }
            if controller.permissionProblem != nil {
                Label("A permission is still missing; the key won't work until it's granted.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }
}
