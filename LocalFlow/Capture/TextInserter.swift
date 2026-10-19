import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Types the transcript into whatever app has focus: put it on the pasteboard, send ⌘V, then restore what
/// the user had copied before.
enum TextInserter {
    static func insert(_ transcript: String, completion: (() -> Void)? = nil) {
        let context = cursorContext()
        let text = TextCleanup.fit(transcript, before: context?.before ?? "", after: context?.after ?? "")
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

    /// Role and description (or title) of the focused element, for picking a cleanup profile. Nil without Accessibility.
    static func focusedElement() -> (role: String?, description: String?)? {
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(focusedRef, to: AXUIElement.self)
        func string(_ attribute: String) -> String? {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
            return ref as? String
        }
        let description = [string(kAXDescriptionAttribute), string(kAXTitleAttribute)].compactMap { $0 }.first { !$0.isEmpty }
        return (string(kAXRoleAttribute), description)
    }

    /// The characters just before and after the caret in the focused text field, via Accessibility. Nil when the
    /// focused element doesn't expose its text (Terminal, secure fields, some web views) — then nothing is adjusted.
    static func cursorContext() -> (before: String, after: String)? {
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(focusedRef, to: AXUIElement.self)
        var valueRef: CFTypeRef?
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String,
              AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(rangeRef, to: AXValue.self), .cfRange, &range) else { return nil }
        let whole = value as NSString
        guard range.location != kCFNotFound, range.location >= 0, range.location + range.length <= whole.length else { return nil }
        let beforeLength = min(2, range.location)
        let before = whole.substring(with: NSRange(location: range.location - beforeLength, length: beforeLength))
        let afterStart = range.location + range.length
        let after = whole.substring(with: NSRange(location: afterStart, length: min(2, whole.length - afterStart)))
        return (before, after)
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
