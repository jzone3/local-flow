import AppKit

/// Settings → About → "Remove All Data…": everything the app keeps outside its bundle, then quit.
enum DataRemoval {
    static func confirmAndRemove() {
        let alert = NSAlert()
        alert.messageText = "Remove all Local Flow data and quit?"
        alert.informativeText = "Deletes the downloaded models, history, settings and the API keys saved in your Keychain. Then drag Local Flow to the Trash to uninstall."
        alert.addButton(withTitle: "Remove and Quit").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            removeAll()
            NSApp.terminate(nil)
        }
        if let window = NSApp.keyWindow { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }

    static func removeAll() {
        CloudProviderID.allCases.forEach { Keychain.delete($0.keychainAccount) }
        try? FileManager.default.removeItem(at: AppSettings.supportDirectory)
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
    }
}
