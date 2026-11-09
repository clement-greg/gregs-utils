import AppKit

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

    static func registerDefaults() {
        var d: [String: Any] = ["maxItems": 200, singleClickPastesKey: true]
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
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    /// Applies a new hotkey for a Settings.shortcuts key. Returns an error message if it can't be used.
    var applyShortcut: ((_ key: String, _ spec: String) -> String?)?

    private var window: NSWindow?
    private var recorders: [String: ShortcutRecorder] = [:]
    private let singleClick = NSButton(checkboxWithTitle: "Paste with a single click (otherwise double-click)",
                                       target: nil, action: nil)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")

    func show() {
        if window == nil { build() }
        for (key, r) in recorders { r.spec = Settings.spec(for: key) }
        singleClick.state = Settings.singleClickPastes ? .on : .off
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

        let reset = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))

        let stack = NSStackView(views: [
            header("Shortcuts"), grid, hint, errorLabel,
            header("Clipboard History"), singleClick,
            reset,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(18, after: errorLabel)
        stack.setCustomSpacing(22, after: singleClick)
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
    }

    func windowWillClose(_ notification: Notification) {
        recorders.values.forEach { $0.stop() }
    }

    func windowDidResignKey(_ notification: Notification) {
        recorders.values.forEach { $0.stop() }
    }
}
