import AppKit
import ApplicationServices

/// Watches the configured hotkey system-wide and reports press/release so holding it records.
/// With Accessibility granted this is a CGEvent tap, which sees every key (Esc included) and can swallow the ones
/// it handles; without it, NSEvent monitors see modifier keys everywhere but other keys only in Local Flow's windows.
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)?  // Esc while holding

    private var globalMonitors: [Any] = []
    private var localMonitors: [Any] = []
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private(set) var isDown = false
    /// Set while dictating hands-free so Esc still cancels although the key is up.
    var escapeArmed = false
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

    var usesEventTap: Bool { tap != nil }

    func start() {
        stop()
        if installEventTap() { return }
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
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tapSource = nil
        tap = nil
    }

    /// An active session tap needs Accessibility; `tapCreate` returns nil without it.
    private func installEventTap() -> Bool {
        guard Self.hasAccessibility else { return false }
        let events: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard let nsEvent = NSEvent(cgEvent: event) else { return Unmanaged.passUnretained(event) }
            let handled = monitor.handle(nsEvent)
            // Modifier changes (fn, right option…) still reach the system so its own fn shortcuts keep working; a
            // handled key (Esc cancel, a key-combo hotkey) is swallowed so the front app doesn't type or act on it.
            if handled, type != .flagsChanged { return nil }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: events, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        tapSource = source
        return true
    }

    /// Returns true when the event belonged to the hotkey and should not reach the app.
    @discardableResult
    private func handle(_ event: NSEvent) -> Bool {
        if isDown || escapeArmed, event.type == .keyDown, event.keyCode == 53 {  // Esc cancels
            isDown = false
            escapeArmed = false
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
