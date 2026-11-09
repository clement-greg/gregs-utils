import AppKit
import Carbon.HIToolbox

/// System-wide hotkeys using Carbon's RegisterEventHotKey (no Accessibility permission needed).
///
/// Each hotkey lives in a named slot ("captureHotkey", …) and can be changed while the app runs.
/// One event handler serves every hotkey and dispatches on the hotkey's ID, so several can be
/// registered at once without each handler firing for the others' keys.
@MainActor
final class HotKeys {
    static let shared = HotKeys()

    private struct Slot {
        let id: UInt32
        var spec: String
        let action: () -> Void
        var ref: EventHotKeyRef?
    }

    private var slots: [String: Slot] = [:]
    private var handlerRef: EventHandlerRef?
    private var nextID: UInt32 = 1
    private var suspended = false
    private static let signature = OSType(0x4755_544C) // 'GUTL'

    private init() {}

    /// Puts `spec` (e.g. "cmd+shift+v") in the named slot, replacing what was there.
    /// Returns false if it can't be parsed or another app owns it; the slot then keeps its old key.
    @discardableResult
    func set(_ name: String, spec: String, action: @escaping () -> Void) -> Bool {
        guard installHandler() else { return false }
        let old = slots[name]
        if let ref = old?.ref { UnregisterEventHotKey(ref) }
        let id = old?.id ?? { defer { nextID += 1 }; return nextID }()
        if !suspended, let ref = register(spec, id: id) {
            slots[name] = Slot(id: id, spec: spec, action: action, ref: ref)
            return true
        }
        if suspended, Self.parse(spec) != nil {
            slots[name] = Slot(id: id, spec: spec, action: action, ref: nil) // registered on resume()
            return true
        }
        // Failed: put the previous key back.
        if var old {
            old.ref = suspended ? nil : register(old.spec, id: id)
            slots[name] = old
        }
        return false
    }

    /// Whether `spec` could be registered right now (it parses and no other app owns it).
    /// Our own slot named `except` doesn't count as a conflict.
    func isAvailable(_ spec: String, except name: String) -> Bool {
        guard let parsed = Self.parse(spec) else { return false }
        if slots.contains(where: { $0.key != name && Self.parse($0.value.spec).map { $0 == parsed } == true }) {
            return false
        }
        if slots[name].flatMap({ Self.parse($0.spec) }).map({ $0 == parsed }) == true { return true }
        guard let ref = register(spec, id: 0) else { return false }
        UnregisterEventHotKey(ref)
        return true
    }

    /// Turns every hotkey off, e.g. while the user records a new one (so pressing an existing
    /// shortcut is recorded instead of triggering it).
    func suspend() {
        guard !suspended else { return }
        suspended = true
        for (name, slot) in slots {
            if let ref = slot.ref { UnregisterEventHotKey(ref) }
            slots[name]?.ref = nil
        }
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        for (name, slot) in slots {
            slots[name]?.ref = register(slot.spec, id: slot.id)
        }
    }

    private func register(_ spec: String, id: UInt32) -> EventHotKeyRef? {
        guard let parsed = Self.parse(spec) else { return nil }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(parsed.keyCode, parsed.modifiers,
                                         EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        return status == noErr ? ref : nil
    }

    private func installHandler() -> Bool {
        if handlerRef != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard err == noErr, hotKeyID.signature == HotKeys.signature else { return OSStatus(eventNotHandledErr) }
            let id = hotKeyID.id
            // Run after the Carbon callback returns, so actions can show windows, menus, alerts…
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    HotKeys.shared.slots.values.first { $0.id == id }?.action()
                }
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)
        return status == noErr
    }

    // MARK: Parsing

    /// Parses strings like "cmd+shift+v" or "ctrl+opt+space".
    static func parse(_ spec: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        var mods: UInt32 = 0
        var key: UInt32?
        for part in spec.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command": mods |= UInt32(cmdKey)
            case "shift": mods |= UInt32(shiftKey)
            case "opt", "option", "alt": mods |= UInt32(optionKey)
            case "ctrl", "control": mods |= UInt32(controlKey)
            default:
                guard let code = keyCodes[part] else { return nil }
                key = code
            }
        }
        guard let key, mods != 0 else { return nil }
        return (key, mods)
    }

    /// Builds a spec from a recorded key press, or nil if the key can't be a hotkey.
    /// A hotkey needs ⌘, ⌃ or ⌥ (Shift alone would swallow ordinary typing).
    static func spec(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> String? {
        guard let name = keyCodes.first(where: { $0.value == UInt32(keyCode) })?.key else { return nil }
        let f = flags.intersection(.deviceIndependentFlagsMask)
        guard !f.isDisjoint(with: [.command, .control, .option]) else { return nil }
        var parts: [String] = []
        if f.contains(.control) { parts.append("ctrl") }
        if f.contains(.option) { parts.append("opt") }
        if f.contains(.shift) { parts.append("shift") }
        if f.contains(.command) { parts.append("cmd") }
        return (parts + [name]).joined(separator: "+")
    }

    /// "cmd+shift+v" → "⇧⌘V", in the standard ⌃⌥⇧⌘ order.
    static func describe(_ spec: String) -> String {
        let parts = Set(spec.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) })
        var out = ""
        if !parts.isDisjoint(with: ["ctrl", "control"]) { out += "⌃" }
        if !parts.isDisjoint(with: ["opt", "option", "alt"]) { out += "⌥" }
        if parts.contains("shift") { out += "⇧" }
        if !parts.isDisjoint(with: ["cmd", "command"]) { out += "⌘" }
        let mods: Set<String> = ["ctrl", "control", "opt", "option", "alt", "shift", "cmd", "command"]
        let key = parts.subtracting(mods).first ?? ""
        return out + (key == "space" ? "Space" : key.uppercased())
    }

    private static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50, "space": 49,
    ]
}
