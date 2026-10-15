import AppKit
import ApplicationServices

/// Watches the configured hotkey system-wide and reports press/release so holding it records.
/// Needs Accessibility permission (for events in other apps); without it only Local Flow's own windows see keys.
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)?  // Esc while holding

    private var globalMonitors: [Any] = []
    private var localMonitors: [Any] = []
    private(set) var isDown = false
    private var hotkey: Hotkey

    init(hotkey: Hotkey) {
        self.hotkey = hotkey
    }

    func update(hotkey: Hotkey) {
        self.hotkey = hotkey
        if isDown { isDown = false; onCancel?() }
    }

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]
        globalMonitors.append(NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        } as Any)
        localMonitors.append(NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        } as Any)
    }

    func stop() {
        (globalMonitors + localMonitors).forEach { NSEvent.removeMonitor($0) }
        globalMonitors = []
        localMonitors = []
    }

    /// Returns true when the event belonged to the hotkey and should not reach the app.
    @discardableResult
    private func handle(_ event: NSEvent) -> Bool {
        if isDown, event.type == .keyDown, event.keyCode == 53 {  // Esc cancels
            isDown = false
            onCancel?()
            return true
        }
        if hotkey.isModifierOnly {
            guard event.type == .flagsChanged, event.keyCode == hotkey.keyCode else { return false }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let wanted = NSEvent.ModifierFlags(rawValue: hotkey.modifiers)
            let pressed = flags.contains(wanted)
            if pressed, !isDown { isDown = true; onPress?() }
            else if !pressed, isDown { isDown = false; onRelease?() }
            return true
        }
        guard event.keyCode == hotkey.keyCode else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad])
        let wanted = NSEvent.ModifierFlags(rawValue: hotkey.modifiers)
        switch event.type {
        case .keyDown where !event.isARepeat && flags == wanted:
            if !isDown { isDown = true; onPress?() }
            return true
        case .keyDown where event.isARepeat && isDown:
            return true
        case .keyUp where isDown:
            isDown = false
            onRelease?()
            return true
        default:
            return false
        }
    }
}
