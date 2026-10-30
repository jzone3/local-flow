import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Watches the configured hotkey system-wide and reports press/release so holding it records.
/// With Accessibility granted this is a CGEvent tap, which sees every key (Esc included) and can swallow the ones
/// it handles; without it, NSEvent monitors see modifier keys everywhere but other keys only in Local Flow's windows.
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)?  // Esc while holding
    var onChord: (() -> Void)?  // another key pressed while a lone-modifier hotkey is held (Fn+E, Fn+←…)

    private var globalMonitors: [Any] = []
    private var localMonitors: [Any] = []
    private var tap: KeyTap?
    private(set) var isDown = false
    /// Set while dictating hands-free so Esc still cancels although the key is up.
    var escapeArmed = false
    /// Set while the Settings recorder is capturing keys so holding the current hotkey doesn't start a dictation.
    var isPaused = false
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
        tap = KeyTap { [weak self] event in self?.handle(event) ?? false }
        if tap != nil { return }
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
        tap?.stop()
        tap = nil
    }

    /// Returns true when the event belonged to the hotkey and should not reach the app.
    @discardableResult
    private func handle(_ event: NSEvent) -> Bool {
        if isPaused { return false }
        if isDown || escapeArmed, event.type == .keyDown, event.keyCode == 53 {  // Esc cancels
            isDown = false
            escapeArmed = false
            onCancel?()
            return true
        }
        if hotkey.isModifierOnly {
            if isDown, event.type == .keyDown {  // a shortcut, not a dictation: drop it and let the key through
                isDown = false
                onChord?()
                return false
            }
            guard event.type == .flagsChanged, event.keyCode == hotkey.keyCode else { return false }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let wanted = NSEvent.ModifierFlags(rawValue: hotkey.modifiers)
            let pressed = flags.contains(wanted)
            if pressed, !isDown { isDown = true; onPress?() }
            else if !pressed, isDown { isDown = false; onRelease?() }
            return true
        }
        guard event.keyCode == hotkey.keyCode else { return false }
        let flags = Hotkey.comboModifiers(event.modifierFlags.rawValue)
        switch event.type {
        case .keyDown where !event.isARepeat && flags == hotkey.modifiers:
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

/// A session-level CGEvent tap. It needs Accessibility (`tapCreate` returns nil without it), sees every key before
/// the system's own shortcuts do, and swallows the keys the handler claims. Modifier changes (fn, right option…)
/// always go on to the system so its fn shortcuts keep working.
final class KeyTap {
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private let handler: (NSEvent) -> Bool

    init?(handler: @escaping (NSEvent) -> Bool) {
        self.handler = handler
        let events: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<KeyTap>.fromOpaque(userInfo).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let port = tap.port { CGEvent.tapEnable(tap: port, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard let nsEvent = NSEvent(cgEvent: event) else { return Unmanaged.passUnretained(event) }
            if tap.handler(nsEvent), type != .flagsChanged { return nil }
            return Unmanaged.passUnretained(event)
        }
        guard HotkeyMonitor.hasAccessibility,
              let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: events, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return nil }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        source = nil
        port = nil
    }
}

extension Hotkey {
    /// True when macOS itself already uses this key combo (⌘Space for Spotlight, ⌃Space for input sources…),
    /// read from the enabled symbolic hotkeys, so the recorder can warn that Local Flow will take it over.
    var isUsedBySystem: Bool {
        guard !isModifierOnly else { return false }
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr, let entries = list?.takeRetainedValue() as? [[String: Any]] else { return false }
        let carbon: [(UInt, Int)] = [(Hotkey.commandFlag, cmdKey), (Hotkey.shiftFlag, shiftKey), (Hotkey.optionFlag, optionKey), (Hotkey.controlFlag, controlKey)]
        let wanted = carbon.reduce(0) { $0 | (modifiers & $1.0 != 0 ? $1.1 : 0) }
        return entries.contains { entry in
            (entry[kHISymbolicHotKeyEnabled] as? Bool) == true
                && entry[kHISymbolicHotKeyCode] as? Int == Int(keyCode)
                && entry[kHISymbolicHotKeyModifiers] as? Int == wanted
        }
    }
}
