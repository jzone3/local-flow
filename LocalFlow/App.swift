import SwiftUI

@main
struct LocalFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var controller = DictationController.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some Scene {
        MenuBarExtra {
            Text(controller.statusLine)
            Divider()
            Button("Settings…") { WindowManager.shared.showSettings() }
                .keyboardShortcut(",")
            Button("History…") { WindowManager.shared.showHistory() }
            Divider()
            Button("Check for Updates…") { UpdateChecker.shared.check(userInitiated: true) }
            Button("Run Setup Again…") { WindowManager.shared.showOnboarding() }
            Divider()
            Button("Quit Local Flow") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: controller.state.isActive ? "waveform.circle.fill" : "waveform")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        _ = HistoryStore.shared
        DictationController.shared.start()
        if AppSettings.shared.onboardingDone {
            LocalWhisper.shared.preload()
        } else {
            WindowManager.shared.showOnboarding()
        }
        UpdateChecker.shared.checkOnLaunch()
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

    func showSettings() { show("settings", title: "Local Flow Settings", size: NSSize(width: 640, height: 560)) { SettingsView() } }
    func showHistory() { show("history", title: "History", size: NSSize(width: 560, height: 480)) { HistoryView() } }
    func showOnboarding() {
        show("onboarding", title: "Welcome to Local Flow", size: OnboardingView.windowSize, fixed: true) { OnboardingView() }
    }

    func close(_ key: String) { windows[key]?.close() }

    /// `fixed` windows (setup) have one size and no visible title bar, so the content sits under the traffic lights.
    private func show<V: View>(_ key: String, title: String, size: NSSize, fixed: Bool = false, @ViewBuilder content: () -> V) {
        NSApp.activate(ignoringOtherApps: true)
        if let window = windows[key] {
            window.makeKeyAndOrderFront(nil)
            return
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
            ? AnyView(content())
            : AnyView(content().frame(minWidth: size.width, minHeight: size.height))
        window.contentViewController = NSHostingController(rootView: root)
        window.center()
        window.makeKeyAndOrderFront(nil)
        windows[key] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            self?.windows[key] = nil
        }
    }
}
