import AppKit
import SwiftUI

/// One-time "thanks for downloading" sheet on first launch; the Get Started opens the author's X profile behind the app.
enum Welcome {
    static let shownKey = "welcomeShown"
    static let repoURL = URL(string: "https://github.com/jzone3/local-flow")!
    static let authorURL = URL(string: "https://x.com/imjaredz")!
    static let devinURL = URL(string: "https://devin.ai")!

    @MainActor
    static func showIfNeeded(then next: @escaping () -> Void) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: shownKey) else { return next() }
        defaults.set(true, forKey: shownKey)

        let host = NSHostingController(rootView: WelcomeView())
        host.sizingOptions = [.preferredContentSize]
        let sheet = NSWindow(contentViewController: host)
        sheet.setContentSize(host.view.fittingSize)
        sheet.styleMask = [.titled, .fullSizeContentView]
        sheet.titlebarAppearsTransparent = true
        sheet.titleVisibility = .hidden
        sheet.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)
        sheet.center()
        NSApp.runModal(for: sheet)
        sheet.orderOut(nil)
        openInBackground(authorURL)
        next()
    }

    static func dismiss() { NSApp.stopModal() }

    /// Opens the URL without bringing the browser in front of the app.
    static func openInBackground(_ url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.open(url, configuration: config)
    }
}

private struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
                .padding(.bottom, 18)
            Text("Thanks for downloading\nLocal Flow")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)
            Text(.init("I built this with [Devin](https://devin.ai), Cognition's AI software engineer. The whole thing is open source."))
                .tint(.primary)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 28)
            HStack(spacing: 10) {
                pill("Source Code", filled: false) { NSWorkspace.shared.open(Welcome.repoURL) }
                pill("Get Started", filled: true) { Welcome.dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 36)
        .padding(.bottom, 28)
        .frame(width: 400)
    }

    private func pill(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(filled ? Color(nsColor: .windowBackgroundColor) : Color.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(filled ? Color.primary : Color.clear, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(filled ? 0 : 0.25), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
