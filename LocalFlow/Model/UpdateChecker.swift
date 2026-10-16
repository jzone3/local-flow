import AppKit
import SwiftUI

/// Checks GitHub Releases for a newer build and swaps it into place: download the DMG, copy the
/// app next to the running bundle, then a detached shell script does the rename once we exit.
final class UpdateChecker: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = UpdateChecker()
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/jzone3/local-flow/releases/latest")!
    static let assetName = "Local-Flow.dmg"
    static let latestDownloadURL = URL(string: "https://github.com/jzone3/local-flow/releases/latest/download/\(assetName)")!
    static let checkInterval: TimeInterval = 24 * 60 * 60
    private static let lastCheckKey = "updateLastCheck"
    private static let skippedVersionKey = "updateSkippedVersion"

    struct Version: Comparable, CustomStringConvertible {
        let parts: [Int]

        init?(_ string: String) {
            let digits = string.hasPrefix("v") ? String(string.dropFirst()) : string
            let parts = digits.split(separator: ".").map { Int($0) }
            guard !parts.isEmpty, !parts.contains(nil) else { return nil }
            self.parts = parts.compactMap { $0 }
        }

        static func < (lhs: Version, rhs: Version) -> Bool {
            let count = max(lhs.parts.count, rhs.parts.count)
            let l = lhs.parts + Array(repeating: 0, count: count - lhs.parts.count)
            let r = rhs.parts + Array(repeating: 0, count: count - rhs.parts.count)
            return l.lexicographicallyPrecedes(r)
        }

        var description: String { parts.map(String.init).joined(separator: ".") }
    }

    struct Release {
        let version: Version
        let downloadURL: URL

        init(version: Version, downloadURL: URL) {
            self.version = version
            self.downloadURL = downloadURL
        }

        init?(json: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
                  let tag = object["tag_name"] as? String, let version = Version(tag),
                  let assets = object["assets"] as? [[String: Any]],
                  let asset = assets.first(where: { $0["name"] as? String == UpdateChecker.assetName }),
                  let url = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)),
                  url.scheme == "https", url.host == "github.com" else { return nil }
            self.version = version
            downloadURL = url
        }
    }

    static var currentVersion: Version {
        Version(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") ?? Version("0")!
    }

    @Published private(set) var isChecking = false
    private var downloadSession: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var progressWindow: UpdateProgressWindow?
    private var pendingRelease: Release?

    func checkOnLaunch() {
        if let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < Self.checkInterval { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.check(userInitiated: false) }
    }

    func check(userInitiated: Bool) {
        guard !isChecking, downloadTask == nil else { return }
        isChecking = true
        var request = URLRequest(url: Self.latestReleaseURL, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            switch (response as? HTTPURLResponse)?.statusCode {
            case 200: self.finishCheck(data.flatMap(Release.init(json:)), userInitiated: userInitiated)
            case 403, 429: self.probeLatestRedirect(userInitiated: userInitiated)
            default: self.finishCheck(nil, userInitiated: userInitiated)
            }
        }.resume()
    }

    /// The unauthenticated API allows 60 requests/hour per IP, so on a shared network it often answers 403.
    /// The stable download link redirects to `/releases/download/vX.Y.Z/…` and isn't rate-limited.
    private func probeLatestRedirect(userInitiated: Bool) {
        var request = URLRequest(url: Self.latestDownloadURL, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        let session = URLSession(configuration: .ephemeral, delegate: RedirectCatcher(), delegateQueue: nil)
        session.dataTask(with: request) { _, response, _ in
            var release: Release?
            if let http = response as? HTTPURLResponse, (300..<400).contains(http.statusCode),
               let location = http.value(forHTTPHeaderField: "Location").flatMap({ URL(string: $0, relativeTo: Self.latestDownloadURL)?.absoluteURL }),
               location.scheme == "https", location.host == "github.com",
               location.pathComponents.count >= 3, location.lastPathComponent == Self.assetName,
               let version = Version(location.pathComponents[location.pathComponents.count - 2]) {
                release = Release(version: version, downloadURL: location)
            }
            session.finishTasksAndInvalidate()
            self.finishCheck(release, userInitiated: userInitiated)
        }.resume()
    }

    private final class RedirectCatcher: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private func finishCheck(_ release: Release?, userInitiated: Bool) {
        DispatchQueue.main.async {
            self.isChecking = false
            if release != nil { UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey) }
            self.handle(release, userInitiated: userInitiated)
        }
    }

    private func handle(_ release: Release?, userInitiated: Bool) {
        let current = Self.currentVersion
        guard let release else {
            if userInitiated {
                present(alert("Couldn't check for updates.", "Local Flow couldn't reach GitHub. Check your connection and try again."))
            }
            return
        }
        guard release.version > current else {
            if userInitiated {
                present(alert("You're up to date", "Local Flow \(current) is the latest version."))
            }
            return
        }
        if !userInitiated, UserDefaults.standard.string(forKey: Self.skippedVersionKey) == release.version.description { return }

        let alert = alert("Local Flow \(release.version) is available",
                          "You have \(current). The update is downloaded from GitHub and installed into \(installLocationName).")
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        present(alert) { response in
            switch response {
            case .alertFirstButtonReturn: self.install(release)
            case .alertThirdButtonReturn: UserDefaults.standard.set(release.version.description, forKey: Self.skippedVersionKey)
            default: break
            }
        }
    }

    // MARK: - Install

    private var bundleURL: URL { Bundle.main.bundleURL.resolvingSymlinksInPath() }

    private var installLocationName: String {
        let parent = bundleURL.deletingLastPathComponent()
        return parent.path == "/Applications" ? "/Applications" : parent.lastPathComponent
    }

    /// The swap needs to rename the running bundle; a DMG/translocated copy or a read-only folder can't be replaced in place.
    private var canInstallInPlace: Bool {
        #if DEBUG
        return false
        #else
        let parent = bundleURL.deletingLastPathComponent().path
        let translocated = bundleURL.path.contains("/AppTranslocation/")
        return !translocated && bundleURL.pathExtension == "app"
            && FileManager.default.isWritableFile(atPath: parent)
        #endif
    }

    private func install(_ release: Release) {
        guard canInstallInPlace else {
            let alert = alert("Local Flow \(release.version) will download in your browser",
                              "This copy can't update itself from \(bundleURL.deletingLastPathComponent().path). Open the downloaded disk image and drag Local Flow to your Applications folder.")
            present(alert) { _ in NSWorkspace.shared.open(release.downloadURL) }
            return
        }
        pendingRelease = release
        let window = UpdateProgressWindow(version: release.version.description) { [weak self] in self?.cancelDownload() }
        progressWindow = window
        window.show()
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        let task = session.downloadTask(with: release.downloadURL)
        downloadSession = session
        downloadTask = task
        task.resume()
    }

    private func cancelDownload() {
        downloadTask?.cancel()
        finishDownload()
    }

    private func finishDownload() {
        downloadSession?.invalidateAndCancel()
        downloadSession = nil
        downloadTask = nil
        pendingRelease = nil
        progressWindow?.close()
        progressWindow = nil
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progressWindow?.setProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        finishDownload()
        present(alert("The update couldn't be downloaded.", error.localizedDescription))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let release = pendingRelease else { return }
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("LocalFlowUpdate-\(ProcessInfo.processInfo.processIdentifier)")
        let dmg = workDir.appendingPathComponent(Self.assetName)
        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: dmg)
        } catch {
            finishDownload()
            present(alert("The update couldn't be installed.", error.localizedDescription))
            return
        }
        progressWindow?.setInstalling()
        let bundleURL = bundleURL
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Self.stage(dmg: dmg, in: workDir, next: bundleURL) }
            DispatchQueue.main.async {
                switch result {
                case .success(let staged):
                    let confirm = self.alert("Install Local Flow \(release.version) and relaunch?", "Local Flow will quit for a moment while the update is installed.")
                    confirm.addButton(withTitle: "Install and Relaunch")
                    confirm.addButton(withTitle: "Cancel")
                    self.present(confirm) { response in
                        if response == .alertFirstButtonReturn {
                            self.relaunch(replacing: bundleURL, with: staged, cleaning: workDir)
                        } else {
                            try? FileManager.default.removeItem(at: staged)
                            try? FileManager.default.removeItem(at: workDir)
                            self.finishDownload()
                        }
                    }
                case .failure(let error):
                    try? FileManager.default.removeItem(at: workDir)
                    self.finishDownload()
                    self.present(self.alert("The update couldn't be installed.",
                                            "\(error.localizedDescription) Version \(release.version) can be downloaded from GitHub instead."))
                }
            }
        }
    }

    /// Mounts the DMG, copies the app to a sibling of the current bundle (same volume, so the swap is a rename) and unmounts.
    private static func stage(dmg: URL, in workDir: URL, next bundleURL: URL) throws -> URL {
        let mountPoint = workDir.appendingPathComponent("mount")
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-noverify", "-quiet", "-mountpoint", mountPoint.path, dmg.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mountPoint.path]) }
        let contents = try FileManager.default.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
            throw NSError(domain: "UpdateChecker", code: 1, userInfo: [NSLocalizedDescriptionKey: "The disk image doesn't contain an app."])
        }
        let staged = bundleURL.deletingLastPathComponent().appendingPathComponent(".\(bundleURL.lastPathComponent).update")
        try? FileManager.default.removeItem(at: staged)
        do {
            try FileManager.default.copyItem(at: app, to: staged)
            try verify(staged)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        return staged
    }

    /// The downloaded app must be this app (same bundle identifier) with an intact signature from the same team.
    private static func verify(_ app: URL) throws {
        let identifier = Bundle(url: app)?.bundleIdentifier
        guard identifier == Bundle.main.bundleIdentifier else {
            throw NSError(domain: "UpdateChecker", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "The downloaded app is \(identifier ?? "unknown"), not Local Flow."])
        }
        var arguments = ["--verify", "--deep", "--strict"]
        if let team = ownTeamIdentifier {
            arguments.append("-R=anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"")
        }
        try run("/usr/bin/codesign", arguments + [app.path])
    }

    private static var ownTeamIdentifier: String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func run(_ launchPath: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "UpdateChecker", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: message.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
    }

    /// Hands the swap to a detached shell that waits for this process to exit, so the bundle is never replaced while
    /// running. A failed rename puts the old app back and clears the check date so the next launch offers the update again.
    private func relaunch(replacing old: URL, with staged: URL, cleaning workDir: URL) {
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        if mv "$2" "$2.old" && mv "$3" "$2"; then
          rm -rf "$2.old"
        else
          mv "$2.old" "$2" 2>/dev/null; rm -rf "$3"; defaults delete "$5" "$6" 2>/dev/null
        fi
        rm -rf "$4"
        open "$2"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), old.path, staged.path, workDir.path,
                             Bundle.main.bundleIdentifier ?? "", Self.lastCheckKey]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: staged)
            try? FileManager.default.removeItem(at: workDir)
            finishDownload()
            present(alert("The update couldn't be installed.", error.localizedDescription))
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: - Alerts

    private func alert(_ message: String, _ informative: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        return alert
    }

    /// Deferred a turn so an alert chosen from another sheet's completion handler lands after that sheet has gone.
    private func present(_ alert: NSAlert, completion: ((NSApplication.ModalResponse) -> Void)? = nil) {
        DispatchQueue.main.async {
            if let window = NSApp.keyWindow, window.attachedSheet == nil {
                alert.beginSheetModal(for: window) { completion?($0) }
            } else {
                completion?(alert.runModal())
            }
        }
    }
}

final class UpdateProgressWindow: NSWindow {
    private let label = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let cancel: () -> Void

    init(version: String, onCancel: @escaping () -> Void) {
        cancel = onCancel
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 96), styleMask: [.titled], backing: .buffered, defer: false)
        title = "Updating Local Flow"
        isReleasedWhenClosed = false
        label.stringValue = "Downloading Local Flow \(version)…"
        label.frame = NSRect(x: 20, y: 62, width: 340, height: 18)
        bar.frame = NSRect(x: 20, y: 40, width: 340, height: 20)
        bar.minValue = 0
        bar.maxValue = 1
        bar.isIndeterminate = true
        let button = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        button.keyEquivalent = "\u{1b}"
        button.frame = NSRect(x: 280, y: 8, width: 80, height: 28)
        [label, bar, button].forEach { contentView?.addSubview($0) }
    }

    func show() {
        bar.startAnimation(nil)
        center()
        makeKeyAndOrderFront(nil)
    }

    func setProgress(_ fraction: Double) {
        bar.isIndeterminate = false
        bar.doubleValue = fraction
    }

    func setInstalling() {
        label.stringValue = "Installing…"
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        contentView?.subviews.compactMap { $0 as? NSButton }.forEach { $0.isEnabled = false }
    }

    @objc private func cancelPressed() { cancel() }
}

struct UpdateCommands: Commands {
    @ObservedObject private var checker = UpdateChecker.shared

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { checker.check(userInitiated: true) }
                .disabled(checker.isChecking)
        }
    }
}
