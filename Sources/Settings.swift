import AppKit
import ServiceManagement

/// The settings that live in UserDefaults, with their defaults.
enum Settings {
    struct Shortcut {
        let key: String          // UserDefaults key, also the HotKeys slot name
        let title: String
        let defaultSpec: String
    }

    static let shortcuts: [Shortcut] = [
        Shortcut(key: "captureHotkey", title: "Capture area", defaultSpec: "cmd+shift+x"),
        Shortcut(key: "clipboardHotkey", title: "Clipboard history", defaultSpec: "cmd+shift+v"),
        Shortcut(key: "noteHotkey", title: "New note", defaultSpec: "ctrl+opt+n"),
    ]

    static let singleClickPastesKey = "singleClickPastes"
    static let maxItemsKey = "maxItems"
    static let defaultMaxItems = 200
    static let maxItemsRange = 10...10_000

    /// The most unpinned items clipboard history keeps.
    static var maxItems: Int {
        min(max(UserDefaults.standard.integer(forKey: maxItemsKey), maxItemsRange.lowerBound), maxItemsRange.upperBound)
    }

    static func registerDefaults() {
        var d: [String: Any] = [maxItemsKey: defaultMaxItems, singleClickPastesKey: true]
        for s in shortcuts { d[s.key] = s.defaultSpec }
        UserDefaults.standard.register(defaults: d)
    }

    static func spec(for key: String) -> String {
        UserDefaults.standard.string(forKey: key) ?? shortcuts.first { $0.key == key }?.defaultSpec ?? ""
    }

    static var singleClickPastes: Bool { UserDefaults.standard.bool(forKey: singleClickPastesKey) }
}

// MARK: - Shortcut recorder

/// A button showing a shortcut. Click it, then press the new key combination (Esc cancels).
@MainActor
final class ShortcutRecorder: NSButton {
    /// Called with the new spec; returns an error message to reject it.
    var onRecord: ((String) -> String?)?
    var onError: ((String?) -> Void)?

    var spec: String = "" { didSet { updateTitle() } }
    private var monitor: Any?
    private var recording = false { didSet { updateTitle() } }

    init() {
        super.init(frame: .zero)
        bezelStyle = .push
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(clicked)
        font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateTitle() {
        title = recording ? "Type shortcut…" : HotKeys.describe(spec)
    }

    @objc private func clicked() {
        recording ? stop() : start()
    }

    private func start() {
        recording = true
        onError?(nil)
        // Turn our hotkeys off so pressing one records it instead of triggering it.
        HotKeys.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            self.handle(event)
            return nil
        }
    }

    func stop() {
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        HotKeys.shared.resume()
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53, flags.isDisjoint(with: [.command, .control, .option, .shift]) { // Esc
            stop()
            return
        }
        guard let newSpec = HotKeys.spec(keyCode: event.keyCode, flags: flags) else {
            NSSound.beep()
            onError?("Use ⌘, ⌃ or ⌥ with a letter, digit, punctuation key or Space.")
            return
        }
        stop()
        if let error = onRecord?(newSpec) {
            onError?(error)
        } else {
            spec = newSpec
            onError?(nil)
        }
    }
}

// MARK: - Settings window
// Edits go into a draft. Nothing changes until Save, which applies the whole draft and closes the
// window; Cancel (or closing and choosing Discard) throws it away.

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    static let shared = SettingsWindowController()

    /// Applies a new hotkey for a Settings.shortcuts key. Returns an error message if it can't be used.
    var applyShortcut: ((_ key: String, _ spec: String) -> String?)?
    /// The clipboard history, so a new item limit applies right away.
    weak var store: ClipboardStore?

    private struct Draft: Equatable {
        var shortcuts: [String: String]
        var launchAtLogin: Bool
        var singleClickPastes: Bool
        var maxItems: Int

        static func saved() -> Draft {
            Draft(shortcuts: Dictionary(uniqueKeysWithValues: Settings.shortcuts.map { ($0.key, Settings.spec(for: $0.key)) }),
                  launchAtLogin: SMAppService.mainApp.status == .enabled,
                  singleClickPastes: Settings.singleClickPastes,
                  maxItems: Settings.maxItems)
        }
    }

    private var saved = Draft.saved()
    private var draft = Draft.saved()

    private var window: NSWindow?
    private var recorders: [String: ShortcutRecorder] = [:]
    private let launchAtLogin = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let singleClick = NSButton(checkboxWithTitle: "Paste with a single click (otherwise double-click)",
                                       target: nil, action: nil)
    private let maxItemsField = NSTextField()
    private let maxItemsStepper = NSStepper()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    /// A one-off problem from the last recording attempt (bad key, taken by another app).
    private var recorderError: String?

    func show() {
        if window == nil { build() }
        if window?.isVisible != true {
            // Fresh draft each time the window opens. (Launch at Login can also change in System Settings.)
            saved = Draft.saved()
            draft = saved
            recorderError = nil
            load()
            window?.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Building

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "\(AppInfo.name) Settings"
        w.isReleasedWhenClosed = false
        w.delegate = self

        func header(_ text: String) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.font = .boldSystemFont(ofSize: 13)
            return l
        }

        let grid = NSGridView()
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        for s in Settings.shortcuts {
            let label = NSTextField(labelWithString: s.title + ":")
            label.alignment = .right
            let recorder = ShortcutRecorder()
            recorder.onRecord = { [weak self] spec in self?.recorded(spec, for: s.key) }
            recorder.onError = { [weak self] message in
                self?.recorderError = message
                self?.refresh()
            }
            recorders[s.key] = recorder
            grid.addRow(with: [label, recorder])
        }
        grid.column(at: 0).xPlacement = .trailing

        let hint = NSTextField(wrappingLabelWithString: "Click a shortcut, then press the new key combination. Esc cancels.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        messageLabel.textColor = .systemRed
        messageLabel.font = .systemFont(ofSize: 11)

        launchAtLogin.target = self
        launchAtLogin.action = #selector(controlChanged)
        singleClick.target = self
        singleClick.action = #selector(controlChanged)

        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = 0
        maxItemsField.formatter = formatter
        maxItemsField.alignment = .right
        maxItemsField.delegate = self
        maxItemsField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        maxItemsStepper.minValue = Double(Settings.maxItemsRange.lowerBound)
        maxItemsStepper.maxValue = Double(Settings.maxItemsRange.upperBound)
        maxItemsStepper.increment = 50
        maxItemsStepper.valueWraps = false
        maxItemsStepper.target = self
        maxItemsStepper.action = #selector(stepperChanged)
        let pinnedNote = NSTextField(labelWithString: "items (pinned items don't count)")
        pinnedNote.textColor = .secondaryLabelColor
        let maxItemsRow = NSStackView(views: [NSTextField(labelWithString: "Keep up to"),
                                              maxItemsField, maxItemsStepper, pinnedNote])
        maxItemsRow.spacing = 6

        let restore = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}" // Esc
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        saveButton.keyEquivalent = "\r" // Return: the default button
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [restore, spacer, cancel, saveButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [
            header("General"), launchAtLogin,
            header("Shortcuts"), grid, hint,
            header("Clipboard History"), singleClick, maxItemsRow,
            messageLabel, buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(22, after: launchAtLogin)
        stack.setCustomSpacing(22, after: hint)
        stack.setCustomSpacing(16, after: maxItemsRow)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 460),
            hint.widthAnchor.constraint(lessThanOrEqualToConstant: 412),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 412),
            buttons.widthAnchor.constraint(equalToConstant: 412),
        ])
        w.contentView = content
        window = w
    }

    // MARK: Draft <-> controls

    /// Shows the draft in the controls.
    private func load() {
        for (key, r) in recorders { r.spec = draft.shortcuts[key] ?? "" }
        launchAtLogin.state = draft.launchAtLogin ? .on : .off
        singleClick.state = draft.singleClickPastes ? .on : .off
        maxItemsField.integerValue = draft.maxItems
        maxItemsStepper.integerValue = draft.maxItems
        refresh()
    }

    /// Two of our shortcuts on the same keys: allowed while editing (so two can be swapped), not on Save.
    private var clash: String? {
        let byKey = Settings.shortcuts.map { ($0, draft.shortcuts[$0.key] ?? "") }
        for (i, a) in byKey.enumerated() {
            if let b = byKey[(i + 1)...].first(where: { $0.1 == a.1 }) {
                return "\(a.0.title) and \(b.0.title.lowercased()) are both \(HotKeys.describe(a.1)). Change one to save."
            }
        }
        return nil
    }

    /// Updates the message and the Save button.
    private func refresh() {
        messageLabel.stringValue = recorderError ?? clash ?? ""
        saveButton.isEnabled = draft != saved && clash == nil
    }

    private func recorded(_ spec: String, for key: String) -> String? {
        if HotKeys.shared.isTakenByAnotherApp(spec) {
            return "\(HotKeys.describe(spec)) is already used by another app or by macOS."
        }
        draft.shortcuts[key] = spec
        recorderError = nil
        refresh()
        return nil
    }

    @objc private func controlChanged() {
        draft.launchAtLogin = launchAtLogin.state == .on
        draft.singleClickPastes = singleClick.state == .on
        refresh()
    }

    @objc private func stepperChanged() {
        maxItemsField.integerValue = maxItemsStepper.integerValue
        draft.maxItems = maxItemsStepper.integerValue
        refresh()
    }

    /// Typing in the number field updates the draft as you go (so Save lights up).
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === maxItemsField else { return }
        let typed = Int(maxItemsField.stringValue.filter(\.isNumber)) ?? draft.maxItems
        draft.maxItems = min(max(typed, Settings.maxItemsRange.lowerBound), Settings.maxItemsRange.upperBound)
        maxItemsStepper.integerValue = draft.maxItems
        refresh()
    }

    /// When typing ends, show the value that will actually be saved (clamped to 10–10,000).
    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === maxItemsField else { return }
        maxItemsField.integerValue = draft.maxItems
    }

    @objc private func restoreDefaults() {
        recorders.values.forEach { $0.stop() }
        for s in Settings.shortcuts { draft.shortcuts[s.key] = s.defaultSpec }
        draft.singleClickPastes = true
        draft.maxItems = Settings.defaultMaxItems
        // Launch at Login is left as it is.
        recorderError = nil
        load()
    }

    // MARK: Save / Cancel

    @objc private func cancelClicked() { cancel() }

    private func cancel() {
        recorders.values.forEach { $0.stop() }
        draft = saved
        window?.orderOut(nil)
    }

    @objc private func saveClicked() {
        save(then: { [weak self] in self?.window?.orderOut(nil) })
    }

    /// Applies the draft (asking first if a lower history limit would delete items), then runs `done`.
    private func save(then done: @escaping () -> Void) {
        recorders.values.forEach { $0.stop() }
        window?.makeFirstResponder(nil) // finish typing in the number field
        guard clash == nil, let window else { refresh(); return }
        let removed = draft.maxItems < saved.maxItems ? (store?.overflow(ifLimitWere: draft.maxItems) ?? 0) : 0
        guard removed > 0 else { apply(); done(); return }

        let alert = NSAlert()
        alert.messageText = "Delete \(removed) clipboard item\(removed == 1 ? "" : "s")?"
        alert.informativeText = "History has more than \(draft.maxItems) unpinned items. Saving deletes the \(removed) oldest. "
            + "This can't be undone. Pinned items are kept."
        alert.addButton(withTitle: "Delete and Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.apply()
            done()
        }
    }

    private func apply() {
        let d = draft
        let defaults = UserDefaults.standard

        if d.shortcuts != saved.shortcuts {
            // Store first, then register them all together, so swapped shortcuts don't block each other.
            for (key, spec) in d.shortcuts { defaults.set(spec, forKey: key) }
            HotKeys.shared.suspend()
            for s in Settings.shortcuts { _ = applyShortcut?(s.key, d.shortcuts[s.key] ?? s.defaultSpec) }
            HotKeys.shared.resume()
        }

        defaults.set(d.singleClickPastes, forKey: Settings.singleClickPastesKey)

        if d.maxItems != saved.maxItems {
            defaults.set(d.maxItems, forKey: Settings.maxItemsKey)
            store?.setMaxItems(d.maxItems)
        }

        if d.launchAtLogin != saved.launchAtLogin {
            do {
                if d.launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSApp.activate(ignoringOtherApps: true)
                NSAlert(error: error).runModal()
            }
        }

        saved = Draft.saved()
        draft = saved
        refresh()
    }

    // MARK: Window

    /// Closing with unsaved changes asks what to do with them.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        recorders.values.forEach { $0.stop() }
        window?.makeFirstResponder(nil)
        guard draft != saved else { return true }
        let alert = NSAlert()
        alert.messageText = "Save your changes to Settings?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Keep Editing")
        alert.beginSheetModal(for: sender) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: self?.save(then: { sender.orderOut(nil) })
            case .alertSecondButtonReturn: self?.cancel()
            default: break
            }
        }
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        recorders.values.forEach { $0.stop() }
    }
}
