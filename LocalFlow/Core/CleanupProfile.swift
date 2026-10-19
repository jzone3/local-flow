import Foundation

/// How far cleanup may go, picked from the app that will receive the text. Terminals, editors and address bars
/// get the words as spoken; chat apps get everything but the final period; everything else gets the full pass.
enum CleanupProfile: String, Equatable {
    case standard
    case casual
    case code

    static let codeApps: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "io.alacritty", "com.apple.dt.Xcode", "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.sublimetext.4", "org.vim.MacVim",
    ]
    static let chatApps: Set<String> = [
        "com.apple.MobileSMS", "com.tinyspeck.slackmacgap", "com.hnc.Discord", "net.whatsapp.WhatsApp",
        "ru.keepcoder.Telegram", "com.facebook.archon",
    ]
    static let browsers: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "org.mozilla.firefox",
        "com.brave.Browser", "com.microsoft.edgemac",
    ]

    /// `focusedRole` / `focusedDescription` are the AX role and description (or title) of the focused element,
    /// nil when Accessibility isn't granted or nothing is focused.
    static func `for`(bundleID: String?, focusedRole: String?, focusedDescription: String?) -> CleanupProfile {
        guard let bundleID else { return .standard }
        if codeApps.contains(bundleID) || bundleID.hasPrefix("com.jetbrains.") { return .code }
        if chatApps.contains(bundleID) { return .casual }
        if browsers.contains(bundleID), focusedRole == "AXTextField" || focusedRole == "AXComboBox",
           let description = focusedDescription?.lowercased(),
           description.contains("address") || description.contains("search") {
            return .code
        }
        return .standard
    }
}
