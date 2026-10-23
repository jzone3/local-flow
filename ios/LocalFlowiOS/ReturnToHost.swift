import Foundation

/// Sends you back to the app you were typing in once the text is copied.
/// iOS has no public API for this, so it uses the private LSApplicationWorkspace. False means it didn't work.
enum ReturnToHost {
    static func open(_ bundleID: String) -> Bool {
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
              let workspace = workspaceClass.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject
        else { return false }
        let open = NSSelectorFromString("openApplicationWithBundleID:")
        guard workspace.responds(to: open) else { return false }
        typealias Open = @convention(c) (AnyObject, Selector, NSString) -> Bool
        return unsafeBitCast(workspace.method(for: open), to: Open.self)(workspace, open, bundleID as NSString)
    }
}
