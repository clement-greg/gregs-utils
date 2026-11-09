import AppKit
import ApplicationServices

enum Paster {
    /// Whether we're allowed to synthesize keystrokes. Optionally shows the system prompt.
    @discardableResult
    static func isTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    /// Sends ⌘V to the given app (which should already hold the item on the clipboard).
    @MainActor
    static func paste(into app: NSRunningApplication?) {
        guard isTrusted(prompt: true) else { return } // item stays on clipboard; user can ⌘V manually
        if let app, !app.isActive { app.activate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let source = CGEventSource(stateID: .hidSystemState)
            let vKey: CGKeyCode = 9
            let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }
}
