// The terminal view (the Windows client's terminal window): paints the emulator's grid in a monospaced font with the
// xterm colours, the cursor and the selection, and turns keys, the mouse, the scroll wheel and the clipboard into what the
// program reads.
import AppKit
import SwiftUI

final class TerminalCanvas: NSView, NSTextInputClient, NSMenuItemValidation {
    static let pad: CGFloat = 6
    private weak var session: TerminalSession?
    private let scroller = NSScroller()
    private var fonts: [NSFont] = []          // regular, bold, italic, bold italic
    private(set) var cellWidth: CGFloat = 8
    private(set) var cellHeight: CGFloat = 16
    private var marked = ""                   // text an input method is composing
    private var wheelRemainder: CGFloat = 0
    private var keyObservers: [NSObjectProtocol] = []

    @MainActor init(session: TerminalSession) {
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        makeFonts()
        scroller.scrollerStyle = .legacy
        scroller.controlSize = .regular
        scroller.target = self
        scroller.action = #selector(scrolled(_:))
        scroller.isEnabled = false
        addSubview(scroller)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    var isFocused: Bool { window?.isKeyWindow == true && window?.firstResponder === self }

    private func makeFonts() {
        // 14px, as the Windows client's Cascadia Mono.
        let regular = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)
        let fm = NSFontManager.shared
        fonts = [regular, bold, fm.convert(regular, toHaveTrait: .italicFontMask), fm.convert(bold, toHaveTrait: .italicFontMask)]
        cellWidth = ("M" as NSString).size(withAttributes: [.font: regular]).width
        cellHeight = ceil(regular.ascender - regular.descender + regular.leading) + 1
    }

    private static var scrollerWidth: CGFloat { NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) }

    // MARK: - Colours

    private var dark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    private var accent: UInt32 { dark ? 0xD97757 : 0xC96442 }
    private static func color(_ rgb: UInt32) -> NSColor { NSColor(hex: rgb) }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    // MARK: - Size

    override func layout() {
        super.layout()
        let w = Self.scrollerWidth
        scroller.frame = NSRect(x: bounds.width - w, y: 0, width: w, height: bounds.height)
        resizeToView()
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    @MainActor private func resizeToView() {
        guard let s = session, bounds.width > 0, bounds.height > 0 else { return }
        let size = TerminalView.gridSize(width: bounds.width, height: bounds.height, cellWidth: cellWidth, cellHeight: cellHeight,
                                         padding: Self.pad, scrollbar: Self.scrollerWidth)
        if size.cols != s.vt.cols || size.rows != s.vt.rows {
            s.resize(cols: size.cols, rows: size.rows)
            updateScroller()
            needsDisplay = true
        }
    }

    /// New output, a scroll or a selection change: paint again.
    @MainActor func contentChanged() {
        updateScroller()
        needsDisplay = true
    }

    @MainActor private func updateScroller() {
        guard let s = session else { return }
        let sb = s.vt.scrollbackCount, rows = s.vt.rows
        scroller.isEnabled = sb > 0
        scroller.knobProportion = CGFloat(rows) / CGFloat(sb + rows)
        scroller.doubleValue = sb > 0 ? Double(sb - s.view.offset) / Double(sb) : 1
    }

    @MainActor private func scrollView(to offset: Int) {
        guard let s = session else { return }
        if s.view.scroll(to: offset, vt: s.vt) { contentChanged() }
    }

    @objc private func scrolled(_ sender: NSScroller) {
        MainActor.assumeIsolated {
            guard let s = session else { return }
            let sb = s.vt.scrollbackCount, rows = s.vt.rows
            switch sender.hitPart {
            case .decrementLine: scrollView(to: s.view.offset + 1)
            case .incrementLine: scrollView(to: s.view.offset - 1)
            case .decrementPage: scrollView(to: s.view.offset + rows)
            case .incrementPage: scrollView(to: s.view.offset - rows)
            case .knob, .knobSlot: scrollView(to: sb - Int((sender.doubleValue * Double(sb)).rounded()))
            default: break
            }
        }
    }

    // MARK: - Painting

    override func draw(_ dirtyRect: NSRect) {
        MainActor.assumeIsolated { paint() }
    }

    @MainActor private func paint() {
        let dark = self.dark
        let background = TerminalPalette.background(dark: dark), foreground = TerminalPalette.foreground(dark: dark)
        Self.color(background).setFill()
        bounds.fill()
        guard let s = session, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let vt = s.vt, view = s.view
        let focused = isFocused
        let cursor = vt.cursor
        let showCursor = cursor.visible && view.offset == 0 && s.running
        let selBG = TerminalPalette.blend(accent, background, 0.35), selFG = foreground
        let pad = Self.pad, cw = cellWidth, ch = cellHeight
        let ascent = fonts[0].ascender
        let textRight = bounds.width - Self.scrollerWidth
        ctx.saveGState()
        ctx.clip(to: NSRect(x: 0, y: 0, width: textRight, height: bounds.height))
        defer { ctx.restoreGState() }

        struct Run { var x: Int; var cells: Int; var text: String; var fg: UInt32; var bg: UInt32; var attr: VTAttributes }
        func flush(_ r: Run, _ y: CGFloat) {
            let box = NSRect(x: pad + CGFloat(r.x) * cw, y: y, width: CGFloat(r.cells) * cw, height: ch)
            if r.bg != background { Self.color(r.bg).setFill(); box.fill() }
            let font = fonts[(r.attr.contains(.bold) ? 1 : 0) | (r.attr.contains(.italic) ? 2 : 0)]
            let fg = Self.color(r.fg)
            if !r.text.trimmingCharacters(in: .whitespaces).isEmpty {
                (r.text as NSString).draw(at: NSPoint(x: box.minX, y: y + (ch - 1 - (font.ascender - font.descender)) / 2 + (font.ascender - ascent)),
                                          withAttributes: [.font: font, .foregroundColor: fg, .ligature: 0])
            }
            if r.attr.contains(.underline) || r.attr.contains(.strike) {
                fg.setFill()
                if r.attr.contains(.underline) { NSRect(x: box.minX, y: box.maxY - 2, width: box.width, height: 1).fill() }
                if r.attr.contains(.strike) { NSRect(x: box.minX, y: floor(box.midY), width: box.width, height: 1).fill() }
            }
        }

        for r in 0..<vt.rows {
            let y = view.lineIndex(row: r)
            let line = vt.line(y)
            let top = pad + CGFloat(r) * ch
            var run: Run?
            var x = 0
            while x < vt.cols {
                let c = line.flatMap { x < $0.count ? $0[x] : nil } ?? .blank
                if c.attr.contains(.wideTail) { x += 1; continue }
                let wide = c.attr.contains(.wide) && x + 1 < vt.cols
                let span = wide ? 2 : 1
                var (fg, bg) = TerminalPalette.colors(of: c, dark: dark)
                if view.isSelected(vt: vt, line: y, col: x) { bg = selBG; fg = selFG }
                if showCursor && focused && y == cursor.y && x == cursor.x { bg = accent; fg = background }
                let attr = c.attr.intersection([.bold, .italic, .underline, .strike])
                let scalar = c.ch == 0 ? 0x20 : c.ch
                // Characters the font may not hold at the cell's width are painted one by one, each at its own cell.
                let alone = wide || scalar >= 0x2500
                let text = String(c.character)
                if let cur = run, !alone, cur.fg == fg, cur.bg == bg, cur.attr == attr, cur.x + cur.cells == x {
                    run!.cells += span; run!.text += text
                } else {
                    if let cur = run { flush(cur, top) }
                    run = Run(x: x, cells: span, text: text, fg: fg, bg: bg, attr: attr)
                    if alone { flush(run!, top); run = nil }
                }
                x += span
            }
            if let cur = run { flush(cur, top) }
        }
        // Unfocused, the cursor is an outline.
        if showCursor && !focused && cursor.y < vt.rows {
            let rect = NSRect(x: pad + CGFloat(cursor.x) * cw, y: pad + CGFloat(cursor.y) * ch, width: cw, height: ch)
            Self.color(accent).setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.stroke()
        }
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        MainActor.assumeIsolated { session?.reportFocus(); needsDisplay = true }
        return ok
    }
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.session?.reportFocus(); self?.needsDisplay = true } }
        return ok
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyObservers.forEach { NotificationCenter.default.removeObserver($0) }
        keyObservers = []
        guard let window else { return }
        // The app going to the background is losing focus too, as on Windows.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.window?.firstResponder === self else { return }
                    self.session?.reportFocus()
                    self.needsDisplay = true
                }
            })
        }
        needsLayout = true
    }
    deinit { keyObservers.forEach { NotificationCenter.default.removeObserver($0) } }

    override func resetCursorRects() {
        addCursorRect(NSRect(x: 0, y: 0, width: max(0, bounds.width - Self.scrollerWidth), height: bounds.height), cursor: .iBeam)
    }

    // MARK: - The clipboard

    @MainActor private var selectionText: String? { session.flatMap { $0.view.selectionText(vt: $0.vt) } }

    @MainActor private func copySelection() {
        if let text = selectionText, !text.isEmpty { Clipboard.copy(text) }
    }
    @MainActor private func pasteClipboard() {
        guard let s = session, s.running, let text = NSPasteboard.general.string(forType: .string) else { return }
        s.view.offset = 0
        contentChanged()
        s.write(TerminalInput.paste(text, bracketed: s.vt.bracketedPaste))
    }
    @MainActor private func selectEverything() {
        guard let s = session else { return }
        s.view.selectAll(vt: s.vt)
        needsDisplay = true
    }
    @MainActor private func clearScrollback() {
        guard let s = session else { return }
        s.vt.clearScrollback()
        s.view.offset = 0
        s.view.clearSelection()
        contentChanged()
    }

    @objc func copy(_ sender: Any?) { MainActor.assumeIsolated { copySelection() } }
    @objc func paste(_ sender: Any?) { MainActor.assumeIsolated { pasteClipboard() } }
    @objc override func selectAll(_ sender: Any?) { MainActor.assumeIsolated { selectEverything() } }
    @objc private func clearScrollbackItem(_ sender: Any?) { MainActor.assumeIsolated { clearScrollback() } }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        MainActor.assumeIsolated {
            switch item.action {
            case #selector(copy(_:)): return !(selectionText ?? "").isEmpty
            case #selector(paste(_:)): return session?.running == true && NSPasteboard.general.string(forType: .string) != nil
            case #selector(clearScrollbackItem(_:)): return (session?.vt.scrollbackCount ?? 0) > 0
            default: return true
            }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "c").target = self
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "v").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select all", action: #selector(selectAll(_:)), keyEquivalent: "a").target = self
        menu.addItem(withTitle: "Clear scrollback", action: #selector(clearScrollbackItem(_:)), keyEquivalent: "").target = self
        return menu
    }

    // MARK: - Keys

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command {
            switch event.charactersIgnoringModifiers {
            case "c": copy(nil); return true
            case "v": paste(nil); return true
            case "a": selectAll(nil); return true
            default: break
            }
        }
        // Ctrl with a key is the terminal's, not a menu's.
        if mods.contains(.control) && !mods.contains(.command) { keyDown(with: event); return true }
        return super.performKeyEquivalent(with: event)
    }

    private static func termKey(_ keyCode: UInt16) -> TermKey? {
        switch keyCode {
        case 126: return .up
        case 125: return .down
        case 124: return .right
        case 123: return .left
        case 115: return .home
        case 119: return .end
        case 114: return .insert
        case 117: return .delete
        case 116: return .pageUp
        case 121: return .pageDown
        case 122: return .function(1)
        case 120: return .function(2)
        case 99: return .function(3)
        case 118: return .function(4)
        case 96: return .function(5)
        case 97: return .function(6)
        case 98: return .function(7)
        case 100: return .function(8)
        case 101: return .function(9)
        case 109: return .function(10)
        case 103: return .function(11)
        case 111: return .function(12)
        case 51: return .backspace
        case 48: return .tab
        case 36, 76: return .enter
        case 53: return .escape
        case 49: return .space
        default: return nil
        }
    }

    override func keyDown(with event: NSEvent) {
        MainActor.assumeIsolated { key(event) }
    }

    @MainActor private func key(_ event: NSEvent) {
        guard let s = session else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { super.keyDown(with: event); return }
        var mods: TermModifiers = []
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.control) { mods.insert(.ctrl) }
        // Option is Meta, as terminals send it: ESC before the key.
        if flags.contains(.option) { mods.insert(.alt) }
        let key = Self.termKey(event.keyCode)
        let base = event.charactersIgnoringModifiers?.first
        // The terminal's own shortcuts.
        if let shortcut = TerminalInput.shortcut(key, character: base, modifiers: mods, hasSelection: s.view.hasSelection) {
            switch shortcut {
            case .copy: copySelection()
            case .copyAndClearSelection: copySelection(); s.view.clearSelection(); needsDisplay = true
            case .paste: pasteClipboard()
            case .nextTab: SSHSessions.shared.step(from: s, backward: false)
            case .previousTab: SSHSessions.shared.step(from: s, backward: true)
            case .pageUp: scrollView(to: s.view.offset + (s.vt.rows - 1))
            case .pageDown: scrollView(to: s.view.offset - (s.vt.rows - 1))
            }
            return
        }
        if !s.running {
            // Enter reconnects a session that ended.
            if key == .enter, let error = s.reconnect() { s.feed(Data(TerminalInput.errorNote(error).utf8)) }
            return
        }
        if let key {
            // Space and the keys that send text go as text unless a modifier changes them.
            let plainText = (key == .space && !mods.contains(.ctrl) && !mods.contains(.alt))
            if !plainText, let bytes = TerminalInput.encode(key, modifiers: mods, appCursor: s.vt.appCursor) {
                s.send(bytes)
                return
            }
        }
        if mods.contains(.ctrl), let c = base, let code = TerminalInput.control(c) {
            s.send((mods.contains(.alt) ? [0x1B] : []) + [code])
            return
        }
        if mods.contains(.alt), !mods.contains(.ctrl), let text = event.charactersIgnoringModifiers, !text.isEmpty {
            s.send(TerminalInput.text(text, alt: true))
            return
        }
        // Text, through the input method (dead keys, compositions).
        interpretKeyEvents([event])
    }

    // NSTextInputClient: what an input method types.
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        marked = ""
        MainActor.assumeIsolated { if !text.isEmpty { session?.send(TerminalInput.text(text)) } }
    }
    override func doCommand(by selector: Selector) {
        // Keys the input method turned into commands still reach the program.
        MainActor.assumeIsolated {
            guard let s = session else { return }
            switch selector {
            case #selector(insertNewline(_:)): s.send([0x0D])
            case #selector(insertTab(_:)): s.send([0x09])
            case #selector(deleteBackward(_:)): s.send([0x7F])
            case #selector(cancelOperation(_:)): s.send([0x1B])
            default: break
            }
        }
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    }
    func unmarkText() { marked = "" }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { marked.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: (marked as NSString).length) }
    func hasMarkedText() -> Bool { !marked.isEmpty }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        MainActor.assumeIsolated {
            guard let s = session, let window else { return .zero }
            let c = s.vt.cursor
            let local = NSRect(x: Self.pad + CGFloat(c.x) * cellWidth, y: Self.pad + CGFloat(c.y) * cellHeight, width: cellWidth, height: cellHeight)
            return window.convertToScreen(convert(local, to: nil))
        }
    }

    // MARK: - The mouse

    @MainActor private func mark(_ event: NSEvent) -> TermMark? {
        guard let s = session else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        return s.view.mark(x: Double(p.x), y: Double(p.y), cellWidth: Double(cellWidth), cellHeight: Double(cellHeight),
                           padding: Double(Self.pad), vt: s.vt)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        MainActor.assumeIsolated {
            guard let s = session, let m = mark(event) else { return }
            if event.clickCount == 2 { s.view.selectWord(vt: s.vt, at: m) }
            else { s.view.begin(at: m) }
            needsDisplay = true
        }
    }
    override func mouseDragged(with event: NSEvent) {
        MainActor.assumeIsolated {
            guard let s = session, s.view.selecting else { return }
            let y = convert(event.locationInWindow, from: nil).y
            // Dragging past the top or bottom scrolls the view along.
            if y < 0 { scrollView(to: s.view.offset + 1) } else if y > bounds.height { scrollView(to: s.view.offset - 1) }
            if let m = mark(event) { s.view.drag(to: m) }
            needsDisplay = true
        }
    }
    override func mouseUp(with event: NSEvent) {
        MainActor.assumeIsolated { session?.view.end() }
    }
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.rightMouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        MainActor.assumeIsolated {
            guard let s = session else { return }
            // A trackpad scrolls by points (a line a cell's height, a notch three lines), a wheel by notches.
            var notches: Int
            if event.hasPreciseScrollingDeltas {
                wheelRemainder += event.scrollingDeltaY
                if !s.vt.altScreen {
                    let lines = Int(wheelRemainder / cellHeight)
                    wheelRemainder -= CGFloat(lines) * cellHeight
                    if lines != 0 { scrollView(to: s.view.offset + lines) }
                    return
                }
                notches = Int(wheelRemainder / (cellHeight * 3))
                wheelRemainder -= CGFloat(notches) * cellHeight * 3
            } else {
                wheelRemainder += event.scrollingDeltaY
                notches = Int(wheelRemainder.rounded(.towardZero))
                wheelRemainder -= CGFloat(notches)
            }
            if notches == 0 { return }
            if s.running, let keys = TerminalInput.wheel(notches: notches, altScreen: s.vt.altScreen, appCursor: s.vt.appCursor) {
                // Full-screen programs (less, vim, htop) have no scrollback: the wheel moves them with the arrow keys.
                s.write(keys)
                return
            }
            if !s.vt.altScreen { scrollView(to: s.view.offset + notches * 3) }
        }
    }
}

/// The terminal of a session, in SwiftUI: the session's own view, moved into whichever screen shows it.
struct TerminalHost: NSViewRepresentable {
    var session: TerminalSession

    final class Container: NSView {
        weak var attached: TerminalCanvas?
        override var isFlipped: Bool { true }
    }

    func makeNSView(context: Context) -> Container {
        let c = Container()
        attach(session, to: c)
        return c
    }
    func updateNSView(_ c: Container, context: Context) {
        if c.attached !== session.canvas { attach(session, to: c) }
    }
    static func dismantleNSView(_ c: Container, coordinator: ()) {
        if let canvas = c.attached, canvas.superview === c { canvas.removeFromSuperview() }
    }

    private func attach(_ s: TerminalSession, to c: Container) {
        if let old = c.attached, old.superview === c { old.removeFromSuperview() }
        let canvas = s.canvas
        canvas.removeFromSuperview()
        canvas.frame = c.bounds
        canvas.autoresizingMask = [.width, .height]
        c.addSubview(canvas)
        c.attached = canvas
        // A session just opened or switched to takes the keyboard.
        DispatchQueue.main.async { [weak canvas] in
            guard let canvas, let window = canvas.window else { return }
            window.makeFirstResponder(canvas)
        }
    }
}
