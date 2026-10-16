import AppKit
import Carbon.HIToolbox

/// Types the transcript into whatever app has focus: put it on the pasteboard, send ⌘V, then restore what
/// the user had copied before.
enum TextInserter {
    static func insert(_ text: String, completion: (() -> Void)? = nil) {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { copy[type] = data } }
            return copy
        } ?? []
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        sendPaste()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if pasteboard.string(forType: .string) == text {
                pasteboard.clearContents()
                let items = saved.map { dict -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    for (type, data) in dict { item.setData(data, forType: type) }
                    return item
                }
                if !items.isEmpty { pasteboard.writeObjects(items) }
            }
            completion?()
        }
    }

    private static func sendPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
