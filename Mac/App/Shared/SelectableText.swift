// Text that selects as the Windows client's pane does (doc.c "Selection", pane.c "Text selection"): a press anchors a
// selection that a drag carries across every text of the page, from one message into the next, the view scrolling
// past its edges; a double click takes a word, a triple click the paragraph; ⌘A takes everything, ⌘C copies it, Esc
// lets it go; the right click offers Copy, Copy text (the paragraph under the mouse) and Select all. Each piece of
// text is its own small view, laid out where SwiftUI puts it (bubbles, code blocks, folds keep their look); the views
// of one page join one `TextSelectionGroup`, which holds the selection's two ends and orders the views as they read.
import AppKit
import SwiftUI

// MARK: - Attributed text

extension NSAttributedString.Key {
    /// Inline code: a rounded tint behind the run.
    static let briareusCode = NSAttributedString.Key("briareus.code")
    /// A link's URL, opened on a click (not NSAttributedString's own `.link`, which AppKit would style).
    static let briareusLink = NSAttributedString.Key("briareus.link")
}

enum SelectableFont {
    static func system(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size, weight: weight) }
    static func mono(_ size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
    static func italic(_ f: NSFont) -> NSFont { NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
}

private func paragraph(_ align: NSTextAlignment, _ gap: CGFloat) -> NSParagraphStyle {
    let p = NSMutableParagraphStyle()
    p.alignment = align
    p.lineSpacing = gap
    p.lineBreakMode = .byWordWrapping
    return p
}

/// Plain text in one font and colour (`doc_text`): wrapped, or aligned on its line.
func selectablePlain(_ text: String, font: NSFont, color: Color, align: NSTextAlignment = .left, lineGap: CGFloat = 0) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(color), .paragraphStyle: paragraph(align, lineGap)])
}

/// Inline Markdown (`doc_rich`): bold, italic, strikethrough in the muted colour, code in the mono font on the sunken
/// tint, links in the accent with a faint underline; lines 4px apart.
func selectableRich(_ source: String, size: MarkdownSize = .body, color: Color = Theme.ink, bold: Bool = false,
                    font base: NSFont? = nil) -> NSAttributedString {
    let out = NSMutableAttributedString()
    let style = paragraph(.left, 4)
    let ink = NSColor(color), accent = NSColor(Theme.accent), muted = NSColor(Theme.muted)
    for span in Markdown.inline(source) {
        var attrs: [NSAttributedString.Key: Any] = [.paragraphStyle: style]
        var font: NSFont
        if span.flags.contains(.code) {
            font = SelectableFont.mono(size.mono)
            attrs[.briareusCode] = true
        } else if let base {
            font = base
            if span.flags.contains(.italic) { font = SelectableFont.italic(font) }
        } else {
            font = SelectableFont.system(size.size, span.flags.contains(.bold) || bold ? .semibold : .regular)
            if span.flags.contains(.italic) { font = SelectableFont.italic(font) }
        }
        attrs[.font] = font
        let link = span.flags.contains(.link) ? span.url : nil
        attrs[.foregroundColor] = link != nil ? accent : span.flags.contains(.strike) ? muted : ink
        if span.flags.contains(.strike) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let link {
            attrs[.briareusLink] = link
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attrs[.underlineColor] = accent.withAlphaComponent(0.4)
        }
        out.append(NSAttributedString(string: span.text, attributes: attrs))
    }
    return out
}

/// Tabs to the next multiple of 8 columns, as DT_EXPANDTABS.
func expandTabs(_ text: String) -> String {
    guard text.contains("\t") else { return text }
    var out = "", col = 0
    for c in text {
        if c == "\t" { let n = 8 - col % 8; out += String(repeating: " ", count: n); col += n }
        else { out.append(c); col = c == "\n" ? 0 : col + 1 }
    }
    return out
}

// MARK: - The group

/// The texts of one page and the selection across them.
@MainActor
final class TextSelectionGroup {
    private struct End { weak var view: SelectableTextNSView?; var offset: Int }
    private let members = NSHashTable<SelectableTextNSView>.weakObjects()
    private var anchor: End?
    private var focus: End?
    private var mouseMonitor: Any?

    func add(_ v: SelectableTextNSView) { members.add(v) }
    func remove(_ v: SelectableTextNSView) {
        members.remove(v)
        if anchor?.view === v || focus?.view === v { clear() }
    }

    /// The views on screen, in reading order: top to bottom, then left to right.
    private func ordered(in window: NSWindow? = nil) -> [(view: SelectableTextNSView, frame: NSRect)] {
        members.allObjects
            .filter { $0.window != nil && (window == nil || $0.window === window) && !$0.isHiddenOrHasHiddenAncestor }
            .map { ($0, $0.convert($0.bounds, to: nil)) }
            .sorted { a, b in
                if abs(a.1.maxY - b.1.maxY) > 0.5 { return a.1.maxY > b.1.maxY }
                return a.1.minX < b.1.minX
            }
    }

    /// The selection's ends in reading order, with the views between them; nil when it is empty.
    private func range() -> (list: [(view: SelectableTextNSView, frame: NSRect)], from: (Int, Int), to: (Int, Int))? {
        guard let a = anchor, let f = focus, let av = a.view, let fv = f.view else { return nil }
        let list = ordered(in: av.window)
        guard let ai = list.firstIndex(where: { $0.view === av }), let fi = list.firstIndex(where: { $0.view === fv }) else { return nil }
        var s = (ai, min(max(a.offset, 0), av.length)), e = (fi, min(max(f.offset, 0), fv.length))
        if e.0 < s.0 || (e.0 == s.0 && e.1 < s.1) { swap(&s, &e) }
        guard s.0 < e.0 || s.1 < e.1 else { return nil }
        return (list, s, e)
    }

    var hasSelection: Bool { range() != nil }

    /// Paints each view's part of the selection.
    private func apply() {
        let r = range()
        var index: [ObjectIdentifier: Int] = [:]
        if let r { for (i, e) in r.list.enumerated() { index[ObjectIdentifier(e.view)] = i } }
        for v in members.allObjects {
            guard let r, let i = index[ObjectIdentifier(v)], i >= r.from.0, i <= r.to.0 else {
                v.selected = NSRange(location: 0, length: 0); continue
            }
            let from = i == r.from.0 ? r.from.1 : 0, to = i == r.to.0 ? r.to.1 : v.length
            v.selected = from < to ? NSRange(location: from, length: to - from) : NSRange(location: 0, length: 0)
        }
        if r != nil { watchClicks() } else { unwatchClicks() }
    }

    func clear() {
        anchor = nil; focus = nil
        apply()
    }

    /// The text position nearest a point in the window (doc_position_at): the text spanning its height nearest it
    /// across; failing that, the end of the nearest text above it or the start of the nearest below.
    private func position(at p: NSPoint, in window: NSWindow?) -> End? {
        let list = ordered(in: window)
        var best: (SelectableTextNSView, CGFloat)?
        for (v, f) in list where p.y > f.minY && p.y <= f.maxY {
            let d = p.x < f.minX ? f.minX - p.x : p.x > f.maxX ? p.x - f.maxX : 0
            if best == nil || d < best!.1 { best = (v, d) }
        }
        if let (v, _) = best { return End(view: v, offset: v.offset(at: v.convert(p, from: nil))) }
        var near: (SelectableTextNSView, CGFloat, Bool)?
        for (v, f) in list {
            let above = p.y > f.maxY   // the point is above this text
            let d = above ? p.y - f.maxY : f.minY - p.y
            if near == nil || d < near!.1 { near = (v, d, above) }
        }
        guard let (v, _, above) = near else { return nil }
        return End(view: v, offset: above ? 0 : v.length)
    }

    func press(_ v: SelectableTextNSView, offset: Int, clicks: Int, extend: Bool) {
        if extend, anchor?.view != nil {
            focus = End(view: v, offset: offset)
        } else if clicks == 2 {
            selectWord(v, offset)
        } else if clicks >= 3 {
            anchor = End(view: v, offset: 0); focus = End(view: v, offset: v.length)
        } else {
            anchor = End(view: v, offset: offset); focus = anchor
        }
        apply()
    }
    /// Moves the selection's end to the mouse.
    func drag(to p: NSPoint, in window: NSWindow?) {
        guard anchor != nil, let pos = position(at: p, in: window) else { return }
        if pos.view === focus?.view && pos.offset == focus?.offset { return }
        focus = pos
        apply()
    }

    /// The word, or the run of spaces, at an offset, within its line (doc_select_word).
    private func selectWord(_ v: SelectableTextNSView, _ offset: Int) {
        let p = Array(v.plain.utf16)
        let n = p.count
        guard n > 0 else { return }
        let o = min(max(offset, 0), n - 1)
        func isSpace(_ c: UInt16) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0xA0 || c == 0x0B || c == 0x0C }
        let space = isSpace(p[o])
        var s = o, e = o + 1
        while s > 0 && isSpace(p[s - 1]) == space && p[s - 1] != 0x0A { s -= 1 }
        while e < n && isSpace(p[e]) == space && p[e] != 0x0A { e += 1 }
        anchor = End(view: v, offset: s); focus = End(view: v, offset: e)
    }

    /// Everything, from the first text to the end of the last.
    func selectAll(in window: NSWindow?) {
        let list = ordered(in: window)
        guard let first = list.first?.view, let last = list.last?.view else { return }
        anchor = End(view: first, offset: 0); focus = End(view: last, offset: last.length)
        apply()
    }
    /// The first text on screen, to take the keyboard after ⌘A.
    func firstView(in window: NSWindow?) -> SelectableTextNSView? { ordered(in: window).first?.view }

    /// The selected text; texts side by side join with a space, stacked ones take a line each (doc_selection_text).
    func selectedText() -> String? {
        guard let r = range() else { return nil }
        var out = "", any = false
        var prevMinY: CGFloat = 0
        for i in r.from.0...r.to.0 {
            let (v, f) = r.list[i]
            let from = i == r.from.0 ? r.from.1 : 0, to = i == r.to.0 ? r.to.1 : v.length
            guard from < to else { continue }
            if any { out += f.maxY > prevMinY + 2 ? " " : "\n" }
            out += (v.plain as NSString).substring(with: NSRange(location: from, length: to - from))
            prevMinY = f.minY; any = true
        }
        return any ? out : nil
    }
    func copy() {
        if let text = selectedText() { Clipboard.copy(text) }
    }

    /// A click anywhere but on one of these texts lets the selection go, as a press in the pane does.
    private func watchClicks() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                let hit = event.window?.contentView?.hitTest(event.locationInWindow)
                if let v = hit as? SelectableTextNSView, self.members.contains(v) { return }
                self.clear()
            }
            return event
        }
    }
    private func unwatchClicks() {
        if let m = mouseMonitor { NSEvent.removeMonitor(m); mouseMonitor = nil }
    }

    /// ⌘A, ⌘C and Esc for the page while no text field has the keyboard (the pane's Ctrl+A, Ctrl+C, Escape).
    /// Returns whether the key was taken.
    func handleKey(_ event: NSEvent, window: NSWindow) -> Bool {
        let responder = window.firstResponder
        if responder is NSText { return false }   // the composer, a field: their own selection
        if let v = responder as? SelectableTextNSView, !members.contains(v) { return false }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if mods == .command && key == "a" {
            selectAll(in: window)
            if let first = firstView(in: window), !(responder is SelectableTextNSView) { window.makeFirstResponder(first) }
            return true
        }
        if mods == .command && key == "c" && hasSelection { copy(); return true }
        if mods.isEmpty && event.keyCode == 53 && hasSelection { clear(); return true }
        return false
    }
}

// MARK: - One text

final class SelectableTextNSView: NSView {
    private let storage = NSTextStorage()
    private let layout = NSLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
    private weak var group: TextSelectionGroup?
    /// A group of its own, for text that is on no page's.
    private var ownGroup: TextSelectionGroup?
    private var measured: [CGFloat: CGSize] = [:]
    /// A press on a link, opened on release unless the mouse moved away first.
    private var pressedLink: (url: String, at: NSPoint, offset: Int)?
    private var lastDrag: NSEvent?
    private var scrollTimer: Timer?

    var selected = NSRange(location: 0, length: 0) { didSet { if oldValue != selected { needsDisplay = true } } }
    var plain: String { storage.string }
    var length: Int { storage.length }

    override init(frame: NSRect) {
        super.init(frame: frame)
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var focusRingType: NSFocusRingType { get { .none } set {} }

    func join(_ g: TextSelectionGroup?) {
        let target: TextSelectionGroup
        if let g { target = g; ownGroup = nil } else {
            if ownGroup == nil { ownGroup = TextSelectionGroup() }
            target = ownGroup!
        }
        if group === target { return }
        group?.remove(self)
        group = target
        target.add(self)
    }
    func leave() { group?.remove(self); group = nil }

    func set(_ text: NSAttributedString) {
        if storage.isEqual(to: text) { return }
        storage.setAttributedString(text)
        measured = [:]
        if selected.location + selected.length > storage.length { selected = NSRange(location: 0, length: 0) }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    private func layOut(width: CGFloat) {
        let w = max(width, 1)
        if container.size.width != w { container.size = NSSize(width: w, height: CGFloat.greatestFiniteMagnitude) }
        layout.ensureLayout(for: container)
    }
    /// The size the text takes at a width; its natural width when there is no limit.
    func measure(width: CGFloat) -> CGSize {
        let key = width.isFinite ? width : -1
        if let m = measured[key] { return m }
        layOut(width: width.isFinite ? width : 100_000)
        let used = layout.usedRect(for: container)
        var size = CGSize(width: ceil(used.width), height: ceil(used.height))
        if storage.length == 0 { size.height = 0 }
        measured[key] = size
        if bounds.width > 0 { layOut(width: bounds.width) }
        return size
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        if changed { needsDisplay = true; window?.invalidateCursorRects(for: self) }
    }

    override func draw(_ dirtyRect: NSRect) {
        layOut(width: bounds.width)
        let glyphs = layout.glyphRange(for: container)
        storage.enumerateAttribute(.briareusCode, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil else { return }
            NSColor(Theme.sunken).setFill()
            let g = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layout.enumerateEnclosingRects(forGlyphRange: g, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { r, _ in
                NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            }
        }
        if selected.length > 0 {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            NSColor(Theme.accent).withAlphaComponent(dark ? 0.4 : 0.3).setFill()
            let g = layout.glyphRange(forCharacterRange: selected, actualCharacterRange: nil)
            layout.enumerateEnclosingRects(forGlyphRange: g, withinSelectedGlyphRange: g, in: container) { r, _ in r.fill() }
        }
        layout.drawGlyphs(forGlyphRange: glyphs, at: .zero)
    }

    /// The character boundary nearest a point in the view.
    func offset(at p: NSPoint) -> Int {
        guard storage.length > 0 else { return 0 }
        layOut(width: bounds.width)
        let used = layout.usedRect(for: container)
        if p.y < used.minY { return 0 }
        if p.y >= used.maxY { return storage.length }
        var fraction: CGFloat = 0
        let i = layout.characterIndex(for: p, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
        return min(storage.length, fraction > 0.5 ? i + 1 : i)
    }
    /// The link under a point, when the point is on its glyphs.
    private func link(at p: NSPoint) -> String? {
        guard storage.length > 0 else { return nil }
        layOut(width: bounds.width)
        var fraction: CGFloat = 0
        let g = layout.glyphIndex(for: p, in: container, fractionOfDistanceThroughGlyph: &fraction)
        guard g < layout.numberOfGlyphs, layout.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: container).insetBy(dx: 0, dy: -2).contains(p) else { return nil }
        let c = layout.characterIndexForGlyph(at: g)
        return storage.attribute(.briareusLink, at: c, effectiveRange: nil) as? String
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
        guard storage.length > 0 else { return }
        layOut(width: bounds.width)
        storage.enumerateAttribute(.briareusLink, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil else { return }
            let g = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layout.enumerateEnclosingRects(forGlyphRange: g, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { r, _ in
                self.addCursorRect(r, cursor: .pointingHand)
            }
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let offset = offset(at: p)
        let shift = event.modifierFlags.contains(.shift)
        if event.clickCount == 1 && !shift, let url = link(at: p) {
            pressedLink = (url, event.locationInWindow, offset)
            return
        }
        group?.press(self, offset: offset, clicks: event.clickCount, extend: shift)
    }
    override func mouseDragged(with event: NSEvent) {
        if let link = pressedLink {
            let d = hypot(event.locationInWindow.x - link.at.x, event.locationInWindow.y - link.at.y)
            if d < 4 { return }
            pressedLink = nil
            group?.press(self, offset: link.offset, clicks: 1, extend: false)
        }
        lastDrag = event
        extend(event)
        // Past the view's edges the page scrolls, and keeps scrolling while the mouse stays there.
        if autoscroll(with: event) {
            if scrollTimer == nil {
                scrollTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let e = self.lastDrag, NSEvent.pressedMouseButtons & 1 != 0 else { self?.stopScrolling(); return }
                        if self.autoscroll(with: e) { self.extend(e) } else { self.stopScrolling() }
                    }
                }
            }
        } else { stopScrolling() }
    }
    private func extend(_ event: NSEvent) {
        group?.drag(to: event.locationInWindow, in: window)
    }
    private func stopScrolling() { scrollTimer?.invalidate(); scrollTimer = nil }
    override func mouseUp(with event: NSEvent) {
        stopScrolling(); lastDrag = nil
        if let link = pressedLink {
            pressedLink = nil
            group?.clear()
            openWebURL(link.url)
        }
    }

    // MARK: Keyboard and menu

    @objc func copy(_ sender: Any?) { group?.copy() }
    override func selectAll(_ sender: Any?) { group?.selectAll(in: window) }
    @objc private func copyText(_ sender: Any?) { Clipboard.copy(plain) }
    override func cancelOperation(_ sender: Any?) { group?.clear() }

    var hasSelection: Bool { group?.hasSelection ?? false }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let copy = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "c")
        copy.target = self
        copy.isEnabled = hasSelection
        menu.addItem(copy)
        let text = NSMenuItem(title: "Copy text", action: #selector(copyText(_:)), keyEquivalent: "")
        text.target = self
        menu.addItem(text)
        let all = NSMenuItem(title: "Select all", action: #selector(selectAll(_:)), keyEquivalent: "a")
        all.target = self
        menu.addItem(all)
        return menu
    }
}

extension SelectableTextNSView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(copy(_:)) { return hasSelection }
        return true
    }
}

// MARK: - SwiftUI

private struct TextSelectionGroupKey: EnvironmentKey {
    static let defaultValue: TextSelectionGroup? = nil
}
extension EnvironmentValues {
    /// The page's selection, which every `SelectableText` under it joins.
    var textSelectionGroup: TextSelectionGroup? {
        get { self[TextSelectionGroupKey.self] }
        set { self[TextSelectionGroupKey.self] = newValue }
    }
}

/// A piece of selectable text: wraps to the width it is offered and takes its height.
struct SelectableText: NSViewRepresentable {
    var text: NSAttributedString
    @Environment(\.textSelectionGroup) private var group

    init(_ text: NSAttributedString) { self.text = text }
    /// Plain text in a font and colour.
    init(_ string: String, font: NSFont, color: Color, align: NSTextAlignment = .left) {
        text = selectablePlain(string, font: font, color: color, align: align)
    }

    func makeNSView(context: Context) -> SelectableTextNSView {
        let v = SelectableTextNSView(frame: .zero)
        v.join(group)
        v.set(text)
        return v
    }
    func updateNSView(_ v: SelectableTextNSView, context: Context) {
        v.join(group)
        v.set(text)
    }
    static func dismantleNSView(_ v: SelectableTextNSView, coordinator: ()) { v.leave() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SelectableTextNSView, context: Context) -> CGSize? {
        if let w = proposal.width, w.isFinite {
            let natural = nsView.measure(width: .infinity)
            if natural.width <= w { return CGSize(width: w, height: natural.height) }
            return CGSize(width: w, height: nsView.measure(width: max(w, 1)).height)
        }
        return nsView.measure(width: .infinity)
    }
}

/// Gives a page its selection: the texts under it select as one, and ⌘A, ⌘C and Esc work on it while no field has
/// the keyboard.
struct TextSelectionScope: ViewModifier {
    let group: TextSelectionGroup
    func body(content: Content) -> some View {
        content
            .environment(\.textSelectionGroup, group)
            .background(SelectionKeys(group: group).frame(width: 0, height: 0))
    }
}
extension View {
    func textSelectionScope(_ group: TextSelectionGroup) -> some View { modifier(TextSelectionScope(group: group)) }
}

/// Watches the keys while the page is in a window.
private struct SelectionKeys: NSViewRepresentable {
    let group: TextSelectionGroup
    func makeNSView(context: Context) -> KeysView { let v = KeysView(); v.group = group; return v }
    func updateNSView(_ v: KeysView, context: Context) { v.group = group }

    final class KeysView: NSView {
        var group: TextSelectionGroup?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let taken = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let window = self.window, event.window === window, let group = self.group else { return false }
                    return group.handleKey(event, window: window)
                }
                return taken ? nil : event
            }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
