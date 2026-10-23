import UIKit

/// The bundle ID of the app this keyboard is typing into, so Local Flow can send you back to it.
/// Private UIKit: `_hostApplicationBundleIdentifier` (empty on iOS 26+), else the host's PID → its .app bundle.
enum HostApp {
    static func bundleID(of keyboard: UIInputViewController) -> String? {
        let idSelector = NSSelectorFromString("_hostApplicationBundleIdentifier")
        if keyboard.responds(to: idSelector),
           let id = keyboard.perform(idSelector)?.takeUnretainedValue() as? String, id.contains(".") {
            return id
        }
        let pidSelector = NSSelectorFromString("_hostProcessIdentifier")
        guard keyboard.responds(to: pidSelector),
              let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "proc_pidpath") else { return nil }
        typealias GetPID = @convention(c) (AnyObject, Selector) -> pid_t
        let pid = unsafeBitCast(keyboard.method(for: pidSelector), to: GetPID.self)(keyboard, pidSelector)
        typealias PIDPath = @convention(c) (pid_t, UnsafeMutableRawPointer, UInt32) -> Int32
        var path = [CChar](repeating: 0, count: 4096)
        guard pid > 0, unsafeBitCast(symbol, to: PIDPath.self)(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let app = URL(fileURLWithPath: String(cString: path)).deletingLastPathComponent()
        return Bundle(url: app)?.bundleIdentifier
    }
}
