
import Cocoa

// MARK: - Editor coordinator
// The editor's windows are created the first time the editor is opened, not at launch.
// While any editor window is on screen (or minimized) the app shows a Dock icon and menu bar;
// once they're all closed it goes back to being a menu-bar-only app.

final class EditorApp: NSObject, NSMenuItemValidation {
    static let shared = EditorApp()

    private var loaded = false

    /// The window that menu commands act on: the frontmost one.
    private var main: MainWindowController? {
        MainWindowController.all.first { $0.window.isMainWindow } ?? MainWindowController.all.first
    }

    /// Call once at launch.
    func installMenu() {
        NSWindow.allowsAutomaticWindowTabbing = false
        buildMenu()
    }

    /// Restores the saved windows and tabs (without showing them) the first time the editor is needed.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let saved = Store.shared.load()
        if saved.isEmpty {
            MainWindowController().newTab()
        }
        // Back to front, so the window that was in front ends up in front again.
        for w in saved.reversed() {
            MainWindowController(frame: w.frame).restore(w)
        }
        MainWindowController.saveSession()
    }

    var hasVisibleWindows: Bool {
        MainWindowController.all.contains { $0.window.isVisible || $0.window.isMiniaturized }
    }

    /// Brings the editor forward, restoring its windows if they're closed.
    func show() {
        loadIfNeeded()
        let wasVisible = hasVisibleWindows
        NSApp.setActivationPolicy(.regular)
        if wasVisible {
            main?.window.makeKeyAndOrderFront(nil)
        } else {
            MainWindowController.all.forEach { $0.window.makeKeyAndOrderFront(nil) }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Opens the editor with a new tab, optionally filled with `text`.
    func newNote(text: String = "") {
        show()
        main?.newTab(text: text)
    }

    /// Saves everything and takes every editor window off screen. Tabs come back on the next show().
    func hideAllWindows() {
        guard loaded else { return }
        if MainWindowController.all.contains(where: { $0.window.attachedSheet != nil }) { NSSound.beep(); return }
        MainWindowController.saveAll()
        MainWindowController.all.forEach { $0.window.orderOut(nil) }
        updateActivationPolicy()
    }

    /// Dock icon and menu bar only while there's an editor window to switch to.
    func updateActivationPolicy() {
        let wanted: NSApplication.ActivationPolicy = hasVisibleWindows ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
        if wanted == .accessory {
            // Hand focus back to another app, as a menu-bar app would.
            NSApp.deactivate()
        }
    }

    func saveAll() {
        if loaded { MainWindowController.saveAll() }
    }

    // MARK: Menu actions

    @objc func newTab(_ sender: Any?) { main?.newTab() }
    @objc func closeEditor(_ sender: Any?) { hideAllWindows() }
    @objc func openSettings(_ sender: Any?) { MainActor.assumeIsolated { SettingsWindowController.shared.show() } }
    @objc func closeTab(_ sender: Any?) { main?.closeCurrent() }
    @objc func saveCopy(_ sender: Any?) { if let main, let d = main.current { main.saveCopy(of: d) } }
    @objc func nextTab(_ sender: Any?) { main?.selectRelative(1) }
    @objc func previousTab(_ sender: Any?) { main?.selectRelative(-1) }
    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        guard let main else { return }
        // ⌘9 always means the last tab, like in browsers.
        main.select(index: sender.tag == 9 ? main.docs.count - 1 : sender.tag - 1)
    }

    @objc func zoomIn(_ sender: Any?) { main?.zoom(1) }
    @objc func zoomOut(_ sender: Any?) { main?.zoom(-1) }
    @objc func actualSize(_ sender: Any?) { main?.zoom(0) }

    @objc func beautifyJSON(_ sender: Any?) { main?.beautifyCurrent() }
    @objc func validateJSON(_ sender: Any?) { main?.validateCurrent() }
    @objc func collapseJSON(_ sender: Any?) { main?.current?.collapseAtCursor() }
    @objc func expandJSON(_ sender: Any?) { main?.current?.expandAtCursor() }
    @objc func collapseAllJSON(_ sender: Any?) { main?.current?.collapseAll() }
    @objc func expandAllJSON(_ sender: Any?) { main?.current?.expandAll() }

    private let jsonActions: Set<Selector> = [
        #selector(beautifyJSON(_:)), #selector(validateJSON(_:)), #selector(collapseJSON(_:)),
        #selector(expandJSON(_:)), #selector(collapseAllJSON(_:)), #selector(expandAllJSON(_:)),
    ]

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // Don't switch or close tabs while a sheet (e.g. the close dialog) is showing.
        if main?.window.attachedSheet != nil, menuItem.target === self { return false }
        if let action = menuItem.action, jsonActions.contains(action) { return main?.current?.isJSON == true }
        return true
    }

    // MARK: Menu

    private func buildMenu() {
        let mainMenu = NSMenu()

        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command,
                  target: AnyObject? = nil, tag: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            i.tag = tag
            return i
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            i.submenu = m
            return i
        }

        mainMenu.addItem(submenu(AppInfo.name, [
            item("About \(AppInfo.name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Hide \(AppInfo.name)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Settings…", #selector(openSettings(_:)), ",", target: self),
            .separator(),
            // ⌘Q only closes the editor: the menu bar tools (hotkeys, clipboard recording) keep running.
            item("Close Editor", #selector(closeEditor(_:)), "q", target: self),
            item("Quit \(AppInfo.name)", #selector(NSApplication.terminate(_:)), "q", [.command, .option]),
        ]))

        mainMenu.addItem(submenu("File", [
            item("New Tab", #selector(newTab(_:)), "t", target: self),
            item("Save a Copy…", #selector(saveCopy(_:)), "s", target: self),
            .separator(),
            item("Close Tab", #selector(closeTab(_:)), "w", target: self),
        ]))

        let spelling = submenu("Spelling and Grammar", [
            item("Show Spelling and Grammar", #selector(NSText.showGuessPanel(_:)), ":"),
            item("Check Document Now", #selector(NSText.checkSpelling(_:)), ";"),
            .separator(),
            item("Check Spelling While Typing", #selector(NSTextView.toggleContinuousSpellChecking(_:))),
        ])
        mainMenu.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSTextView.pasteAsPlainText(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            submenu("Find", [
                findItem("Find…", .showFindInterface, "f"),
                findItem("Find Next", .nextMatch, "g"),
                findItem("Find Previous", .previousMatch, "g", [.command, .shift]),
                findItem("Use Selection for Find", .setSearchString, "e"),
            ]),
            spelling,
        ]))

        // ⌘= is the same key as ⌘+ without Shift; it stays out of sight like the other duplicates.
        let zoomInAlt = item("Zoom In", #selector(zoomIn(_:)), "=", target: self)
        zoomInAlt.isHidden = true; zoomInAlt.allowsKeyEquivalentWhenHidden = true
        mainMenu.addItem(submenu("View", [
            item("Actual Size", #selector(actualSize(_:)), "0", target: self),
            item("Zoom In", #selector(zoomIn(_:)), "+", target: self),
            zoomInAlt,
            item("Zoom Out", #selector(zoomOut(_:)), "-", target: self),
        ]))

        let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!), right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        mainMenu.addItem(submenu("JSON", [
            item("Beautify", #selector(beautifyJSON(_:)), "f", [.command, .option, .shift], target: self),
            item("Validate", #selector(validateJSON(_:)), "j", [.command, .option, .shift], target: self),
            .separator(),
            item("Collapse", #selector(collapseJSON(_:)), left, [.command, .option], target: self),
            item("Expand", #selector(expandJSON(_:)), right, [.command, .option], target: self),
            item("Collapse All", #selector(collapseAllJSON(_:)), left, [.command, .option, .shift], target: self),
            item("Expand All", #selector(expandAllJSON(_:)), right, [.command, .option, .shift], target: self),
        ]))

        var windowItems: [NSMenuItem] = [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Show Next Tab", #selector(nextTab(_:)), "\t", .control, target: self),
            item("Show Previous Tab", #selector(previousTab(_:)), "\t", [.control, .shift], target: self),
            item("Show Next Tab", #selector(nextTab(_:)), "]", [.command, .shift], target: self),
            item("Show Previous Tab", #selector(previousTab(_:)), "[", [.command, .shift], target: self),
            .separator(),
        ]
        for n in 1...9 {
            let i = item(n == 9 ? "Last Tab" : "Tab \(n)", #selector(selectTabByNumber(_:)), "\(n)", target: self, tag: n)
            windowItems.append(i)
        }
        windowItems.append(.separator())
        windowItems.append(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        // The ⌘⇧[ / ⌘⇧] duplicates work as shortcuts but stay out of sight.
        windowItems[5].isHidden = true; windowItems[5].allowsKeyEquivalentWhenHidden = true
        windowItems[6].isHidden = true; windowItems[6].allowsKeyEquivalentWhenHidden = true
        let windowMenu = submenu("Window", windowItems)
        mainMenu.addItem(windowMenu)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu.submenu
    }

    private func findItem(_ title: String, _ action: NSTextFinder.Action, _ key: String,
                          _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.tag = action.rawValue
        return i
    }
}
