// Capture — screenshot + annotate (formerly CaptureMe).
//
// The capture hotkey freezes every display; drag a rectangle (it may span displays) to capture it.
// The capture is copied to the clipboard immediately. You can then annotate it
// with the pen, arrows or text (toolbar, or P / A / T); every finished annotation
// re-copies the image. Return/Enter or Escape dismisses the overlay. Cmd+Z undoes.
// Save (Cmd+S) closes the overlay and asks where to save the image as a PNG.
// When the overlay closes, the final image is handed to onEnd (it goes into clipboard history).

import Cocoa
import Carbon.HIToolbox
import ScreenCaptureKit

// MARK: - Clipboard

func copyToClipboard(_ image: CGImage, pointScale: CGFloat) {
    let rep = NSBitmapImageRep(cgImage: image)
    // Record point size so Retina captures paste at their on-screen size.
    rep.size = NSSize(width: CGFloat(image.width) / pointScale,
                      height: CGFloat(image.height) / pointScale)
    let pb = NSPasteboard.general
    pb.clearContents()
    if let png = rep.representation(using: .png, properties: [:]) {
        pb.setData(png, forType: .png)
    }
    if let tiff = rep.tiffRepresentation {
        pb.setData(tiff, forType: .tiff)
    }
}

// MARK: - Overlay window / view
// One borderless overlay per display shows that display's frozen screenshot. The selection and the
// pen strokes belong to the CaptureSession, in global screen coordinates (points, origin at the
// bottom-left of the main display), so a rectangle can span several displays. Each overlay draws
// the part of the selection that falls on its display.

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class OverlayView: NSView {
    let screenshot: CGImage
    /// This display's frame in global coordinates.
    let screenFrame: NSRect
    private weak var session: CaptureSession?

    init(screenFrame: NSRect, screenshot: CGImage, session: CaptureSession) {
        self.screenshot = screenshot
        self.screenFrame = screenFrame
        self.session = session
        super.init(frame: NSRect(origin: .zero, size: screenFrame.size))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: session?.tool == .text && session?.isSelecting == false ? .iBeam : .crosshair)
    }

    /// Screenshot pixels per point on this display.
    var pixelScale: CGFloat { CGFloat(screenshot.width) / screenFrame.width }

    private func toLocal(_ r: NSRect) -> NSRect { r.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY) }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let session else { return }
        ctx.interpolationQuality = .high
        ctx.draw(screenshot, in: bounds)

        // Dim everything except the selection.
        let dim = NSBezierPath(rect: bounds)
        let sel = session.selection.map(toLocal)
        if let sel, sel.width > 0, sel.height > 0 {
            dim.append(NSBezierPath(rect: sel))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.35).setFill()
        dim.fill()

        guard let sel, sel.width > 0, sel.height > 0, sel.intersects(bounds) else { return }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: sel).addClip()
        let transform = NSAffineTransform()
        transform.translateX(by: -screenFrame.minX, yBy: -screenFrame.minY)
        transform.concat()
        session.drawAnnotations()
        NSGraphicsContext.restoreGraphicsState()

        let border = NSBezierPath(rect: sel.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        NSColor.white.withAlphaComponent(0.9).setStroke()
        border.stroke()

        // The size label sits by the selection's bottom-left corner, on whichever display has that corner.
        if session.isSelecting, bounds.contains(NSPoint(x: sel.minX, y: sel.minY)) {
            drawSizeLabel(for: sel, pixels: session.pixelSize)
        }
    }

    private func drawSizeLabel(for sel: NSRect, pixels: (w: Int, h: Int)) {
        let text = "\(pixels.w) × \(pixels.h)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        var origin = NSPoint(x: sel.minX, y: sel.minY - size.height - 8)
        if origin.y < 2 { origin.y = sel.minY + 4 }
        let bg = NSRect(x: origin.x, y: origin.y, width: size.width + 10, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 4, yRadius: 4).fill()
        text.draw(at: NSPoint(x: origin.x + 5, y: origin.y + 2), withAttributes: attrs)
    }

    // MARK: Mouse
    // A drag keeps going to the window it started in, even after the pointer moves onto another
    // display, so converting the event to global coordinates is all a cross-display drag needs.

    private func globalPoint(_ event: NSEvent) -> NSPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

    override func mouseDown(with event: NSEvent) { session?.mouseDown(at: globalPoint(event)) }
    override func mouseDragged(with event: NSEvent) { session?.mouseDragged(to: globalPoint(event)) }
    override func mouseUp(with event: NSEvent) { session?.mouseUp() }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if session?.handleKey(event) != true { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { session?.end() }
}

// MARK: - Capture session (one overlay per display, one selection across all of them)

final class CaptureSession: NSObject, NSTextFieldDelegate {
    private enum Mode { case selecting, drawing }
    enum Tool: Int { case pen, arrow, text }

    /// Annotations, in global coordinates, in the order they were made (⌘Z removes the last).
    private enum Annotation {
        case stroke(NSBezierPath)
        case arrow(from: NSPoint, to: NSPoint)
        case text(String, at: NSPoint)
    }

    private var views: [OverlayView] = []
    private var mode: Mode = .selecting
    private var dragStart: NSPoint?
    /// The selection, in global coordinates.
    private(set) var selection: NSRect?

    private(set) var tool: Tool = .pen
    private var annotations: [Annotation] = []
    private var currentStroke: NSBezierPath?
    private var arrowStart: NSPoint?
    private var arrowEnd: NSPoint?
    private var textField: NSTextField?
    private var toolbar: CaptureToolbar?
    private let penColor = NSColor.systemRed
    private let penWidth: CGFloat = 3
    private static let textFont = NSFont.systemFont(ofSize: 22, weight: .bold)

    typealias Result = (image: CGImage, pointScale: CGFloat)
    /// Called when the overlay closes, with the final image (nil if nothing was selected)
    /// and whether the user asked to save it to a file.
    private let onEnd: (Result?, _ save: Bool) -> Void
    private var saveRequested = false
    /// The most recent image copied to the clipboard (with annotations), or nil if nothing was selected.
    private var lastResult: (image: CGImage, pointScale: CGFloat)?
    private var outsideClickMonitor: Any?
    private var ended = false

    init(onEnd: @escaping (Result?, _ save: Bool) -> Void) {
        self.onEnd = onEnd
        super.init()
    }

    var isSelecting: Bool { mode == .selecting }

    func show(_ captures: [(NSScreen, CGImage)]) {
        let mouse = NSEvent.mouseLocation
        var keyWindow: NSWindow?
        for (screen, image) in captures {
            let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless,
                                  backing: .buffered, defer: false)
            w.setFrame(screen.frame, display: false)
            w.level = .screenSaver
            w.isOpaque = true
            w.backgroundColor = .black
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let view = OverlayView(screenFrame: screen.frame, screenshot: image, session: self)
            w.contentView = view
            w.orderFrontRegardless()
            views.append(view)
            if screen.frame.contains(mouse) { keyWindow = w }
        }
        NSApp.activate(ignoringOtherApps: true)
        let key = keyWindow ?? views.first?.window
        key?.makeKeyAndOrderFront(nil)
        key?.makeFirstResponder(key?.contentView)
    }

    private func redraw() { views.forEach { $0.needsDisplay = true } }

    /// The displays the selection covers.
    private var coveredViews: [OverlayView] {
        guard let sel = selection else { return [] }
        return views.filter { $0.screenFrame.intersects(sel) }
    }

    /// Pixels per point of the result: the sharpest display the selection covers.
    private var outputScale: CGFloat { coveredViews.map(\.pixelScale).max() ?? views.first?.pixelScale ?? 1 }

    var pixelSize: (w: Int, h: Int) {
        guard let sel = selection else { return (0, 0) }
        let s = outputScale
        return (Int((sel.width * s).rounded()), Int((sel.height * s).rounded()))
    }

    // MARK: Annotations

    /// Draws every annotation (and the one in progress) into the current graphics context,
    /// which must be set up in global coordinates.
    func drawAnnotations() {
        for a in annotations { draw(a) }
        if let currentStroke { draw(.stroke(currentStroke)) }
        if let arrowStart, let arrowEnd { draw(.arrow(from: arrowStart, to: arrowEnd)) }
    }

    private func draw(_ a: Annotation) {
        switch a {
        case .stroke(let path):
            penColor.setStroke()
            path.stroke()
        case .arrow(let from, let to):
            let (shaft, head) = Self.arrowPaths(from: from, to: to, width: penWidth)
            penColor.setStroke()
            shaft.stroke()
            penColor.setFill()
            head.fill()
        case .text(let string, let at):
            // A white outline under the red fill keeps text readable on any background.
            let outline: [NSAttributedString.Key: Any] = [
                .font: Self.textFont, .strokeColor: NSColor.white, .strokeWidth: 14,
            ]
            (string as NSString).draw(at: at, withAttributes: outline)
            (string as NSString).draw(at: at, withAttributes: [.font: Self.textFont, .foregroundColor: penColor])
        }
    }

    /// An arrow from `a` to `b`: a round-capped shaft and a filled triangular head at `b`.
    private static func arrowPaths(from a: NSPoint, to b: NSPoint, width: CGFloat) -> (NSBezierPath, NSBezierPath) {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = max(hypot(dx, dy), 0.001)
        let ux = dx / length, uy = dy / length          // along the arrow
        let px = -uy, py = ux                           // perpendicular
        let headLength = min(max(width * 5, 14), length * 0.6)
        let headHalfWidth = headLength * 0.45
        let base = NSPoint(x: b.x - ux * headLength, y: b.y - uy * headLength)

        let shaft = NSBezierPath()
        shaft.lineWidth = width
        shaft.lineCapStyle = .round
        shaft.move(to: a)
        shaft.line(to: NSPoint(x: base.x + ux * 2, y: base.y + uy * 2)) // tuck under the head

        let head = NSBezierPath()
        head.move(to: b)
        head.line(to: NSPoint(x: base.x + px * headHalfWidth, y: base.y + py * headHalfWidth))
        head.line(to: NSPoint(x: base.x - px * headHalfWidth, y: base.y - py * headHalfWidth))
        head.close()
        return (shaft, head)
    }

    /// Finishes the capture and asks where to save it (the Save dialog can't show above the overlay).
    func saveAndEnd() {
        commitText()
        saveRequested = true
        end()
    }

    func select(_ newTool: Tool) {
        commitText()
        tool = newTool
        toolbar?.selected = newTool
        for v in views { v.window?.invalidateCursorRects(for: v) }
    }

    private func annotationAdded(_ a: Annotation) {
        annotations.append(a)
        copyResult()
        redraw()
    }

    // MARK: Text

    private func beginText(at p: NSPoint) {
        guard let view = views.first(where: { $0.screenFrame.contains(p) }) else { return }
        let field = NSTextField(string: "")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Self.textFont
        field.textColor = penColor
        field.placeholderString = "Text"
        field.delegate = self
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        // The click marks the left end of the text's line, roughly centered on it vertically.
        let height = ceil(Self.textFont.boundingRectForFont.height)
        field.frame = NSRect(x: p.x - view.screenFrame.minX - 2, y: p.y - view.screenFrame.minY - height / 2,
                             width: 60, height: height)
        view.addSubview(field)
        textField = field
        view.window?.makeKeyAndOrderFront(nil)
        view.window?.makeFirstResponder(field)
    }

    /// Turns the text being typed into an annotation (or drops it if empty).
    private func commitText() {
        guard let field = textField, let view = field.superview as? OverlayView else { return }
        textField = nil // first, so the end-editing callback below doesn't commit twice
        let string = field.stringValue
        let origin = NSPoint(x: field.frame.minX + 2 + view.screenFrame.minX,
                             y: field.frame.minY + view.screenFrame.minY)
        field.removeFromSuperview()
        view.window?.makeFirstResponder(view)
        if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            annotationAdded(.text(string, at: origin))
        }
    }

    private func cancelText() {
        guard let field = textField else { return }
        textField = nil
        let view = field.superview
        field.removeFromSuperview()
        view?.window?.makeFirstResponder(view)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = textField else { return }
        let width = (field.stringValue as NSString).size(withAttributes: [.font: Self.textFont]).width
        field.frame.size.width = max(60, ceil(width) + 12)
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitText() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commitText()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelText() // Esc drops this text, not the whole capture
            return true
        default:
            return false
        }
    }

    // MARK: Mouse (global coordinates)

    func mouseDown(at p: NSPoint) {
        switch mode {
        case .selecting:
            dragStart = p
            selection = NSRect(origin: p, size: .zero)
        case .drawing:
            let wasTyping = textField != nil
            commitText()
            // Clicking outside the capture closes the editor.
            guard let sel = selection, sel.contains(p) else { end(); return }
            switch tool {
            case .pen:
                let path = NSBezierPath()
                path.lineWidth = penWidth
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.move(to: p)
                path.line(to: p) // so a single click leaves a dot
                currentStroke = path
            case .arrow:
                arrowStart = p
                arrowEnd = p
            case .text:
                // A click while typing just finishes that text; the next click starts a new one.
                if !wasTyping { beginText(at: p) }
            }
        }
        redraw()
    }

    func mouseDragged(to p: NSPoint) {
        switch mode {
        case .selecting:
            guard let start = dragStart else { return }
            selection = NSRect(x: min(start.x, p.x), y: min(start.y, p.y),
                               width: abs(p.x - start.x), height: abs(p.y - start.y))
        case .drawing:
            currentStroke?.line(to: p)
            if arrowStart != nil { arrowEnd = p }
        }
        redraw()
    }

    func mouseUp() {
        switch mode {
        case .selecting:
            dragStart = nil
            guard let sel = selection, sel.width >= 3, sel.height >= 3 else {
                selection = nil
                redraw()
                return
            }
            selection = alignedToPixels(sel)
            mode = .drawing
            copyResult()
            selectionCompleted()
        case .drawing:
            if let stroke = currentStroke {
                currentStroke = nil
                annotationAdded(.stroke(stroke))
            }
            if let start = arrowStart, let end = arrowEnd {
                arrowStart = nil
                arrowEnd = nil
                if hypot(end.x - start.x, end.y - start.y) >= 6 { annotationAdded(.arrow(from: start, to: end)) }
            }
        }
        redraw()
    }

    func handleKey(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case kVK_Escape, kVK_Return, kVK_ANSI_KeypadEnter:
            end()
        case kVK_ANSI_Z where event.modifierFlags.contains(.command):
            if mode == .drawing, !annotations.isEmpty {
                annotations.removeLast()
                copyResult()
                redraw()
            }
        case kVK_ANSI_S where mode == .drawing && event.modifierFlags.contains(.command):
            saveAndEnd()
        case kVK_ANSI_P where mode == .drawing: select(.pen)
        case kVK_ANSI_A where mode == .drawing: select(.arrow)
        case kVK_ANSI_T where mode == .drawing: select(.text)
        default:
            return false
        }
        return true
    }

    /// Once a rectangle is chosen, keep only the displays it covers; the others go back to normal.
    private func selectionCompleted() {
        let keep = coveredViews
        for v in views where !keep.contains(where: { $0 === v }) { v.window?.orderOut(nil) }
        views = keep
        let mouse = NSEvent.mouseLocation
        let key = (keep.first { $0.screenFrame.contains(mouse) } ?? keep.first)?.window
        key?.makeKeyAndOrderFront(nil)
        key?.makeFirstResponder(key?.contentView)
        showToolbar()
        for v in views { v.window?.invalidateCursorRects(for: v) }
        // The other displays are live again, so clicks there go to other apps and never reach
        // our overlays. A global monitor sees them (mouse monitors need no Accessibility permission)
        // and closes the editor, just like clicking outside the capture on a covered display.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.end() }
        }
    }

    /// Puts the tool picker just below the selection (above it, or inside it, if there's no room).
    private func showToolbar() {
        guard let sel = selection else { return }
        let anchor = NSPoint(x: sel.midX, y: sel.minY)
        guard let view = views.first(where: { $0.screenFrame.contains(anchor) })
                ?? views.first(where: { $0.screenFrame.contains(NSPoint(x: sel.midX, y: sel.maxY - 1)) })
                ?? views.first else { return }
        let bar = CaptureToolbar(onSelect: { [weak self] tool in self?.select(tool) },
                                 onSave: { [weak self] in self?.saveAndEnd() })
        bar.selected = tool
        let size = bar.fittingSize
        let local = sel.offsetBy(dx: -view.screenFrame.minX, dy: -view.screenFrame.minY)
        var y = local.minY - size.height - 8
        if y < 4 { y = local.maxY + 8 }
        if y + size.height > view.bounds.maxY - 4 { y = local.minY + 8 }
        let x = min(max(local.midX - size.width / 2, 4), view.bounds.maxX - size.width - 4)
        bar.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        view.addSubview(bar)
        toolbar = bar
    }

    func end() {
        guard !ended else { return }
        ended = true
        commitText()
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        for v in views { v.window?.orderOut(nil) }
        views.removeAll()
        onEnd(lastResult, saveRequested && lastResult != nil)
    }

    // MARK: Rendering the result

    /// Snaps the selection to the output's pixel grid. Display frames are whole points, so this
    /// lines up with every covered display's pixels too (at the same or a lower scale).
    private func alignedToPixels(_ r: NSRect) -> NSRect {
        let s = outputScale
        let x0 = (r.minX * s).rounded(.down) / s
        let y0 = (r.minY * s).rounded(.down) / s
        let x1 = (r.maxX * s).rounded(.up) / s
        let y1 = (r.maxY * s).rounded(.up) / s
        return NSRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    private func copyResult() {
        guard let image = renderSelection() else { return }
        let scale = outputScale
        copyToClipboard(image, pointScale: scale)
        lastResult = (image, scale)
    }

    /// Stitches the selected part of each covered display into one image at the output scale,
    /// then draws the annotations on top. Areas of the selection that fall between displays
    /// (when monitors aren't lined up) stay transparent.
    private func renderSelection() -> CGImage? {
        guard let sel = selection else { return nil }
        let s = outputScale
        let w = Int((sel.width * s).rounded()), h = Int((sel.height * s).rounded())
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: coveredViews.first?.screenshot.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high

        for view in coveredViews {
            let part = sel.intersection(view.screenFrame)
            guard !part.isEmpty else { continue }
            let ps = view.pixelScale
            // CGImage pixel space has its origin at the top-left of the display.
            let src = CGRect(x: (part.minX - view.screenFrame.minX) * ps,
                             y: (view.screenFrame.maxY - part.maxY) * ps,
                             width: part.width * ps, height: part.height * ps).integral
            guard let piece = view.screenshot.cropping(to: src) else { continue }
            // CGContext space has its origin at the bottom-left, like global coordinates.
            let dst = CGRect(x: (part.minX - sel.minX) * s, y: (part.minY - sel.minY) * s,
                             width: part.width * s, height: part.height * s)
            ctx.draw(piece, in: dst)
        }

        if !annotations.isEmpty {
            ctx.scaleBy(x: s, y: s)
            ctx.translateBy(x: -sel.minX, y: -sel.minY)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            for a in annotations { draw(a) }
            NSGraphicsContext.restoreGraphicsState()
        }
        return ctx.makeImage()
    }
}

// MARK: - Toolbar

/// Pen / Arrow / Text picker shown next to the selection while annotating.
final class CaptureToolbar: NSVisualEffectView {
    private let control: NSSegmentedControl
    private let saveButton: NSButton
    private let onSelect: (CaptureSession.Tool) -> Void
    private let onSave: () -> Void

    var selected: CaptureSession.Tool = .pen {
        didSet { control.selectedSegment = selected.rawValue }
    }

    init(onSelect: @escaping (CaptureSession.Tool) -> Void, onSave: @escaping () -> Void) {
        self.onSelect = onSelect
        self.onSave = onSave
        saveButton = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.down",
                                             accessibilityDescription: "Save to File")!,
                              target: nil, action: nil)
        let symbols: [(String, String)] = [("scribble", "Pen (P)"), ("arrow.up.right", "Arrow (A)"), ("textformat", "Text (T)")]
        let images = symbols.map { NSImage(systemSymbolName: $0.0, accessibilityDescription: $0.1)! }
        control = NSSegmentedControl(images: images, trackingMode: .selectOne, target: nil, action: nil)
        super.init(frame: .zero)
        for (i, s) in symbols.enumerated() { control.setToolTip(s.1, forSegment: i) }
        control.target = self
        control.action = #selector(changed)
        control.selectedSegment = 0
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        appearance = NSAppearance(named: .darkAqua)
        saveButton.bezelStyle = .texturedRounded
        saveButton.toolTip = "Save to File… (⌘S)"
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        let row = NSStackView(views: [control, saveButton])
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func saveClicked() { onSave() }

    @objc private func changed() {
        if let tool = CaptureSession.Tool(rawValue: control.selectedSegment) { onSelect(tool) }
    }
}

// MARK: - Screen capture

enum CaptureError: Error { case noDisplays }

func captureAllScreens() async throws -> [(NSScreen, CGImage)] {
    let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                      onScreenWindowsOnly: true)
    var results: [(NSScreen, CGImage)] = []
    for screen in NSScreen.screens {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let display = content.displays.first(where: { $0.displayID == number.uint32Value })
        else { continue }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        config.width = Int(screen.frame.width * scale)
        config.height = Int(screen.frame.height * scale)
        config.showsCursor = false
        config.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                               configuration: config)
        results.append((screen, image))
    }
    if results.isEmpty { throw CaptureError.noDisplays }
    return results
}

