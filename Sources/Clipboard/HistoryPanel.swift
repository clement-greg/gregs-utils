import AppKit

/// A borderless-looking floating panel that can take keyboard focus without activating our app,
/// so the app you were typing in stays frontmost (Spotlight-style).
final class KeyablePanel: NSPanel {
    var keyEquivalentHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyEquivalentHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Keeps selected rows drawn in the accent color even though the search field has focus.
private final class AlwaysEmphasizedRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}

private final class ClipCellView: NSTableCellView {
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    let shortcutLabel = NSTextField(labelWithString: "")
    let pinIcon = NSImageView()
    let thumbnail = NSImageView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.font = .systemFont(ofSize: 10.5)
        detailLabel.lineBreakMode = .byTruncatingTail
        shortcutLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        shortcutLabel.alignment = .right
        shortcutLabel.setContentHuggingPriority(.required, for: .horizontal)
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1

        pinIcon.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        pinIcon.setContentHuggingPriority(.required, for: .horizontal)
        pinIcon.setContentCompressionResistancePriority(.required, for: .horizontal)

        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 3
        thumbnail.layer?.masksToBounds = true
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            thumbnail.widthAnchor.constraint(equalToConstant: 44),
            thumbnail.heightAnchor.constraint(equalToConstant: 32),
        ])

        let row = NSStackView(views: [pinIcon, thumbnail, textStack, shortcutLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = titleLabel
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    private func applyColors() {
        let selected = backgroundStyle == .emphasized
        titleLabel.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
        detailLabel.textColor = selected ? .alternateSelectedControlTextColor.withAlphaComponent(0.75) : .secondaryLabelColor
        shortcutLabel.textColor = selected ? .alternateSelectedControlTextColor.withAlphaComponent(0.85) : .tertiaryLabelColor
        pinIcon.contentTintColor = selected ? .alternateSelectedControlTextColor : .controlAccentColor
    }

    func configure(item: ClipItem, row: Int, formatter: RelativeDateTimeFormatter, image: NSImage?) {
        thumbnail.image = image
        thumbnail.isHidden = !item.isImage
        let snippet = item.text.prefix(400)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        titleLabel.stringValue = snippet

        var detail: [String] = []
        if let app = item.sourceApp { detail.append(app) }
        detail.append(formatter.localizedString(for: item.date, relativeTo: Date()))
        if !item.isImage {
            let lines = item.text.split(whereSeparator: \.isNewline).count
            if lines > 1 { detail.append("\(lines) lines") }
            if item.text.count > 400 { detail.append("\(item.text.count) chars") }
        }
        detailLabel.stringValue = detail.joined(separator: " · ")

        shortcutLabel.stringValue = row < 9 ? "⌘\(row + 1)" : ""
        pinIcon.isHidden = !item.pinned
    }
}

@MainActor
final class HistoryWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate,
    NSSearchFieldDelegate, NSWindowDelegate, NSMenuDelegate, NSTextViewDelegate
{
    private let store: ClipboardStore
    private let panel: KeyablePanel
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let tableScroll = NSScrollView()
    private let previewScroll = NSTextView.scrollableTextView()
    private var previewText: NSTextView { previewScroll.documentView as! NSTextView }
    private let previewImage = NSImageView()
    private var imageCache: [UUID: NSImage] = [:]
    /// Called with an item's text when the user picks Open in Editor (⌘O).
    var onOpenInEditor: ((String) -> Void)?

    /// While editing, the preview pane is an editable text view holding the item's text.
    private var isEditing = false
    /// The item being edited, or nil when adding a new one.
    private var editingID: UUID?
    private lazy var previewHeight = previewScroll.heightAnchor.constraint(equalToConstant: Self.previewHeightBrowsing)
    private static let panelSize = NSSize(width: 620, height: 480)
    private static let previewHeightBrowsing: CGFloat = 110
    private static let previewHeightEditing: CGFloat = 220
    private static let browseFooter =
        "↩ paste  ⌘1–9 quick paste  ⌘C copy  ⌘N new  ⌘E edit  ⌘O open in editor  ⌘P pin  ⌘⌫ delete  esc close"
    private static let editFooter = "⌘↩ save   esc cancel   clicking away also saves"
    private let footer = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "")
    private let dateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private var filtered: [ClipItem] = []
    private var targetApp: NSRunningApplication?
    private static let cellID = NSUserInterfaceItemIdentifier("ClipCell")

    var isVisible: Bool { panel.isVisible }

    init(store: ClipboardStore) {
        self.store = store
        self.panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        super.init()
        configurePanel()
        buildUI()
        store.onChange = { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.refilter(keepSelection: true)
        }
    }

    // MARK: Setup

    private func configurePanel() {
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        hideWindowButtons()
        panel.keyEquivalentHandler = { [weak self] event in self?.handleKeyEquivalent(event) ?? false }
    }

    private func buildUI() {
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        panel.contentView = background

        searchField.placeholderString = "Search clipboard history…"
        searchField.font = .systemFont(ofSize: 16)
        searchField.controlSize = .large
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.focusRingType = .none

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 40
        tableView.style = .inset
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.refusesFirstResponder = true // keep typing focus in the search field
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.doubleAction = #selector(rowDoubleClicked)
        let rowMenu = NSMenu()
        rowMenu.delegate = self
        tableView.menu = rowMenu

        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.drawsBackground = false
        tableScroll.autohidesScrollers = true

        previewText.isEditable = false
        previewText.isSelectable = false
        previewText.drawsBackground = false
        previewText.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        previewText.textColor = .secondaryLabelColor
        previewText.textContainerInset = NSSize(width: 6, height: 6)
        // Edits must keep the text exactly as typed: plain text, no smart substitutions.
        previewText.isRichText = false
        previewText.allowsUndo = true
        previewText.isAutomaticQuoteSubstitutionEnabled = false
        previewText.isAutomaticDashSubstitutionEnabled = false
        previewText.isAutomaticTextReplacementEnabled = false
        previewText.isAutomaticSpellingCorrectionEnabled = false
        previewText.delegate = self
        previewScroll.drawsBackground = false
        previewScroll.hasVerticalScroller = true
        previewScroll.autohidesScrollers = true

        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .tertiaryLabelColor
        footer.alignment = .center
        footer.lineBreakMode = .byTruncatingTail
        // Truncate rather than let a long hint line push the panel wider.
        footer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        emptyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footer.stringValue = Self.browseFooter

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center

        let divider = NSBox()
        divider.boxType = .separator

        previewImage.imageScaling = .scaleProportionallyDown
        previewImage.imageAlignment = .alignCenter
        previewImage.isHidden = true

        for v in [searchField, tableScroll, divider, previewScroll, previewImage, footer, emptyLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(v)
        }

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
            searchField.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),

            tableScroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            tableScroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: tableScroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: tableScroll.centerYAnchor),

            divider.topAnchor.constraint(equalTo: tableScroll.bottomAnchor, constant: 4),
            divider.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            divider.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),

            previewScroll.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 4),
            previewScroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
            previewScroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            previewHeight,

            previewImage.topAnchor.constraint(equalTo: previewScroll.topAnchor, constant: 4),
            previewImage.bottomAnchor.constraint(equalTo: previewScroll.bottomAnchor, constant: -4),
            previewImage.leadingAnchor.constraint(equalTo: previewScroll.leadingAnchor),
            previewImage.trailingAnchor.constraint(equalTo: previewScroll.trailingAnchor),

            footer.topAnchor.constraint(equalTo: previewScroll.bottomAnchor, constant: 6),
            footer.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
            footer.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            footer.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -10),

            // The panel is a fixed size; nothing inside it may resize it.
            background.widthAnchor.constraint(equalToConstant: Self.panelSize.width),
            background.heightAnchor.constraint(equalToConstant: Self.panelSize.height),
        ])
    }

    // MARK: Show / hide

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        let front = NSWorkspace.shared.frontmostApplication
        targetApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front

        searchField.stringValue = ""
        refilter(keepSelection: false)
        positionOnActiveScreen()
        hideWindowButtons()
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(searchField)
    }

    func hide() {
        endEditing(save: true, reselect: false)
        panel.orderOut(nil)
    }

    private func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { panel.center(); return }
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + visible.height * 0.62 - size.height / 2
        )
        panel.setFrameOrigin(origin)
    }

    /// The panel needs a title bar for its rounded, translucent look, but not the traffic-light buttons.
    /// AppKit can put them back when it re-lays out the title bar, so this runs on every show and resize.
    private func hideWindowButtons() {
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(kind)?.isHidden = true
        }
    }

    func windowDidResize(_ notification: Notification) { hideWindowButtons() }
    func windowDidBecomeKey(_ notification: Notification) { hideWindowButtons() }

    func windowDidResignKey(_ notification: Notification) {
        hide() // clicking elsewhere dismisses, like a menu
    }

    // MARK: Filtering & selection

    private func refilter(keepSelection: Bool) {
        let live = Set(store.items.map(\.id))
        imageCache = imageCache.filter { live.contains($0.key) }
        let previousID = keepSelection ? selectedItem?.id : nil
        let terms = searchField.stringValue.lowercased().split(separator: " ").map(String.init)
        filtered = terms.isEmpty
            ? store.items
            : store.items.filter { item in
                let haystack = item.text.lowercased()
                return terms.allSatisfy { haystack.contains($0) }
            }
        tableView.reloadData()

        emptyLabel.stringValue = store.items.isEmpty ? "Nothing copied yet (⌘N adds an item)" : "No matches"
        emptyLabel.isHidden = !filtered.isEmpty

        let row = previousID.flatMap { id in filtered.firstIndex { $0.id == id } } ?? 0
        select(row: row)
    }

    private var selectedItem: ClipItem? {
        let row = tableView.selectedRow
        return filtered.indices.contains(row) ? filtered[row] : nil
    }

    private func select(row: Int) {
        guard !filtered.isEmpty else {
            tableView.deselectAll(nil)
            updatePreview()
            return
        }
        let clamped = min(max(row, 0), filtered.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: clamped), byExtendingSelection: false)
        tableView.scrollRowToVisible(clamped)
        updatePreview()
    }

    private func moveSelection(by delta: Int) {
        guard !filtered.isEmpty else { return }
        let current = tableView.selectedRow < 0 ? 0 : tableView.selectedRow
        select(row: current + delta)
    }

    private var pageSize: Int {
        max(1, Int(tableScroll.contentView.bounds.height / (tableView.rowHeight + tableView.intercellSpacing.height)) - 1)
    }

    private func image(for item: ClipItem) -> NSImage? {
        guard item.isImage else { return nil }
        if let cached = imageCache[item.id] { return cached }
        guard let url = store.imageURL(for: item), let image = NSImage(contentsOf: url) else { return nil }
        imageCache[item.id] = image
        return image
    }

    private func updatePreview() {
        guard !isEditing else { return }
        if let item = selectedItem, item.isImage {
            previewImage.image = image(for: item)
            previewImage.isHidden = false
            previewScroll.isHidden = true
            return
        }
        previewImage.isHidden = true
        previewImage.image = nil
        previewScroll.isHidden = false
        let text = selectedItem?.text ?? ""
        previewText.string = text.count > 20_000 ? String(text.prefix(20_000)) + "\n…" : text
        previewText.scrollToBeginningOfDocument(nil)
    }

    // MARK: Actions

    private func choose(row: Int, paste: Bool) {
        guard filtered.indices.contains(row) else { return }
        let item = filtered[row]
        let target = targetApp
        hide()
        store.copyToPasteboard(item)
        if paste { Paster.paste(into: target) }
    }

    private func deleteSelected() {
        guard let item = selectedItem else { return }
        let row = tableView.selectedRow
        store.remove(id: item.id)
        // store.onChange refilters with the old id (now gone) → reselect the same position
        select(row: row)
    }

    // MARK: Create / edit

    /// Turns the preview pane into an editor for `item`, or for a new item when nil.
    private func beginEditing(_ item: ClipItem?) {
        if isEditing { endEditing(save: true, reselect: false) }
        if let item, item.isImage { NSSound.beep(); return } // screenshots can't be edited as text
        if item == nil, !searchField.stringValue.isEmpty {
            // Show the whole list, so the new item is visible once it's saved.
            searchField.stringValue = ""
            refilter(keepSelection: true)
        }
        isEditing = true
        editingID = item?.id
        previewImage.isHidden = true
        previewScroll.isHidden = false
        previewText.string = item?.text ?? ""  // the full text, not the shortened preview
        previewText.isEditable = true
        previewText.isSelectable = true
        previewText.textColor = .labelColor
        previewText.drawsBackground = true
        previewText.backgroundColor = .textBackgroundColor
        previewText.undoManager?.removeAllActions()
        previewHeight.constant = Self.previewHeightEditing
        footer.stringValue = Self.editFooter
        panel.makeFirstResponder(previewText)
        previewText.setSelectedRange(NSRange(location: (previewText.string as NSString).length, length: 0))
        previewText.scrollRangeToVisible(previewText.selectedRange())
    }

    /// Leaves edit mode, saving the text when `save` is true. Blank text is never saved
    /// (an existing item keeps its old text; use ⌘⌫ to delete it).
    private func endEditing(save: Bool, reselect: Bool = true) {
        guard isEditing else { return }
        let text = previewText.string
        var selectID = editingID
        let wasNew = editingID == nil

        isEditing = false
        editingID = nil
        previewText.isEditable = false
        previewText.isSelectable = false
        previewText.textColor = .secondaryLabelColor
        previewText.drawsBackground = false
        previewHeight.constant = Self.previewHeightBrowsing
        footer.stringValue = Self.browseFooter
        panel.makeFirstResponder(searchField)

        if save {
            if let id = selectID {
                store.update(id: id, text: text)
            } else {
                selectID = store.addText(text)
            }
        }
        if reselect, let id = selectID, let row = filtered.firstIndex(where: { $0.id == id }) {
            select(row: row)
        } else if reselect || wasNew {
            updatePreview()
        }
    }

    /// Esc in the edit pane cancels (NSTextView would otherwise start word completion).
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard textView === previewText, isEditing else { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) || selector == #selector(NSResponder.complete(_:)) {
            endEditing(save: false)
            return true
        }
        return false
    }

    /// ⌘-keys while editing: ⌘↩ saves, the usual text-editing shortcuts work, and nothing reaches the list.
    private func handleEditingKeyEquivalent(_ event: NSEvent, chars: String, flags: NSEvent.ModifierFlags) -> Bool {
        if event.keyCode == 36 || event.keyCode == 76 { // ⌘↩ / ⌘Enter
            endEditing(save: true)
            return true
        }
        switch chars {
        case "a": previewText.selectAll(nil)
        case "c": previewText.copy(nil)
        case "v": previewText.paste(nil)
        case "x": previewText.cut(nil)
        case "z":
            if flags.contains(.shift) { previewText.undoManager?.redo() } else { previewText.undoManager?.undo() }
        case "w", "q": hide() // saves
        default:
            // ⌘← ⌘→ ⌘↑ ⌘↓ ⌘⌫ … are text-view key bindings, not menu shortcuts.
            previewText.interpretKeyEvents([event])
        }
        return true
    }

    private func openSelectedInEditor() {
        guard let item = selectedItem else { return }
        guard !item.isImage else { NSSound.beep(); return }
        hide()
        onOpenInEditor?(item.text)
    }

    private func togglePinSelected() {
        guard let item = selectedItem else { return }
        store.togglePin(id: item.id) // onChange refilters and keeps the selection on this item
    }

    private func moveSelectedPin(by delta: Int) {
        guard let item = selectedItem, item.pinned else { return }
        store.movePinned(id: item.id, by: delta)
    }

    /// A single click pastes when that's turned on in Settings (otherwise it just selects).
    /// While editing, a click only selects, which saves the edit.
    @objc private func rowClicked() {
        guard Settings.singleClickPastes, !isEditing, filtered.indices.contains(tableView.clickedRow) else { return }
        choose(row: tableView.clickedRow, paste: true)
    }

    @objc private func rowDoubleClicked() {
        choose(row: tableView.clickedRow, paste: true)
    }

    // MARK: Keyboard

    /// ⌘-shortcuts. There's no Edit menu in a menu-bar app, so we route the text-editing ones ourselves.
    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return false }
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let onlyCommand = flags.subtracting([.numericPad, .function, .capsLock]) == .command

        if isEditing { return handleEditingKeyEquivalent(event, chars: chars, flags: flags) }

        if onlyCommand, let digit = Int(chars), (1...9).contains(digit) {
            choose(row: digit - 1, paste: true)
            return true
        }
        if event.keyCode == 51 { // ⌘⌫
            deleteSelected()
            return true
        }
        if flags.contains(.option), event.keyCode == 126 || event.keyCode == 125 { // ⌥⌘↑ / ⌥⌘↓
            moveSelectedPin(by: event.keyCode == 126 ? -1 : 1)
            return true
        }
        switch chars {
        case "c":
            if let editor = panel.fieldEditor(false, for: searchField) as? NSTextView,
               editor.selectedRange().length > 0 {
                return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
            }
            choose(row: tableView.selectedRow, paste: false)
            return true
        case "n" where onlyCommand:
            beginEditing(nil)
            return true
        case "e" where onlyCommand:
            if let item = selectedItem { beginEditing(item) } else { NSSound.beep() }
            return true
        case "o" where onlyCommand:
            openSelectedInEditor()
            return true
        case "p" where onlyCommand:
            togglePinSelected()
            return true
        case "a": return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
        case "v": return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
        case "x": return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
        case "z":
            let sel = flags.contains(.shift) ? Selector(("redo:")) : Selector(("undo:"))
            return NSApp.sendAction(sel, to: nil, from: self)
        case "w", "q":
            hide()
            return true
        default:
            return false
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let optionHeld = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
        switch selector {
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertBacktab(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)):
            moveSelection(by: -pageSize)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)):
            moveSelection(by: pageSize)
        case #selector(NSResponder.moveToBeginningOfDocument(_:)),
             #selector(NSResponder.scrollToBeginningOfDocument(_:)):
            select(row: 0)
        case #selector(NSResponder.moveToEndOfDocument(_:)),
             #selector(NSResponder.scrollToEndOfDocument(_:)):
            select(row: filtered.count - 1)
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            choose(row: tableView.selectedRow, paste: !optionHeld)
        case #selector(NSResponder.cancelOperation(_:)):
            if searchField.stringValue.isEmpty {
                hide()
            } else {
                searchField.stringValue = ""
                refilter(keepSelection: false)
            }
        default:
            return false
        }
        return true
    }

    func controlTextDidChange(_ obj: Notification) {
        refilter(keepSelection: false)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        AlwaysEmphasizedRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: Self.cellID, owner: self) as? ClipCellView)
            ?? ClipCellView(identifier: Self.cellID)
        cell.configure(item: filtered[row], row: row, formatter: dateFormatter, image: image(for: filtered[row]))
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // Picking another row while editing saves the edit and moves on.
        if isEditing, selectedItem?.id != editingID { endEditing(save: true, reselect: false) }
        updatePreview()
    }

    // MARK: Right-click menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let mi = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
            mi.target = self
            menu.addItem(mi)
        }
        let row = tableView.clickedRow
        guard filtered.indices.contains(row) else {
            add("New Item", #selector(menuNew)) // right-click on empty space
            return
        }
        select(row: row)
        let item = filtered[row]

        add("Paste", #selector(menuPaste))
        add("Copy", #selector(menuCopy))
        add("Open in Editor", #selector(menuOpenInEditor), enabled: !item.isImage)
        menu.addItem(.separator())
        add("New Item", #selector(menuNew))
        add("Edit", #selector(menuEdit), enabled: !item.isImage)
        menu.addItem(.separator())
        add(item.pinned ? "Unpin" : "Pin to Top", #selector(menuTogglePin))
        if item.pinned {
            let idx = store.items.firstIndex { $0.id == item.id } ?? 0
            add("Move Up", #selector(menuMoveUp), enabled: idx > 0)
            add("Move Down", #selector(menuMoveDown), enabled: idx < store.pinnedCount - 1)
        }
        menu.addItem(.separator())
        add("Delete", #selector(menuDelete))
    }

    @objc private func menuPaste() { choose(row: tableView.selectedRow, paste: true) }
    @objc private func menuCopy() { choose(row: tableView.selectedRow, paste: false) }
    @objc private func menuOpenInEditor() { openSelectedInEditor() }
    @objc private func menuNew() { beginEditing(nil) }
    @objc private func menuEdit() { if let item = selectedItem { beginEditing(item) } }
    @objc private func menuTogglePin() { togglePinSelected() }
    @objc private func menuMoveUp() { moveSelectedPin(by: -1) }
    @objc private func menuMoveDown() { moveSelectedPin(by: 1) }
    @objc private func menuDelete() { deleteSelected() }
}
