// Editor (formerly PlainPad) — a minimal plain-text editor with tabs, spell check and crash-safe autosave.
import Cocoa
import CoreText
import UniformTypeIdentifiers

// MARK: - Storage
// Every open document lives as a .txt file in ~/Library/Application Support/PlainPad/Documents.
// Files are written atomically on every edit (debounced), so a crash or restart loses nothing.
// Explicitly closing a tab deletes its file; quitting the app keeps everything.
// The folder is still named PlainPad so documents from the standalone app carry over.

final class Store {
    static let shared = Store()

    let root: URL
    let docsDir: URL
    private var orderURL: URL { root.appendingPathComponent("order.json") }

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("PlainPad", isDirectory: true)
        docsDir = root.appendingPathComponent("Documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
    }

    private func url(for id: String) -> URL { docsDir.appendingPathComponent(id + ".txt") }

    func save(id: String, text: String) {
        try? text.write(to: url(for: id), atomically: true, encoding: .utf8)
    }

    func delete(id: String) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// One window's tabs in order, the selected tab, and where the window was (an NSStringFromRect).
    struct WindowState: Codable { var ids: [String]; var selected: String?; var frame: String? }
    private struct Session: Codable { var windows: [WindowState] }
    /// order.json before there could be more than one window.
    private struct LegacyOrder: Codable { var ids: [String]; var selected: String? }

    struct SavedWindow { var docs: [(id: String, text: String)]; var selected: String?; var frame: NSRect? }

    /// Saves the windows front to back.
    func saveSession(_ windows: [WindowState]) {
        if let data = try? JSONEncoder().encode(Session(windows: windows)) {
            try? data.write(to: orderURL, options: .atomic)
        }
    }

    /// Returns the saved windows front to back, each with its documents in tab order.
    func load() -> [SavedWindow] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: docsDir, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.pathExtension == "txt" } ?? []
        var byId: [String: (text: String, date: Date)] = [:]
        for f in files {
            let id = f.deletingPathExtension().lastPathComponent
            let text = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
            let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            byId[id] = (text, date)
        }
        let data = try? Data(contentsOf: orderURL)
        let states = data.flatMap { try? JSONDecoder().decode(Session.self, from: $0) }?.windows
            ?? data.flatMap { try? JSONDecoder().decode(LegacyOrder.self, from: $0) }.map { [WindowState(ids: $0.ids, selected: $0.selected)] }
            ?? []
        var seen = Set<String>()
        var windows: [(ids: [String], selected: String?, frame: NSRect?)] = states.map { s in
            (s.ids.filter { byId[$0] != nil && seen.insert($0).inserted }, s.selected, s.frame.map(NSRectFromString))
        }.filter { !$0.ids.isEmpty }
        // Any files not listed in the order (e.g. created just before a crash) go at the end of the front window.
        let extra = byId.keys.filter { !seen.contains($0) }.sorted { byId[$0]!.date < byId[$1]!.date }
        if !extra.isEmpty {
            if windows.isEmpty { windows.append(([], nil, nil)) }
            windows[0].ids += extra
        }
        return windows.map { w in SavedWindow(docs: w.ids.map { ($0, byId[$0]!.text) }, selected: w.selected, frame: w.frame) }
    }
}

// MARK: - JSON
// A tab whose text looks like a JSON object or array gets JSON tools: validate, beautify and folding.
// Everything works on UTF-16 code units so positions line up with NSString / NSTextView ranges.
// Beautify re-emits each token exactly as written, so key order and number formatting are preserved.

enum JSONTools {
    struct Issue: Error { let index: Int; let message: String }
    /// A {…} or […] that spans more than one line, so it can be collapsed.
    struct FoldPair { let open: Int; let close: Int; let depth: Int }

    static func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 10 || c == 13 || c == 9 }
    static func isOpen(_ c: UInt16?) -> Bool { c == 0x7B || c == 0x5B }
    static func isClose(_ c: UInt16?) -> Bool { c == 0x7D || c == 0x5D }

    /// Starts with { or [ and ends with } or ]. Used to switch a tab into JSON mode.
    static func looksLikeJSON(_ u: [UInt16]) -> Bool {
        isOpen(u.first { !isSpace($0) }) && isClose(u.last { !isSpace($0) })
    }

    /// Once a tab is in JSON mode it stays there while it still starts like JSON, even mid-edit.
    static func startsLikeJSON(_ u: [UInt16]) -> Bool { isOpen(u.first { !isSpace($0) }) }

    static func validate(_ u: [UInt16]) -> Issue? {
        var s = JSONScanner(u, format: false)
        return s.run()
    }

    static func beautify(_ u: [UInt16]) -> Result<[UInt16], Issue> {
        var s = JSONScanner(u, format: true)
        if let issue = s.run() { return .failure(issue) }
        return .success(s.out)
    }

    /// Bracket pairs that span several lines. Lenient, so folding still works while the JSON has errors.
    static func foldPairs(_ u: [UInt16]) -> [FoldPair] {
        var pairs: [FoldPair] = []
        var stack: [(index: Int, line: Int, isObject: Bool)] = []
        var line = 0, i = 0
        let n = u.count
        while i < n {
            let c = u[i]
            switch c {
            case 10: line += 1
            case 0x22: // skip strings; stop at a line break so an unclosed quote doesn't swallow the rest
                i += 1
                while i < n, u[i] != 0x22 {
                    if u[i] == 10 { i -= 1; break }
                    i += u[i] == 0x5C ? 2 : 1
                }
            case 0x7B, 0x5B: stack.append((i, line, c == 0x7B))
            case 0x7D, 0x5D:
                if let top = stack.last, top.isObject == (c == 0x7D) {
                    stack.removeLast()
                    if line > top.line { pairs.append(FoldPair(open: top.index, close: i, depth: stack.count)) }
                }
            default: break
            }
            i += 1
        }
        return pairs.sorted { $0.open < $1.open }
    }

    static func lineAndColumn(of index: Int, in u: [UInt16]) -> (line: Int, column: Int) {
        var line = 1, lineStart = 0
        for k in 0..<min(index, u.count) where u[k] == 10 { line += 1; lineStart = k + 1 }
        return (line, index - lineStart + 1)
    }
}

/// Strict JSON (RFC 8259) checker that can also pretty-print with 2-space indentation.
/// Iterative rather than recursive, so deeply nested input can't overflow the stack.
private struct JSONScanner {
    private enum State { case top, arrayFirst, arrayNext, keyFirst, keyNext, colon, objectValue, afterValue, end }
    private struct Open { let isObject: Bool; let index: Int; var count = 0 }

    let u: [UInt16]
    let format: Bool
    private(set) var out: [UInt16] = []
    private var i = 0
    private var stack: [Open] = []
    private var state = State.top
    private var lastComma = 0

    init(_ u: [UInt16], format: Bool) {
        self.u = u
        self.format = format
        if format { out.reserveCapacity(u.count + u.count / 2) }
    }

    mutating func run() -> JSONTools.Issue? {
        let n = u.count
        while true {
            while i < n, JSONTools.isSpace(u[i]) { i += 1 }
            if state == .end {
                return i < n ? issue(i, "Unexpected text after the end of the JSON.") : nil
            }
            guard i < n else {
                if let top = stack.last {
                    return issue(top.index, top.isObject ? "This { is never closed (missing })." : "This [ is never closed (missing ]).")
                }
                return issue(0, "The document is empty.")
            }
            let c = u[i]
            switch state {
            case .top, .objectValue:
                if let e = value() { return e }
            case .arrayFirst, .arrayNext:
                if JSONTools.isClose(c) {
                    if state == .arrayNext { return issue(lastComma, "Trailing comma: nothing comes after this ','.") }
                    if c == 0x7D { return issue(i, "Expected ']' to close the array, but found '}'.") }
                    close()
                } else {
                    startElement()
                    if let e = value() { return e }
                }
            case .keyFirst, .keyNext:
                if c == 0x7D, state == .keyFirst {
                    close()
                } else if JSONTools.isClose(c), state == .keyNext {
                    return issue(lastComma, "Trailing comma: nothing comes after this ','.")
                } else if c == 0x22 {
                    startElement()
                    if let e = string() { return e }
                    state = .colon
                } else if c == 0x27 {
                    return issue(i, "Property names must use double quotes (\"), not single quotes.")
                } else {
                    return issue(i, "Expected a property name in double quotes.")
                }
            case .colon:
                guard c == 0x3A else { return issue(i, "Expected ':' after the property name.") }
                emit(0x3A); emit(0x20)
                i += 1
                state = .objectValue
            case .afterValue:
                let top = stack[stack.count - 1]
                if c == 0x2C {
                    lastComma = i
                    emit(c)
                    i += 1
                    state = top.isObject ? .keyNext : .arrayNext
                } else if c == (top.isObject ? 0x7D : 0x5D) {
                    close()
                } else if c == 0x22 || JSONTools.isOpen(c) || c == 0x2D || isWordChar(c) {
                    return issue(i, "Missing ',' before this item.")
                } else {
                    return issue(i, top.isObject ? "Expected ',' or '}' after the value." : "Expected ',' or ']' after the value.")
                }
            case .end:
                break
            }
        }
    }

    private func issue(_ at: Int, _ message: String) -> JSONTools.Issue { .init(index: at, message: message) }

    private func isWordChar(_ c: UInt16) -> Bool {
        (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39) || c == 0x5F
    }

    private func isHex(_ c: UInt16) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x66) || (c >= 0x41 && c <= 0x46)
    }

    private mutating func emit(_ c: UInt16) { if format { out.append(c) } }

    private mutating func newline() {
        guard format else { return }
        out.append(10)
        out.append(contentsOf: repeatElement(32, count: stack.count * 2))
    }

    /// Called before each array item or object key: counts it and puts it on its own line.
    private mutating func startElement() {
        stack[stack.count - 1].count += 1
        newline()
    }

    private mutating func close() {
        let top = stack.removeLast()
        if top.count > 0 { newline() }
        emit(top.isObject ? 0x7D : 0x5D)
        i += 1
        state = stack.isEmpty ? .end : .afterValue
    }

    private mutating func value() -> JSONTools.Issue? {
        let c = u[i]
        switch c {
        case 0x7B, 0x5B:
            stack.append(Open(isObject: c == 0x7B, index: i))
            emit(c)
            i += 1
            state = c == 0x7B ? .keyFirst : .arrayFirst
            return nil
        case 0x22:
            if let e = string() { return e }
        case 0x2D, 0x30...0x39:
            if let e = number() { return e }
        case 0x27:
            return issue(i, "Strings must use double quotes (\"), not single quotes.")
        case 0x7D, 0x5D:
            return issue(i, "Expected a value before this '\(c == 0x7D ? "}" : "]")'.")
        default:
            guard isWordChar(c) else {
                return issue(i, "Expected a value: text in double quotes, a number, true, false, null, an object or an array.")
            }
            if let e = word() { return e }
        }
        state = stack.isEmpty ? .end : .afterValue
        return nil
    }

    private mutating func string() -> JSONTools.Issue? {
        let u = self.u, n = u.count, start = i
        var j = i + 1
        while true {
            guard j < n else { return issue(start, "This string is never closed (missing \").") }
            let c = u[j]
            if c == 0x22 { break }
            if c == 10 || c == 13 { return issue(start, "This string is never closed (missing \" before the end of the line).") }
            if c < 0x20 { return issue(j, "Tabs and other control characters inside strings must be escaped (e.g. \\t).") }
            if c == 0x5C {
                switch j + 1 < n ? u[j + 1] : 0 {
                case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74:
                    j += 2
                case 0x75:
                    for k in j + 2 ..< j + 6 where !(k < n && isHex(u[k])) {
                        return issue(j, "Invalid \\u escape: expected 4 hex digits.")
                    }
                    j += 6
                default:
                    return issue(j, "Invalid escape. Allowed: \\\" \\\\ \\/ \\b \\f \\n \\r \\t \\uXXXX")
                }
                continue
            }
            j += 1
        }
        if format { out.append(contentsOf: u[start...j]) }
        i = j + 1
        return nil
    }

    private mutating func number() -> JSONTools.Issue? {
        let u = self.u, n = u.count, start = i
        var j = i
        func isDigit(_ k: Int) -> Bool { k < n && u[k] >= 0x30 && u[k] <= 0x39 }
        if u[j] == 0x2D { j += 1 }
        guard isDigit(j) else { return issue(start, "Invalid number.") }
        if u[j] == 0x30 {
            j += 1
            if isDigit(j) { return issue(start, "Numbers can't have leading zeros.") }
        } else {
            while isDigit(j) { j += 1 }
        }
        if j < n, u[j] == 0x2E {
            j += 1
            guard isDigit(j) else { return issue(start, "Invalid number: expected digits after the decimal point.") }
            while isDigit(j) { j += 1 }
        }
        if j < n, u[j] == 0x65 || u[j] == 0x45 {
            j += 1
            if j < n, u[j] == 0x2B || u[j] == 0x2D { j += 1 }
            guard isDigit(j) else { return issue(start, "Invalid number: expected digits in the exponent.") }
            while isDigit(j) { j += 1 }
        }
        if format { out.append(contentsOf: u[start..<j]) }
        i = j
        return nil
    }

    private mutating func word() -> JSONTools.Issue? {
        var j = i
        while j < u.count, isWordChar(u[j]) { j += 1 }
        let w = String(decoding: u[i..<j], as: UTF16.self)
        guard w == "true" || w == "false" || w == "null" else {
            let shown = w.count > 30 ? String(w.prefix(30)) + "…" : w
            return issue(i, "Unknown value '\(shown)'. Text must be in double quotes; the only bare words allowed are true, false and null.")
        }
        if format { out.append(contentsOf: u[i..<j]) }
        i = j
        return nil
    }
}

// MARK: - Document (one per tab)

final class Document: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate, NSTextStorageDelegate {
    // Zoom scales both fonts. It's one level for every tab, and it's remembered between launches.
    static let zoomSteps: [CGFloat] = [0.5, 0.67, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]
    static var zoom: CGFloat = {
        let saved = CGFloat(UserDefaults.standard.double(forKey: "zoom"))
        return saved > 0 ? saved : 1
    }() {
        didSet { UserDefaults.standard.set(Double(zoom), forKey: "zoom") }
    }
    static var textFont: NSFont { .systemFont(ofSize: (15 * zoom).rounded()) }
    static var jsonFont: NSFont { .monospacedSystemFont(ofSize: (13 * zoom).rounded(), weight: .regular) }
    /// Above this size, JSON checking waits until typing pauses instead of running on every keystroke.
    private static let liveAnalysisLimit = 300_000

    let id: String
    let scrollView: NSScrollView
    let textView: NSTextView
    private(set) var ruler: FoldRulerView!
    var onChange: (() -> Void)?
    private var saveTimer: Timer?
    /// Each tab has its own undo history (rather than its window's), so it goes along when the tab moves to another window.
    private let undo = UndoManager()

    // JSON state
    private(set) var isJSON = false
    private(set) var jsonIssue: JSONTools.Issue?
    private(set) var foldPairs: [JSONTools.FoldPair] = []
    private var pairByOpen: [Int: JSONTools.FoldPair] = [:]
    private(set) var folded = Set<Int>()                        // open-bracket indices of collapsed pairs
    private var hidden: [(range: NSRange, ellipsis: Int)] = []  // outermost collapsed ranges, sorted
    private var needsAnalysis = false
    private var replacedEverything = false  // e.g. Select All + Paste: detect JSON afresh
    private var spellingBeforeJSON = true
    private var adjustingSelection = false

    init(id: String, text: String) {
        self.id = id
        // Built by hand (rather than NSTextView.scrollableTextView()) so the view can be an EditorTextView.
        let tv = EditorTextView(frame: .zero)
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = .width
        tv.textContainer?.widthTracksTextView = true
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.documentView = tv
        textView = tv
        super.init()

        tv.isRichText = false
        tv.importsGraphics = false
        tv.usesRuler = false
        tv.allowsUndo = true
        tv.isContinuousSpellCheckingEnabled = true      // red squiggles
        tv.isAutomaticSpellingCorrectionEnabled = false // don't silently change words
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.font = Document.textFont
        tv.textContainerInset = NSSize(width: 14, height: 14)
        tv.string = text
        tv.delegate = self
        // Folding hides glyphs through the layout manager (this also opts the view into TextKit 1).
        tv.layoutManager?.delegate = self
        tv.textStorage?.delegate = self

        ruler = FoldRulerView(doc: self)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewMoved),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(viewMoved),
                                               name: NSView.frameDidChangeNotification, object: tv)
        analyzeJSON()
    }

    @objc private func viewMoved() { if isJSON { ruler.needsDisplay = true } }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    var isEmpty: Bool { textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var title: String {
        let firstLine = textView.string
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        if firstLine.isEmpty { return "Untitled" }
        if isJSON, firstLine == "{" || firstLine == "[" { return "JSON" }
        return firstLine.count > 60 ? String(firstLine.prefix(60)) + "…" : firstLine
    }

    func textDidChange(_ notification: Notification) {
        if (textView.string as NSString).length <= Document.liveAnalysisLimit {
            analyzeJSON()
        } else {
            needsAnalysis = true
            setFoldPairs([])
            markIssue(nil, in: [])  // its position is stale until the next analysis
        }
        onChange?()
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.saveNow()
            if self.needsAnalysis { self.analyzeJSON(); self.onChange?() }
        }
    }

    func saveNow() {
        saveTimer?.invalidate()
        saveTimer = nil
        Store.shared.save(id: id, text: textView.string)
    }

    func discard() {
        saveTimer?.invalidate()
        saveTimer = nil
        Store.shared.delete(id: id)
    }

    // MARK: JSON detection, validation, beautify

    private var utf16: [UInt16] { Array(textView.string.utf16) }

    func analyzeJSON() {
        needsAnalysis = false
        let u = utf16
        let wasJSON = isJSON
        let sticky = wasJSON && !replacedEverything
        replacedEverything = false
        isJSON = sticky ? JSONTools.startsLikeJSON(u) : JSONTools.looksLikeJSON(u)
        jsonIssue = isJSON ? JSONTools.validate(u) : nil
        setFoldPairs(isJSON ? JSONTools.foldPairs(u) : [])
        if isJSON != wasJSON {
            if !isJSON { expandAll() }
            applyJSONAppearance()
        }
        markIssue(jsonIssue, in: u)
        ruler.needsDisplay = true
    }

    /// Puts a red squiggle (the same mark as a misspelling) under the JSON error, if there is one.
    /// It's a layout-manager decoration, so the text itself is untouched.
    private func markIssue(_ issue: JSONTools.Issue?, in u: [UInt16]) {
        guard let lm = textView.layoutManager else { return }
        let full = NSRange(location: 0, length: (textView.string as NSString).length)
        lm.removeTemporaryAttribute(.spellingState, forCharacterRange: full)
        guard let issue, let r = issueRange(issue, in: u), NSMaxRange(r) <= full.length else { return }
        lm.addTemporaryAttribute(.spellingState, value: NSAttributedString.SpellingState.spelling.rawValue,
                                 forCharacterRange: r)
    }

    /// The characters to mark for an issue: the whole bad token (e.g. `tru`), or the single character at fault.
    private func issueRange(_ issue: JSONTools.Issue, in u: [UInt16]) -> NSRange? {
        var start = min(issue.index, u.count)
        if start == u.count {
            // Ran off the end (e.g. an unclosed bracket): mark the last visible character.
            while start > 0 && JSONTools.isSpace(u[start - 1]) { start -= 1 }
            return start == 0 ? nil : NSRange(location: start - 1, length: 1)
        }
        func isTokenChar(_ c: UInt16) -> Bool {
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
                || c == 0x2B || c == 0x2D || c == 0x2E || c == 0x5F  // + - . _
        }
        var end = start + 1
        if isTokenChar(u[start]) {
            while start > 0 && isTokenChar(u[start - 1]) { start -= 1 }
            while end < u.count && isTokenChar(u[end]) { end += 1 }
        }
        return NSRange(location: start, length: end - start)
    }

    private func setFoldPairs(_ pairs: [JSONTools.FoldPair]) {
        foldPairs = pairs
        pairByOpen = Dictionary(uniqueKeysWithValues: pairs.map { ($0.open, $0) })
    }

    /// JSON reads better in a monospaced font, and keys would be covered in spelling squiggles.
    private func applyJSONAppearance() {
        let tv = textView
        if isJSON {
            spellingBeforeJSON = tv.isContinuousSpellCheckingEnabled
            tv.isContinuousSpellCheckingEnabled = false
            tv.font = Document.jsonFont
        } else {
            tv.isContinuousSpellCheckingEnabled = spellingBeforeJSON
            tv.font = Document.textFont
        }
        scrollView.rulersVisible = isJSON
    }

    /// Picks up a new zoom level.
    func applyZoom() {
        textView.font = isJSON ? Document.jsonFont : Document.textFont
        ruler.needsDisplay = true
    }

    func describe(_ issue: JSONTools.Issue) -> String {
        let (line, column) = JSONTools.lineAndColumn(of: issue.index, in: utf16)
        return "Line \(line), column \(column): \(issue.message)"
    }

    /// Re-indents the whole document. Returns the problem instead if it isn't valid JSON. Undoable.
    func beautify() -> JSONTools.Issue? {
        let u = utf16
        switch JSONTools.beautify(u) {
        case .failure(let issue):
            return issue
        case .success(let out):
            guard out != u else { return nil }
            let s = String(decoding: out, as: UTF16.self)
            let full = NSRange(location: 0, length: u.count)
            // Its own undo step: typing before or after must not be merged into it.
            let undo = textView.undoManager
            textView.breakUndoCoalescing()
            undo?.beginUndoGrouping()
            if textView.shouldChangeText(in: full, replacementString: s) {
                textView.textStorage?.replaceCharacters(in: full, with: s)
                textView.didChangeText()
                undo?.setActionName("Beautify JSON")
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
            }
            undo?.endUndoGrouping()
            textView.breakUndoCoalescing()
            return nil
        }
    }

    // MARK: Folding

    func toggleFold(open: Int) {
        if folded.contains(open) { folded.remove(open) } else { folded.insert(open) }
        applyFolds()
    }

    /// Collapses everything below the top level, so the top-level keys / items stay visible.
    func collapseAll() {
        let inner = foldPairs.filter { $0.depth > 0 }
        folded = Set((inner.isEmpty ? foldPairs : inner).map(\.open))
        applyFolds()
    }

    func expandAll() {
        guard !folded.isEmpty else { return }
        folded.removeAll()
        applyFolds()
    }

    /// Collapses the block that starts on the cursor's line, or else the innermost block around the cursor.
    func collapseAtCursor() {
        let loc = textView.selectedRange().location
        let line = (textView.string as NSString).paragraphRange(for: NSRange(location: loc, length: 0))
        let open = foldPairs.filter { !folded.contains($0.open) }
        let target = open.first { NSLocationInRange($0.open, line) }
            ?? open.filter { $0.open < loc && loc <= $0.close }.max { $0.open < $1.open }
        if let target { folded.insert(target.open); applyFolds() }
    }

    /// Expands collapsed blocks that start or end on the cursor's line.
    func expandAtCursor() {
        let loc = textView.selectedRange().location
        let line = (textView.string as NSString).paragraphRange(for: NSRange(location: loc, length: 0))
        let hits = folded.filter { o in
            guard let p = pairByOpen[o] else { return true }
            return NSLocationInRange(p.open, line) || NSLocationInRange(p.close, line)
        }
        if !hits.isEmpty { folded.subtract(hits); applyFolds() }
    }

    private func hiddenRange(_ p: JSONTools.FoldPair) -> NSRange {
        NSRange(location: p.open + 1, length: p.close - p.open - 1)
    }

    /// Recomputes which characters are hidden and redoes layout only where that changed.
    private func applyFolds() {
        folded = folded.filter { pairByOpen[$0] != nil }
        let text = textView.string as NSString
        var new: [(range: NSRange, ellipsis: Int)] = []
        for open in folded.sorted() {
            let r = hiddenRange(pairByOpen[open]!)
            if let last = new.last, NSMaxRange(last.range) >= NSMaxRange(r) { continue } // inside a collapsed parent
            // The "…" is drawn in place of the first visible character inside the brackets.
            var e = r.location
            while e < NSMaxRange(r), [10, 13, 9].contains(text.character(at: e)) { e += 1 }
            new.append((r, e < NSMaxRange(r) ? e : -1))
        }
        let old = hidden
        hidden = new

        if let lm = textView.layoutManager {
            let changed = Set(old.map { $0.range }).symmetricDifference(new.map { $0.range })
            for r in changed {
                lm.invalidateGlyphs(forCharacterRange: r, changeInLength: 0, actualCharacterRange: nil)
                lm.invalidateLayout(forCharacterRange: r, actualCharacterRange: nil)
            }
            for h in old where h.ellipsis >= 0 {
                let r = NSRange(location: h.ellipsis, length: 1)
                lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: r)
                lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: r)
            }
            for h in new where h.ellipsis >= 0 {
                lm.addTemporaryAttributes([.foregroundColor: NSColor.secondaryLabelColor,
                                           .backgroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.15)],
                                          forCharacterRange: NSRange(location: h.ellipsis, length: 1))
            }
        }
        moveSelectionOutOfFolds()
        textView.needsDisplay = true
        ruler.needsDisplay = true
    }

    /// Whether a selection edge at `p` lands inside hidden range `r`. A bare cursor counts from the opening bracket.
    private func lands(_ p: Int, in r: NSRange, caret: Bool) -> Bool {
        (caret ? p >= r.location : p > r.location) && p < NSMaxRange(r)
    }

    private func selectionEdges() -> [(Int, Bool)] {
        let sel = textView.selectedRange()
        return sel.length == 0 ? [(sel.location, true)] : [(sel.location, false), (NSMaxRange(sel), false)]
    }

    /// After collapsing, a cursor that ended up inside hidden text is moved to just after the block.
    private func moveSelectionOutOfFolds() {
        let edges = selectionEdges()
        guard let h = hidden.first(where: { h in edges.contains { lands($0.0, in: h.range, caret: $0.1) } }) else { return }
        let after = min(NSMaxRange(h.range) + 1, (textView.string as NSString).length)
        adjustingSelection = true
        textView.setSelectedRange(NSRange(location: after, length: 0))
        adjustingSelection = false
    }

    /// Clicking the "…", arrowing into a collapsed block or a Find match inside one expands it.
    func textViewDidChangeSelection(_ notification: Notification) {
        guard !adjustingSelection, !folded.isEmpty else { return }
        let edges = selectionEdges()
        let hits = folded.filter { o in
            guard let p = pairByOpen[o] else { return true }
            return edges.contains { lands($0.0, in: hiddenRange(p), caret: $0.1) }
        }
        if !hits.isEmpty { folded.subtract(hits); applyFolds() }
    }

    /// Any edit expands everything first, so typing never happens inside invisible text.
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if affectedCharRange.length > 0, affectedCharRange.length == (textView.string as NSString).length {
            replacedEverything = true
        }
        expandAll()
        return true
    }

    /// Safety net for edits that skip the delegate check above (e.g. some undo paths).
    func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), !hidden.isEmpty else { return }
        folded.removeAll()
        hidden.removeAll()
        DispatchQueue.main.async { [weak self] in
            guard let self, let lm = self.textView.layoutManager else { return }
            let full = NSRange(location: 0, length: (self.textView.string as NSString).length)
            lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            lm.invalidateGlyphs(forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
            lm.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
            self.ruler.needsDisplay = true
        }
    }

    private func hiddenEntry(containing ci: Int) -> (range: NSRange, ellipsis: Int)? {
        var lo = 0, hi = hidden.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = hidden[mid].range
            if ci < r.location { hi = mid - 1 } else if ci >= NSMaxRange(r) { lo = mid + 1 } else { return hidden[mid] }
        }
        return nil
    }

    func isHidden(_ ci: Int) -> Bool { hiddenEntry(containing: ci) != nil }

    // Collapsed characters get null glyphs (no width, not drawn), except one that is drawn as "…".
    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>, font aFont: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        let n = glyphRange.length
        guard !hidden.isEmpty, n > 0,
              (0..<n).contains(where: { isHidden(charIndexes[$0]) }) else { return 0 }
        var newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: n))
        var newProps = Array(UnsafeBufferPointer(start: props, count: n))
        var ellipsisChar: UniChar = 0x2026
        var ellipsisGlyph: CGGlyph = 0
        CTFontGetGlyphsForCharacters(aFont as CTFont, &ellipsisChar, &ellipsisGlyph, 1)
        for k in 0..<n {
            guard let h = hiddenEntry(containing: charIndexes[k]) else { continue }
            if charIndexes[k] == h.ellipsis {
                newGlyphs[k] = ellipsisGlyph
                newProps[k] = []
            } else {
                newProps[k] = .null
            }
        }
        layoutManager.setGlyphs(newGlyphs, properties: newProps, characterIndexes: charIndexes,
                                font: aFont, forGlyphRange: glyphRange)
        return n
    }

    // Hidden line breaks must not start new lines.
    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        !hidden.isEmpty && isHidden(charIndex) ? .zeroAdvancement : action
    }
}

/// The gutter to the left of a JSON document: a ▾ / ▸ next to every block that can be collapsed.
final class FoldRulerView: NSRulerView {
    private weak var doc: Document?
    private var foldMarkers: [(rect: NSRect, open: Int)] = []

    init(doc: Document) {
        self.doc = doc
        super.init(scrollView: doc.scrollView, orientation: .verticalRuler)
        ruleThickness = 18
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        clientView = doc.textView
    }

    required init(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        foldMarkers.removeAll()
        guard let doc, doc.isJSON, let lm = doc.textView.layoutManager, let tc = doc.textView.textContainer else { return }
        let tv = doc.textView
        let origin = tv.textContainerOrigin
        let visible = tv.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let chars = lm.characterRange(forGlyphRange: lm.glyphRange(forBoundingRect: visible, in: tc), actualGlyphRange: nil)
        let pairs = doc.foldPairs

        // Binary search for the first block that opens in view.
        var lo = 0, hi = pairs.count
        while lo < hi { let mid = (lo + hi) / 2; if pairs[mid].open < chars.location { lo = mid + 1 } else { hi = mid } }

        var lastY = -CGFloat.greatestFiniteMagnitude
        NSColor.secondaryLabelColor.setFill()
        for p in pairs[lo...] {
            guard p.open < NSMaxRange(chars) else { break }
            if doc.isHidden(p.open) { continue }
            let line = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: p.open), effectiveRange: nil)
            let y = convert(NSPoint(x: 0, y: line.minY + origin.y), from: tv).y
            if abs(y - lastY) < 0.5 { continue } // one marker per line: the outermost block
            lastY = y
            let rowRect = NSRect(x: 0, y: y, width: bounds.width, height: line.height)
            foldMarkers.append((rowRect, p.open))
            drawTriangle(in: rowRect, collapsed: doc.folded.contains(p.open))
        }
    }

    private func drawTriangle(in row: NSRect, collapsed: Bool) {
        let c = NSPoint(x: bounds.width / 2 + 1, y: row.minY + min(row.height, 18) / 2)
        let s: CGFloat = 4
        let path = NSBezierPath()
        if collapsed {
            path.move(to: NSPoint(x: c.x - s * 0.6, y: c.y - s))
            path.line(to: NSPoint(x: c.x + s * 0.8, y: c.y))
            path.line(to: NSPoint(x: c.x - s * 0.6, y: c.y + s))
        } else {
            path.move(to: NSPoint(x: c.x - s, y: c.y - s * 0.6))
            path.line(to: NSPoint(x: c.x + s, y: c.y - s * 0.6))
            path.line(to: NSPoint(x: c.x, y: c.y + s * 0.8))
        }
        path.close()
        path.fill()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let m = foldMarkers.first(where: { p.y >= $0.rect.minY && p.y < $0.rect.maxY }) {
            doc?.toggleFold(open: m.open)
        }
    }
}

// MARK: - File drops
// Dropping files from Finder anywhere on the window opens each one in a new tab.
// The text view would otherwise insert the file's path, so it hands file drops to the controller instead.

enum FileDrop {
    static func urls(_ info: NSDraggingInfo) -> [URL] {
        let objects = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                          options: [.urlReadingFileURLsOnly: true])
        return objects as? [URL] ?? []
    }
}

final class EditorTextView: NSTextView {
    var onDropFiles: (([URL]) -> Void)?

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        var types = super.acceptableDragTypes
        if !types.contains(.fileURL) { types.append(.fileURL) }
        return types
    }

    private func isFileDrop(_ info: NSDraggingInfo) -> Bool {
        onDropFiles != nil && !FileDrop.urls(info).isEmpty
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isFileDrop(sender) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isFileDrop(sender) ? .copy : super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isFileDrop(sender) || super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isFileDrop(sender), let onDropFiles else { return super.performDragOperation(sender) }
        onDropFiles(FileDrop.urls(sender))
        return true
    }
}

/// The window's content view, so drops on the tab strip or JSON bar open files too.
final class DropRootView: NSView {
    var onDropFiles: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        FileDrop.urls(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = FileDrop.urls(sender)
        guard !urls.isEmpty, let onDropFiles else { return false }
        onDropFiles(urls)
        return true
    }
}

// MARK: - Tab strip

final class TabItemView: NSView {
    let doc: Document
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let closeButton: NSButton
    private var hovering = false { didSet { needsDisplay = true } }

    var isSelected = false {
        didSet {
            label.textColor = isSelected ? .labelColor : .secondaryLabelColor
            needsDisplay = true
        }
    }

    var title: String {
        get { label.stringValue }
        set { if label.stringValue != newValue { label.stringValue = newValue; toolTip = newValue } }
    }

    init(doc: Document) {
        self.doc = doc
        let image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")!
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))!
        closeButton = NSButton(image: image, target: nil, action: nil)
        super.init(frame: .zero)

        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "Close Tab"
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        addSubview(closeButton)

        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        addSubview(label)

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let b = 16.0
        closeButton.frame = NSRect(x: bounds.maxX - b - 8, y: (bounds.height - b) / 2, width: b, height: b)
        let labelH = label.intrinsicContentSize.height
        label.frame = NSRect(x: 28, y: (bounds.height - labelH) / 2, width: max(0, bounds.width - 56), height: labelH)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 2, dy: 0)
        let path = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
        if isSelected {
            NSColor.textBackgroundColor.setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 0.5
            path.stroke()
        } else if hovering {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            path.fill()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        if closeButton.frame.contains(p) { return closeButton }
        return bounds.contains(p) ? self : nil
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
        if let bar = superview as? TabBarView { TabDrag.track(doc, in: bar) }
    }

    // Middle-click closes a tab, like in browsers.
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose?() }
    }

    @objc private func closeClicked() { onClose?() }
}

final class TabBarView: NSView {
    static let height: CGFloat = 38
    weak var controller: MainWindowController?

    private var items: [TabItemView] = []
    private var draggedItem: TabItemView?
    private let addButton: NSButton
    private let pad: CGFloat = 8
    private let addWidth: CGFloat = 32
    private let minTabWidth: CGFloat = 90

    override init(frame: NSRect) {
        let image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")!
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))!
        addButton = NSButton(image: image, target: nil, action: nil)
        super.init(frame: frame)
        addButton.isBordered = false
        addButton.contentTintColor = .secondaryLabelColor
        addButton.toolTip = "New Tab (⌘T)"
        addButton.target = self
        addButton.action = #selector(addClicked)
        addSubview(addButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    @objc private func addClicked() { controller?.newTab() }

    /// Matches the tab views to the controller's documents, reusing existing views.
    func sync() {
        guard let controller else { return }
        var newItems: [TabItemView] = []
        for doc in controller.docs {
            if let existing = items.first(where: { $0.doc === doc }) {
                newItems.append(existing)
            } else {
                let item = TabItemView(doc: doc)
                item.onSelect = { [weak controller, weak doc] in if let doc { controller?.select(doc) } }
                item.onClose = { [weak controller, weak doc] in if let doc { controller?.requestClose(doc) } }
                addSubview(item)
                newItems.append(item)
            }
        }
        for old in items where !newItems.contains(old) { old.removeFromSuperview() }
        items = newItems
        for item in items {
            item.isSelected = item.doc === controller.current
            item.title = item.doc.title
        }
        layoutItems(animated: false)
    }

    func updateTitles() {
        for item in items { item.title = item.doc.title }
    }

    var tabWidth: CGFloat {
        guard !items.isEmpty else { return 0 }
        let available = bounds.width - pad * 2 - addWidth - 4
        return max(minTabWidth, available / CGFloat(items.count))
    }

    private func frameForTab(at index: Int) -> NSRect {
        NSRect(x: pad + CGFloat(index) * tabWidth, y: 5, width: tabWidth, height: bounds.height - 11)
    }

    private func layoutItems(animated: Bool) {
        for (i, item) in items.enumerated() where item !== draggedItem {
            let f = frameForTab(at: i)
            if animated { item.animator().frame = f } else { item.frame = f }
        }
        let addX = min(pad + CGFloat(items.count) * tabWidth + 4, bounds.width - addWidth - 4)
        addButton.frame = NSRect(x: addX, y: (bounds.height - 1 - 26) / 2, width: addWidth - 4, height: 26)
    }

    override func layout() {
        super.layout()
        layoutItems(animated: false)
    }

    // MARK: Dragging (driven by TabDrag)

    /// The tab bar's rectangle in screen coordinates.
    var screenFrame: NSRect { window?.convertToScreen(convert(bounds, to: nil)) ?? .zero }

    /// A tab's rectangle in screen coordinates.
    func screenFrame(of doc: Document) -> NSRect? {
        guard let window, let item = items.first(where: { $0.doc === doc }) else { return nil }
        return window.convertToScreen(convert(item.frame, to: nil))
    }

    private func localX(_ screenX: CGFloat) -> CGFloat {
        guard let window else { return 0 }
        return convert(window.convertPoint(fromScreen: NSPoint(x: screenX, y: 0)), from: nil).x
    }

    /// Where a tab arriving with its left edge at `screenX` should go.
    func insertionIndex(forScreenX screenX: CGFloat) -> Int {
        guard !items.isEmpty else { return 0 }
        return min(max(0, Int(((localX(screenX) - pad) / tabWidth).rounded())), items.count)
    }

    func beginDrag(of doc: Document) {
        guard let item = items.first(where: { $0.doc === doc }) else { return }
        draggedItem = item
        addSubview(item, positioned: .above, relativeTo: nil)
    }

    /// Moves the dragged tab's left edge to `screenX`. The other tabs make way as it passes their middles.
    func drag(toScreenX screenX: CGFloat) {
        guard let item = draggedItem else { return }
        let maxX = pad + CGFloat(items.count - 1) * tabWidth
        item.frame.origin.x = min(max(pad, localX(screenX)), maxX)

        let target = min(max(0, Int((item.frame.midX - pad) / tabWidth)), items.count - 1)
        if let from = items.firstIndex(of: item), from != target {
            items.remove(at: from)
            items.insert(item, at: target)
            controller?.moveDocument(from: from, to: target)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                layoutItems(animated: true)
            }
        }
    }

    /// Lets the dragged tab settle into its slot.
    func endDrag() {
        guard draggedItem != nil else { return }
        draggedItem = nil
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            layoutItems(animated: true)
        }
    }
}

// MARK: - Tab dragging
// Like browser tabs: slide a tab along its bar to reorder it, pull it away from the bar to give it a
// window of its own, or drop it onto another window's tab bar to move it there. A window's only tab
// can't be reordered, so dragging it moves its whole window (and can drop it into another one).
// Everything is tracked in screen coordinates, because the tab changes windows mid-drag.

final class TabDrag {
    /// How far the mouse can stray from the tab bar before the tab comes out into a window of its own.
    private static let detachDistance: CGFloat = 30

    private let doc: Document
    private var bar: TabBarView?                 // the bar the tab is being slid along; nil while it's in its own window
    private var floating: MainWindowController?  // the tab's own window, once it has one
    private var grab: NSPoint                    // where the tab was grabbed, from its bottom-left corner
    private var floatOffset = NSPoint.zero       // where the mouse is in the floating window

    private init(doc: Document, bar: TabBarView, grab: NSPoint) {
        self.doc = doc
        self.bar = bar
        self.grab = grab
    }

    static func track(_ doc: Document, in bar: TabBarView) {
        let start = NSEvent.mouseLocation
        guard let tab = bar.screenFrame(of: doc) else { return }
        TabDrag(doc: doc, bar: bar, grab: NSPoint(x: start.x - tab.minX, y: start.y - tab.minY)).run(from: start)
    }

    private func run(from start: NSPoint) {
        var started = false
        while let event = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture,
                                          inMode: .eventTracking, dequeue: true), event.type != .leftMouseUp {
            let p = NSEvent.mouseLocation
            if !started {
                guard hypot(p.x - start.x, p.y - start.y) > 4 else { continue }
                started = true
                if let c = bar?.controller, c.docs.count == 1 { float(in: c) } else { bar?.beginDrag(of: doc) }
            }
            move(to: p)
        }
        if started { finish() }
    }

    private func move(to p: NSPoint) {
        if let bar {
            if bar.screenFrame.insetBy(dx: -Self.detachDistance, dy: -Self.detachDistance).contains(p) {
                bar.drag(toScreenX: p.x - grab.x)
                return
            }
            tearOff()
        }
        if let target = tabBar(under: p) {
            drop(into: target, at: p)
        } else if let w = floating?.window {
            w.setFrameOrigin(NSPoint(x: p.x - floatOffset.x, y: p.y - floatOffset.y))
        }
    }

    /// Takes the tab out of its bar into the window it had before, if it's been out already, or else a new one.
    private func tearOff() {
        guard let bar, let source = bar.controller else { return }
        bar.endDrag()
        let c = floating ?? (source.docs.count == 1 ? source : MainWindowController(frame: source.window.frame))
        if c !== source {
            source.detach(doc)
            c.attach(doc, at: 0)
        }
        float(in: c)
    }

    /// From now on the window follows the mouse, keeping the spot where the tab was grabbed under it.
    private func float(in c: MainWindowController) {
        bar = nil
        floating = c
        let w = c.window
        if let tab = c.tabBar.screenFrame(of: doc) {
            floatOffset = NSPoint(x: tab.minX + grab.x - w.frame.minX, y: tab.minY + grab.y - w.frame.minY)
        }
        w.alphaValue = 1
        w.orderFront(nil)
    }

    /// The tab bar of another editor window under the mouse, if no other window is covering it.
    private func tabBar(under p: NSPoint) -> TabBarView? {
        guard let floating else { return nil }
        let number = NSWindow.windowNumber(at: p, belowWindowWithWindowNumber: floating.window.windowNumber)
        guard let c = MainWindowController.all.first(where: { $0 !== floating && $0.window.windowNumber == number }),
              c.tabBar.screenFrame.contains(p) else { return nil }
        return c.tabBar
    }

    private func drop(into target: TabBarView, at p: NSPoint) {
        guard let floating, let c = target.controller else { return }
        floating.detach(doc)
        // Hidden rather than closed: the tab may be pulled out again before the mouse is released.
        floating.window.alphaValue = 0
        c.attach(doc, at: target.insertionIndex(forScreenX: p.x - grab.x))
        c.window.orderFront(nil)
        grab.x = min(grab.x, target.tabWidth - 12)
        bar = target
        target.beginDrag(of: doc)
        target.drag(toScreenX: p.x - grab.x)
    }

    private func finish() {
        if let bar {
            bar.endDrag()
            if let floating, floating.docs.isEmpty { floating.closeWindow() }
            bar.controller?.select(doc)
            bar.window?.makeKeyAndOrderFront(nil)
        } else if let floating {
            floating.window.makeKeyAndOrderFront(nil)
        }
        MainWindowController.saveSession()
    }
}

// MARK: - JSON bar
// Shown under the tabs while the current tab holds JSON. Buttons send their actions to
// EditorApp, the same as the JSON menu.

final class JSONBarView: NSView {
    static let height: CGFloat = 30
    private let status = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        let badge = NSTextField(labelWithString: "JSON")
        badge.font = .systemFont(ofSize: 11, weight: .semibold)
        badge.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12)
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)

        func button(_ title: String, _ action: Selector, _ tip: String) -> NSButton {
            let b = NSButton(title: title, target: EditorApp.shared, action: action)
            b.bezelStyle = .push
            b.controlSize = .small
            b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            b.toolTip = tip
            return b
        }
        let stack = NSStackView(views: [
            badge, status,
            button("Beautify", #selector(EditorApp.beautifyJSON(_:)), "Re-indent the JSON (⌥⇧⌘F)"),
            button("Collapse All", #selector(EditorApp.collapseAllJSON(_:)), "Collapse every block below the top level (⌥⇧⌘←)"),
            button("Expand All", #selector(EditorApp.expandAllJSON(_:)), "Expand every block (⌥⇧⌘→)"),
            button("Validate", #selector(EditorApp.validateJSON(_:)), "Check the JSON and jump to any error (⌥⇧⌘J)"),
        ])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.setCustomSpacing(10, after: badge)
        stack.setCustomSpacing(12, after: status)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -0.5),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(for doc: Document) {
        if let issue = doc.jsonIssue {
            status.stringValue = "✕ Invalid — " + doc.describe(issue)
            status.textColor = .systemRed
        } else {
            status.stringValue = "✓ Valid JSON"
            status.textColor = .systemGreen
        }
        status.toolTip = status.stringValue
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.025).setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

// MARK: - Main window

final class MainWindowController: NSObject, NSWindowDelegate {
    /// Every open window. A window is added when it's created and removed by closeWindow().
    private(set) static var all: [MainWindowController] = []

    let window: NSWindow
    let tabBar: TabBarView
    private let jsonBar: JSONBarView
    private let editorHolder: NSView
    private(set) var docs: [Document] = []
    private(set) var current: Document?

    /// Without a frame, the window goes where the single window was before there could be several.
    init(frame: NSRect? = nil) {
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 800, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        let root = DropRootView(frame: window.contentRect(forFrameRect: window.frame))
        let h = root.bounds.height
        tabBar = TabBarView(frame: NSRect(x: 0, y: h - TabBarView.height, width: root.bounds.width, height: TabBarView.height))
        tabBar.autoresizingMask = [.width, .minYMargin]
        editorHolder = NSView(frame: NSRect(x: 0, y: 0, width: root.bounds.width, height: h - TabBarView.height))
        editorHolder.autoresizingMask = [.width, .height]
        jsonBar = JSONBarView(frame: NSRect(x: 0, y: h - TabBarView.height - JSONBarView.height,
                                            width: root.bounds.width, height: JSONBarView.height))
        jsonBar.autoresizingMask = [.width, .minYMargin]
        jsonBar.isHidden = true
        root.addSubview(editorHolder)
        root.addSubview(jsonBar)
        root.addSubview(tabBar)
        super.init()

        window.contentView = root
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 360, height: 240)
        window.delegate = self
        if let frame {
            // Skip a frame that's no longer on any screen (e.g. a display was unplugged).
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) { window.setFrame(frame, display: false) }
        } else {
            window.setFrameUsingName("PlainPadMainWindow")
        }
        tabBar.controller = self
        root.onDropFiles = { [weak self] in self?.open($0) }
        Self.all.append(self)
    }

    // MARK: Tabs

    func restore(_ saved: Store.SavedWindow) {
        for item in saved.docs { add(Document(id: item.id, text: item.text)) }
        if docs.isEmpty {
            newTab()
        } else {
            select(docs.first { $0.id == saved.selected } ?? docs[0])
        }
    }

    /// Takes a tab out of this window without discarding it: it's moving to another window.
    func detach(_ doc: Document) {
        guard let i = docs.firstIndex(where: { $0 === doc }) else { return }
        docs.remove(at: i)
        if doc === current {
            doc.scrollView.removeFromSuperview()
            current = nil
            if !docs.isEmpty { select(index: min(i, docs.count - 1)); return }
            updateJSONBar()
        }
        tabBar.sync()
        saveOrder()
    }

    /// Takes in a tab from another window and selects it.
    func attach(_ doc: Document, at index: Int) {
        add(doc, at: min(index, docs.count))
        select(doc)
    }

    private func add(_ doc: Document, at index: Int? = nil) {
        (doc.textView as? EditorTextView)?.onDropFiles = { [weak self] in self?.open($0) }
        doc.onChange = { [weak self, weak doc] in
            guard let self, let doc else { return }
            self.tabBar.updateTitles()
            if doc === self.current {
                self.window.title = doc.title
                self.updateJSONBar()
            }
        }
        docs.insert(doc, at: index ?? docs.count)
    }

    func newTab(text: String = "") {
        let doc = Document(id: UUID().uuidString, text: text)
        doc.saveNow()
        let index = current.flatMap { c in docs.firstIndex { $0 === c } }.map { $0 + 1 }
        add(doc, at: index)
        select(doc)
    }

    // MARK: Open files

    /// Opens each file's text in a new tab after the current one. The tab holds a copy: edits don't touch the original.
    func open(_ urls: [URL]) {
        var failed: [String] = []
        var index = current.flatMap { c in docs.firstIndex { $0 === c } }.map { $0 + 1 } ?? docs.count
        var last: Document?
        for url in urls {
            guard let text = readText(url) else { failed.append(url.lastPathComponent); continue }
            let doc = Document(id: UUID().uuidString, text: text)
            doc.saveNow()
            add(doc, at: index)
            index += 1
            last = doc
        }
        if let last { select(last) }
        if !failed.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = failed.count == 1 ? "Can’t open “\(failed[0])”" : "Can’t open \(failed.count) files"
            alert.informativeText = (failed.count == 1 ? "" : failed.joined(separator: ", ") + "\n\n")
                + "Only plain-text files can be opened."
            alert.beginSheetModal(for: window)
        }
    }

    /// Reads a file as text, or nil if it isn't readable text (a folder, an image, …).
    private func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var encoding = String.Encoding.utf8
        let hasNul = data.contains(0)
        if let text = try? String(contentsOf: url, usedEncoding: &encoding), encoding != .utf8 || !hasNul { return text }
        if hasNul { return nil }  // binary (NULs are only legitimate in UTF-16/32, detected above)
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
    }

    func select(_ doc: Document) {
        if current !== doc {
            current?.scrollView.removeFromSuperview()
            doc.scrollView.frame = editorHolder.bounds
            doc.scrollView.autoresizingMask = [.width, .height]
            editorHolder.addSubview(doc.scrollView)
            current = doc
        }
        window.title = doc.title
        window.makeFirstResponder(doc.textView)
        tabBar.sync()
        updateJSONBar()
        saveOrder()
    }

    // MARK: Zoom

    /// Moves the zoom one step bigger (+1) or smaller (-1), or back to 100% (0).
    func zoom(_ direction: Int) {
        let steps = Document.zoomSteps, z = Document.zoom
        let next: CGFloat?
        switch direction {
        case 0: next = 1
        case 1...: next = steps.first { $0 > z + 0.001 }
        default: next = steps.last { $0 < z - 0.001 }
        }
        guard let next, next != z else { NSSound.beep(); return }
        Document.zoom = next
        Self.all.forEach { $0.docs.forEach { $0.applyZoom() } }
    }

    // MARK: JSON

    func updateJSONBar() {
        let show = current?.isJSON == true
        if let current, show { jsonBar.update(for: current) }
        guard jsonBar.isHidden == show, let root = window.contentView else { return }
        jsonBar.isHidden = !show
        let top = root.bounds.height - TabBarView.height
        editorHolder.frame = NSRect(x: 0, y: 0, width: root.bounds.width, height: top - (show ? JSONBarView.height : 0))
    }

    func beautifyCurrent() {
        guard let doc = current, doc.isJSON else { return }
        if let issue = doc.beautify() { show(issue, in: doc, title: "Can’t beautify: the JSON has an error") }
    }

    func validateCurrent() {
        guard let doc = current, doc.isJSON else { return }
        doc.analyzeJSON()
        updateJSONBar()
        if let issue = doc.jsonIssue {
            show(issue, in: doc, title: "This isn’t valid JSON")
        } else {
            let alert = NSAlert()
            alert.messageText = "Valid JSON"
            alert.informativeText = "No problems found."
            alert.beginSheetModal(for: window)
        }
    }

    /// Selects the character where the problem is, then explains it.
    private func show(_ issue: JSONTools.Issue, in doc: Document, title: String) {
        let tv = doc.textView
        let length = (tv.string as NSString).length
        let r = NSRange(location: min(issue.index, length), length: issue.index < length ? 1 : 0)
        tv.setSelectedRange(r)
        tv.scrollRangeToVisible(r)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = doc.describe(issue)
        alert.beginSheetModal(for: window) { [weak self] _ in
            self?.window.makeFirstResponder(tv)
            tv.showFindIndicator(for: r)
        }
    }

    func select(index: Int) {
        guard docs.indices.contains(index) else { return }
        select(docs[index])
    }

    func selectRelative(_ offset: Int) {
        guard let c = current, let i = docs.firstIndex(where: { $0 === c }), !docs.isEmpty else { return }
        select(index: (i + offset + docs.count) % docs.count)
    }

    func moveDocument(from: Int, to: Int) {
        let doc = docs.remove(at: from)
        docs.insert(doc, at: to)
        saveOrder()
    }

    /// Closing a tab discards its text, so ask first unless it's empty.
    func requestClose(_ doc: Document) {
        if doc.isEmpty { close(doc); return }
        select(doc)
        let alert = NSAlert()
        alert.messageText = "Close “\(doc.title)”?"
        alert.informativeText = "This document's text will be discarded."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Save a Copy…")
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: self?.close(doc)
            case .alertThirdButtonReturn: self?.saveCopy(of: doc)
            default: break
            }
        }
    }

    private func close(_ doc: Document) {
        guard let i = docs.firstIndex(where: { $0 === doc }) else { return }
        doc.discard()
        docs.remove(at: i)
        if doc === current {
            doc.scrollView.removeFromSuperview()
            current = nil
            if docs.isEmpty {
                // Closing the last tab closes its window, unless it's the only window.
                if Self.all.count > 1 { closeWindow(); Self.saveSession() } else { newTab() }
                return
            }
            select(index: min(i, docs.count - 1))
        } else {
            tabBar.sync()
            saveOrder()
        }
    }

    func closeCurrent() {
        if let current { requestClose(current) }
    }

    func saveOrder() { Self.saveSession() }

    /// Saves every window's tabs, front window first.
    static func saveSession() {
        let front = NSApp.orderedWindows.compactMap { w in all.first { $0.window === w } }
        let rest = all.filter { c in !front.contains { $0 === c } }  // e.g. minimized
        Store.shared.saveSession((front + rest).filter { !$0.docs.isEmpty }.map {
            .init(ids: $0.docs.map(\.id), selected: $0.current?.id, frame: NSStringFromRect($0.window.frame))
        })
    }

    static func saveAll() {
        all.forEach { $0.docs.forEach { $0.saveNow() } }
        saveSession()
    }

    // MARK: Save a copy to a real file

    func saveCopy(of doc: Document) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [doc.isJSON ? .json : .plainText]
        panel.nameFieldStringValue = doc.title.replacingOccurrences(of: "/", with: "-") + (doc.isJSON ? ".json" : ".txt")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try doc.textView.string.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSAlert(error: error).beginSheetModal(for: self.window)
            }
        }
    }

    // MARK: Window

    /// The red close button on the only window hides it (the app keeps running in the menu bar).
    /// All its tabs are kept and come back the next time the editor is opened.
    /// With other windows open it closes just this one, and its tabs move into the frontmost of the others.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let others = NSApp.orderedWindows.compactMap { w in Self.all.first { $0.window === w && $0 !== self } }
        guard let target = others.first ?? Self.all.first(where: { $0 !== self }) else {
            EditorApp.shared.hideAllWindows()
            return false
        }
        guard window.attachedSheet == nil else { NSSound.beep(); return false }
        current?.scrollView.removeFromSuperview()
        let moving = docs
        docs = []
        current = nil
        moving.forEach { target.add($0) }
        target.tabBar.sync()
        closeWindow()
        Self.saveSession()
        return false
    }

    /// Closes the window without touching any documents: it has none left, or they've moved elsewhere.
    func closeWindow() {
        Self.all.removeAll { $0 === self }
        window.orderOut(nil)
        EditorApp.shared.updateActivationPolicy()
        // The actual close waits for the next pass of the run loop: this can be called from inside the window's own event handling.
        DispatchQueue.main.async { self.window.close() }
    }
}

