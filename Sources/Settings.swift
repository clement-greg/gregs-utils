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

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    static let shared = SettingsWindowController()

    /// Applies a new hotkey for a Settings.shortcuts key. Returns an error message if it can't be used.
    var applyShortcut: ((_ key: String, _ spec: String) -> String?)?

    private var window: NSWindow?
    private var recorders: [String: ShortcutRecorder] = [:]
    private let singleClick = NSButton(checkboxWithTitle: "Paste with a single click (otherwise double-click)",
                                       target: nil, action: nil)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let launchAtLogin = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let maxItemsField = NSTextField()
    private let maxItemsStepper = NSStepper()
    private var confirmingMaxItems = false
    /// The clipboard history, so a new item limit applies right away.
    weak var store: ClipboardStore?

    func show() {
        if window == nil { build() }
        for (key, r) in recorders { r.spec = Settings.spec(for: key) }
        singleClick.state = Settings.singleClickPastes ? .on : .off
        // Read from the system each time: it can also be changed in System Settings → Login Items.
        launchAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
        showMaxItems(Settings.maxItems)
        errorLabel.stringValue = ""
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 280),
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
            recorder.onRecord = { [weak self] spec in self?.apply(key: s.key, spec: spec) }
            recorder.onError = { [weak self] message in self?.errorLabel.stringValue = message ?? "" }
            recorders[s.key] = recorder
            grid.addRow(with: [label, recorder])
        }
        grid.column(at: 0).xPlacement = .trailing

        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 11)

        let hint = NSTextField(wrappingLabelWithString: "Click a shortcut, then press the new key combination. Esc cancels.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        singleClick.target = self
        singleClick.action = #selector(singleClickChanged)
        launchAtLogin.target = self
        launchAtLogin.action = #selector(launchAtLoginChanged)

        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = NSNumber(value: Settings.maxItemsRange.lowerBound)
        formatter.maximum = NSNumber(value: Settings.maxItemsRange.upperBound)
        maxItemsField.formatter = formatter
        maxItemsField.alignment = .right
        maxItemsField.delegate = self
        maxItemsField.target = self
        maxItemsField.action = #selector(maxItemsFieldChanged)
        maxItemsField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        maxItemsStepper.minValue = Double(Settings.maxItemsRange.lowerBound)
        maxItemsStepper.maxValue = Double(Settings.maxItemsRange.upperBound)
        maxItemsStepper.increment = 50
        maxItemsStepper.valueWraps = false
        maxItemsStepper.target = self
        maxItemsStepper.action = #selector(maxItemsStepperChanged)
        let pinnedNote = NSTextField(labelWithString: "items (pinned items don't count)")
        pinnedNote.textColor = .secondaryLabelColor
        let maxItemsRow = NSStackView(views: [NSTextField(labelWithString: "Keep up to"),
                                              maxItemsField, maxItemsStepper, pinnedNote])
        maxItemsRow.spacing = 6

        let reset = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))

        let stack = NSStackView(views: [
            header("General"), launchAtLogin,
            header("Shortcuts"), grid, hint, errorLabel,
            header("Clipboard History"), singleClick, maxItemsRow,
            reset,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(22, after: launchAtLogin)
        stack.setCustomSpacing(18, after: errorLabel)
        stack.setCustomSpacing(22, after: maxItemsRow)
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
            errorLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 412),
        ])
        w.contentView = content
        window = w
    }

    private func apply(key: String, spec: String) -> String? {
        if let error = applyShortcut?(key, spec) { return error }
        UserDefaults.standard.set(spec, forKey: key)
        return nil
    }

    // MARK: History limit

    private func showMaxItems(_ n: Int) {
        maxItemsField.integerValue = n
        maxItemsStepper.integerValue = n
    }

    @objc private func maxItemsFieldChanged() { commitMaxItems(maxItemsField.integerValue) }
    @objc private func maxItemsStepperChanged() { commitMaxItems(maxItemsStepper.integerValue) }

    func controlTextDidEndEditing(_ obj: Notification) {
        if (obj.object as? NSTextField) === maxItemsField { commitMaxItems(maxItemsField.integerValue) }
    }

    /// Applies a new limit. If it would delete items, asks first (and puts the old value back on Cancel).
    private func commitMaxItems(_ value: Int) {
        guard !confirmingMaxItems else { return } // Return fires both the action and end-editing
        let n = min(max(value, Settings.maxItemsRange.lowerBound), Settings.maxItemsRange.upperBound)
        let current = Settings.maxItems
        guard n != current else { showMaxItems(n); return }
        let apply = { [weak self] in
            UserDefaults.standard.set(n, forKey: Settings.maxItemsKey)
            self?.store?.setMaxItems(n)
            self?.showMaxItems(n)
        }
        let removed = store?.overflow(ifLimitWere: n) ?? 0
        guard removed > 0, let window else { apply(); return }

        let alert = NSAlert()
        alert.messageText = "Delete \(removed) clipboard item\(removed == 1 ? "" : "s")?"
        alert.informativeText = "History has more than \(n) unpinned items. The \(removed) oldest will be deleted. "
            + "This can't be undone. Pinned items are kept."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        showMaxItems(n)
        confirmingMaxItems = true
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.confirmingMaxItems = false
            if response == .alertFirstButtonReturn { apply() } else { self?.showMaxItems(current) }
        }
    }

    @objc private func launchAtLoginChanged() {
        do {
            if launchAtLogin.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            if let window { NSAlert(error: error).beginSheetModal(for: window) }
        }
        launchAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func singleClickChanged() {
        UserDefaults.standard.set(singleClick.state == .on, forKey: Settings.singleClickPastesKey)
    }

    @objc private func restoreDefaults() {
        recorders.values.forEach { $0.stop() }
        // With hotkeys suspended, swapped shortcuts (A↔B) can both move back without
        // tripping over each other; they're all registered together on resume().
        HotKeys.shared.suspend()
        Settings.shortcuts.forEach { UserDefaults.standard.removeObject(forKey: $0.key) }
        let problems = Settings.shortcuts.compactMap { applyShortcut?($0.key, $0.defaultSpec) }
        HotKeys.shared.resume()
        UserDefaults.standard.removeObject(forKey: Settings.singleClickPastesKey)
        show()
        errorLabel.stringValue = problems.joined(separator: "\n")
        commitMaxItems(Settings.defaultMaxItems) // asks first if this would delete items
    }

    func windowWillClose(_ notification: Notification) {
        recorders.values.forEach { $0.stop() }
    }

    func windowDidResignKey(_ notification: Notification) {
        recorders.values.forEach { $0.stop() }
    }
}
