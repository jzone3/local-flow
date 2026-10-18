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

        let host = NSHostingController(rootView: WelcomeView().windowMaterial())
        host.sizingOptions = [.preferredContentSize]
        host.safeAreaRegions = []  // hidden title bar: no safe-area inset, so the content is padded evenly
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
                .font(.system(size: 20, weight: .semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)
            Text("You speak faster than you type. Local Flow keeps all voice dictation private. Nobody will train on your data, and all transcription runs locally.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)
            Text("Built with Devin by Cognition. Open source.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 28)
            HStack(spacing: 12) {
                Button("Source Code") { NSWorkspace.shared.open(Welcome.repoURL) }
                    .actionButton()
                Button("Get Started") { Welcome.dismiss() }
                    .actionButton(prominent: true)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 36)
        .padding(.top, 22)  // the icon artwork has its own margin; this reads as even with the 28 below
        .padding(.bottom, 28)
        .frame(width: 400)
        .overlay(alignment: .topLeading) {
            TryDevinLink()
                .padding(.leading, 16)
                .padding(.top, 14)
        }
    }

}

/// Quiet "Try Devin ↗" text in the sheet's corner: body-grey, blue only on hover.
private struct TryDevinLink: View {
    @State private var hover = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(Welcome.devinURL)
        } label: {
            Text("Try Devin \u{2197}")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(hover ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeInOut(duration: 0.12), value: hover)
        .help("Open devin.ai")
    }
}
