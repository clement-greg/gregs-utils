import Cocoa
import ServiceManagement
import UniformTypeIdentifiers

enum AppInfo {
    static let name = "Greg's Utils"
}

/// One menu-bar icon for all three tools: Capture (screenshots), Clipboard History, and the Editor.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let defaults = UserDefaults.standard
    private var statusItem: NSStatusItem!

    private var store: ClipboardStore!
    private var history: HistoryWindowController!

    private var captureSession: CaptureSession?
    private var capturing = false

    private var failedHotKeys: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()

        store = ClipboardStore(maxItems: max(10, defaults.integer(forKey: "maxItems")))
        store.start()
        history = HistoryWindowController(store: store)
        history.onOpenInEditor = { text in EditorApp.shared.newNote(text: text) }

        EditorApp.shared.installMenu()
        setUpStatusItem()
        registerHotKeys()
        SettingsWindowController.shared.applyShortcut = { [weak self] key, spec in
            self?.applyShortcut(key: key, spec: spec)
        }
        enableLaunchAtLoginOnFirstRun()

        // Ask up front so the first capture and the first paste "just work".
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        Paster.isTrusted(prompt: true)

        if !failedHotKeys.isEmpty {
            alert("Shortcut unavailable",
                  "\(failedHotKeys.joined(separator: ", ")) is already used by another app "
                  + "Choose another in \(AppInfo.name) → Settings….")
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        EditorApp.shared.saveAll()
        return .terminateNow
    }

    func applicationWillResignActive(_ notification: Notification) { EditorApp.shared.saveAll() }

    /// Opening the app again (Finder, Spotlight, Dock) shows the editor.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        EditorApp.shared.show()
        return true
    }

    // MARK: Hotkeys

    private func action(for key: String) -> () -> Void {
        switch key {
        case "captureHotkey": return { [weak self] in self?.startCapture() }
        case "clipboardHotkey": return { [weak self] in self?.history.toggle() }
        default: return { EditorApp.shared.newNote() }
        }
    }

    private func registerHotKeys() {
        for s in Settings.shortcuts {
            let spec = Settings.spec(for: s.key)
            if !HotKeys.shared.set(s.key, spec: spec, action: action(for: s.key)) {
                failedHotKeys.append(HotKeys.describe(spec))
            }
        }
    }

    /// Switches a hotkey while running (from Settings). Returns an error message if it can't be used.
    private func applyShortcut(key: String, spec: String) -> String? {
        if let other = Settings.shortcuts.first(where: { $0.key != key && Settings.spec(for: $0.key) == spec }) {
            return "\(HotKeys.describe(spec)) is already the \(other.title.lowercased()) shortcut."
        }
        guard HotKeys.shared.set(key, spec: spec, action: action(for: key)) else {
            return "\(HotKeys.describe(spec)) is already used by another app or by macOS."
        }
        return nil
    }

    private func shortcutLabel(_ key: String) -> String { HotKeys.describe(Settings.spec(for: key)) }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: AppInfo.name)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector, state: Bool? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            if let state { item.state = state ? .on : .off }
            menu.addItem(item)
        }

        add("Capture Area  (\(shortcutLabel("captureHotkey")))", #selector(captureFromMenu))
        add("Clipboard History  (\(shortcutLabel("clipboardHotkey")))", #selector(showHistory))
        add("New Note  (\(shortcutLabel("noteHotkey")))", #selector(newNote))
        add("Open Editor", #selector(openEditor))
        menu.addItem(.separator())

        add("Pause Clipboard Recording", #selector(togglePause), state: store.isPaused)
        let unpinned = store.items.count - store.pinnedCount
        add("Clear Clipboard History (\(unpinned) items)…", #selector(clearHistory))
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        add("Launch at Login", #selector(toggleLaunchAtLogin), state: SMAppService.mainApp.status == .enabled)
        if !CGPreflightScreenCaptureAccess() {
            add("Grant Screen Recording Access (needed to capture)…", #selector(openScreenRecordingSettings))
        }
        if !Paster.isTrusted(prompt: false) {
            add("Grant Accessibility Access (needed to paste)…", #selector(openAccessibilitySettings))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit \(AppInfo.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // Each runs after the menu has finished closing, so focus is back in the previous app.
    @objc private func captureFromMenu() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.startCapture() } // let the menu fade before freezing the screen
    }
    @objc private func showHistory() { DispatchQueue.main.async { self.history.show() } }
    @objc private func newNote() { EditorApp.shared.newNote() }
    @objc private func openEditor() { EditorApp.shared.show() }
    @objc private func showSettings() { SettingsWindowController.shared.show() }

    @objc private func togglePause() {
        store.isPaused.toggle()
        statusItem.button?.appearsDisabled = store.isPaused
    }

    @objc private func clearHistory() {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = "Clear clipboard history?"
        let unpinned = store.items.count - store.pinnedCount
        let pins = store.pinnedCount
        a.informativeText = "This removes all \(unpinned) unpinned items. It can't be undone."
            + (pins > 0 ? " Your \(pins) pinned item\(pins == 1 ? "" : "s") will be kept." : "")
        a.addButton(withTitle: "Clear")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { store.clear() }
    }

    // MARK: Launch at login

    private func enableLaunchAtLoginOnFirstRun() {
        let key = "didAutoEnableLaunchAtLogin"
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert("Couldn't change Launch at Login", error.localizedDescription)
        }
    }

    // MARK: Permissions

    @objc private func openScreenRecordingSettings() {
        CGRequestScreenCaptureAccess()
        openSettings("Privacy_ScreenCapture")
    }

    @objc private func openAccessibilitySettings() {
        Paster.isTrusted(prompt: true)
        openSettings("Privacy_Accessibility")
    }

    private func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Capture

    private func startCapture() {
        guard !capturing else { return }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            alert("Screen Recording permission needed",
                  "Enable \(AppInfo.name) in System Settings → Privacy & Security → "
                  + "Screen & System Audio Recording, then try again.")
            return
        }
        capturing = true
        let front = NSWorkspace.shared.frontmostApplication
        let previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        Task { @MainActor in
            do {
                let captures = try await captureAllScreens()
                let session = CaptureSession { [weak self = self] result, save in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.captureSession = nil
                        self.capturing = false
                        if let result {
                            self.store.addImage(result.image, pointScale: result.pointScale,
                                                source: previousApp?.localizedName)
                        }
                        if save, let result {
                            self.saveToFile(result.image, pointScale: result.pointScale)
                        }
                        previousApp?.activate()
                    }
                }
                self.captureSession = session
                session.show(captures)
            } catch {
                self.capturing = false
                self.alert("Capture failed", error.localizedDescription)
            }
        }
    }

    /// Asks where to save a capture and writes it as a PNG (at its on-screen size, so Retina
    /// captures open at the right size). The folder is remembered for next time.
    private func saveToFile(_ image: CGImage, pointScale: CGFloat) {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: CGFloat(image.width) / pointScale, height: CGFloat(image.height) / pointScale)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        panel.nameFieldStringValue = "Screenshot \(stamp.string(from: Date())).png"
        if let dir = defaults.string(forKey: "captureSaveDirectory") {
            panel.directoryURL = URL(fileURLWithPath: dir, isDirectory: true)
        } else {
            panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try png.write(to: url, options: .atomic)
            defaults.set(url.deletingLastPathComponent().path, forKey: "captureSaveDirectory")
        } catch {
            alert("Couldn't save the screenshot", error.localizedDescription)
        }
    }

    private func alert(_ title: String, _ message: String) {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.runModal()
    }
}
