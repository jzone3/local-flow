import AppKit

/// A copy launched from the disk image or a translocated path can't update itself; offer to put it in /Applications first.
enum MoveToApplications {
    private static let declinedKey = "moveToApplicationsDeclined"

    static var bundleURL: URL { Bundle.main.bundleURL.resolvingSymlinksInPath() }
    static var isRunningFromTemporaryLocation: Bool {
        bundleURL.path.hasPrefix("/Volumes/") || bundleURL.path.contains("/AppTranslocation/")
    }

    static var destination: URL {
        URL(fileURLWithPath: "/Applications", isDirectory: true).appendingPathComponent(bundleURL.lastPathComponent)
    }

    static func offerIfNeeded(then next: @escaping () -> Void) {
        guard isRunningFromTemporaryLocation, !UserDefaults.standard.bool(forKey: declinedKey),
              FileManager.default.isWritableFile(atPath: "/Applications") else { return next() }
        let alert = NSAlert()
        alert.messageText = "Move Local Flow to the Applications folder?"
        let from = bundleURL.path.hasPrefix("/Volumes/") ? "the disk image" : "a temporary location"
        alert.informativeText = "It's running from \(from). In Applications it keeps its settings, starts without this step and can update itself."
        alert.addButton(withTitle: "Move and Relaunch")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.level = .floating
        if alert.runModal() == .alertFirstButtonReturn {
            do {
                try move()
                return  // relaunching from /Applications
            } catch {
                let failed = NSAlert()
                failed.messageText = "Couldn't move Local Flow."
                failed.informativeText = "\(error.localizedDescription) Drag Local Flow to your Applications folder instead."
                failed.runModal()
            }
        } else {
            UserDefaults.standard.set(true, forKey: declinedKey)
        }
        next()
    }

    private static func move() throws {
        let fm = FileManager.default
        let target = destination
        if fm.fileExists(atPath: target.path) { try fm.trashItem(at: target, resultingItemURL: nil) }
        try fm.copyItem(at: bundleURL, to: target)
        // Gatekeeper already approved this launch; a quarantined copy would be translocated again.
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", target.path]
        try xattr.run()
        xattr.waitUntilExit()
        relaunch(from: target)
    }

    /// Waits for this process to exit, opens the new copy, then ejects the disk image it was launched from.
    private static func relaunch(from target: URL) {
        var mount = ""
        if bundleURL.path.hasPrefix("/Volumes/") {
            mount = "/Volumes/" + bundleURL.pathComponents[2]
        }
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        open "$2"
        if [ -n "$3" ]; then sleep 2; /usr/bin/hdiutil detach "$3" -quiet -force; fi
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), target.path, mount]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        NSApp.terminate(nil)
    }
}
