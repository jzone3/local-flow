import SwiftUI

@main
struct LocalFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var controller = DictationController.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var history = HistoryStore.shared

    var body: some Scene {
        MenuBarExtra {
            Text(controller.statusLine)
            Text(settings.engineMode == .local
                 ? "Local: On · nothing leaves this Mac"
                 : "Local: Off · Cloud (\(settings.mixtureOfExperts ? MixtureOfExperts.title : settings.cloudProvider.title))")
            Divider()
            Button("Settings…") { WindowManager.shared.showSettings() }
                .keyboardShortcut(",")
            Button("History…") { WindowManager.shared.showHistory() }
            Button("Last Transcript…") { WindowManager.shared.showLastTranscript() }
                .disabled(history.entries.isEmpty)
            Divider()
            Button("Check for Updates…") { UpdateChecker.shared.check(userInitiated: true) }
            Button("Run Setup Again…") { WindowManager.shared.showOnboarding() }
            Divider()
            Button("Quit Local Flow") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(nsImage: Icon.nsImage(controller.state.isActive ? "waveform-circle" : "waveform", size: 18))
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second copy would add a second menu bar icon and paste every dictation twice.
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
               .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        _ = HistoryStore.shared
        DictationController.shared.start()
        Welcome.showIfNeeded {
            if AppSettings.shared.onboardingDone {
                LocalWhisper.shared.preload()
            } else {
                WindowManager.shared.showOnboarding()
            }
            UpdateChecker.shared.checkOnLaunch()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowManager.shared.showSettings() }
        return true
    }
}

/// Opens the app's few windows (settings, history, setup) as plain NSWindows so they work from a menu bar app.
@MainActor
final class WindowManager {
    static let shared = WindowManager()
    private var windows: [String: NSWindow] = [:]

    @discardableResult
    func showSettings() -> NSWindow { show("settings", title: "Local Flow Settings", size: NSSize(width: 640, height: 560)) { SettingsView() } }
    func showHistory() { show("history", title: "History", size: NSSize(width: 560, height: 480)) { HistoryView() } }
    func showLastTranscript() { show("last", title: "Last Transcript", size: NSSize(width: 460, height: 260)) { LastTranscriptView() } }
    func showOnboarding() {
        show("onboarding", title: "Welcome to Local Flow", size: OnboardingView.windowSize, fixed: true) { OnboardingView() }
    }

    func close(_ key: String) { windows[key]?.close() }

    /// `fixed` windows (setup) have one size and no visible title bar, so the content sits under the traffic lights.
    @discardableResult
    private func show<V: View>(_ key: String, title: String, size: NSSize, fixed: Bool = false, @ViewBuilder content: () -> V) -> NSWindow {
        NSApp.activate(ignoringOtherApps: true)
        if let window = windows[key] {
            window.makeKeyAndOrderFront(nil)
            return window
        }
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if fixed { style.insert(.fullSizeContentView) } else { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.titlebarAppearsTransparent = true
        if fixed {
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
        }
        window.isReleasedWhenClosed = false
        let root = fixed
            ? AnyView(content().windowMaterial())
            : AnyView(content().frame(minWidth: size.width, minHeight: size.height).windowMaterial())
        window.contentViewController = NSHostingController(rootView: root)
        window.setContentSize(size)
        window.center()
        window.makeKeyAndOrderFront(nil)
        windows[key] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            self?.windows[key] = nil
        }
        return window
    }
}

/// The newest history entry on its own, with a Copy button. Follows the store, so it updates after each dictation.
struct LastTranscriptView: View {
    @ObservedObject private var history = HistoryStore.shared
    @State private var copied = false

    private var entry: HistoryEntry? { history.entries.max { $0.date < $1.date } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let entry {
                ScrollView {
                    Text(entry.text)
                        .font(.system(size: 14))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Text("\(entry.date.formatted(date: .omitted, time: .shortened)) · \(entry.engine)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.text, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }
                    .keyboardShortcut("c")
                }
            } else {
                Text("Nothing dictated yet this session.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        .frame(minWidth: 360, minHeight: 200)
    }
}
