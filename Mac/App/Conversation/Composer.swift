// The composer both the conversation and the new session screen use: an NSTextView where Enter sends and Shift+Enter breaks
// the line, Escape leaves it, a paste or a drop of files or an image attaches them; the chips above it; the box around it
// (`#composer-wrap`) with its 📎, microphone and send buttons; and the menus the chips open.
import AppKit
import SwiftUI

// MARK: - The text

/// A request to put the cursor in the composer; bump `tick` to ask again.
struct FocusRequest: Equatable { var tick = 0 }

struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    /// Visual lines of the text, for the box's height (1...8 lines of 24px).
    @Binding var lines: Int
    @Binding var focused: Bool
    var placeholder: String
    var focus: FocusRequest
    var onSubmit: () -> Void
    /// A paste: true when it was taken as attachments and is not to be pasted as text.
    var onPaste: (NSPasteboard) -> Bool
    var onDrop: ([URL]) -> Void

    static let lineHeight: CGFloat = 24
    static let ink = Theme.nsDynamic(0xE8E6E1, 0x1F1E1D)
    static let muted = Theme.nsDynamic(0xA29E93, 0x6B675E)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ComposerScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.hasHorizontalScroller = false
        let tv = ComposerNSTextView()
        tv.coordinator = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: 15)
        tv.textColor = ComposerTextView.ink
        tv.insertionPointColor = ComposerTextView.ink
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = ComposerTextView.lineHeight
        p.maximumLineHeight = ComposerTextView.lineHeight
        tv.defaultParagraphStyle = p
        tv.typingAttributes = [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: ComposerTextView.ink, .paragraphStyle: p,
                               .baselineOffset: 3]
        tv.placeholder = placeholder
        tv.delegate = context.coordinator
        tv.string = text
        tv.registerForDraggedTypes([.fileURL])
        scroll.documentView = tv
        context.coordinator.textView = tv
        DispatchQueue.main.async { context.coordinator.measure() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = context.coordinator.textView else { return }
        tv.placeholder = placeholder
        if tv.string != text {
            tv.string = text
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            context.coordinator.measure()
            tv.needsDisplay = true
        }
        if context.coordinator.lastFocus != focus {
            context.coordinator.lastFocus = focus
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: ComposerNSTextView?
        var lastFocus: FocusRequest
        init(_ parent: ComposerTextView) { self.parent = parent; lastFocus = parent.focus }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            if parent.text != tv.string { parent.text = tv.string }
            measure()
        }
        func measure() {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            var count = 0, index = 0
            let glyphs = lm.numberOfGlyphs
            while index < glyphs {
                var range = NSRange()
                lm.lineFragmentRect(forGlyphAt: index, effectiveRange: &range)
                index = NSMaxRange(range); count += 1
            }
            if lm.extraLineFragmentTextContainer != nil { count += 1 }
            let n = max(1, count)
            if parent.lines != n { DispatchQueue.main.async { if self.parent.lines != n { self.parent.lines = n } } }
        }
        func focusChanged(_ on: Bool) { if parent.focused != on { parent.focused = on } }
    }
}

/// Keeps the text view at least as tall as what shows of it, so a click anywhere in the box's text area lands in it.
final class ComposerScrollView: NSScrollView {
    override func tile() {
        super.tile()
        if let tv = documentView as? NSTextView, tv.minSize.height != contentSize.height {
            tv.minSize = NSSize(width: 0, height: contentSize.height)
            tv.sizeToFit()
        }
    }
}

final class ComposerNSTextView: NSTextView {
    weak var coordinator: ComposerTextView.Coordinator?
    var placeholder = "" { didSet { if oldValue != placeholder { needsDisplay = true } } }

    // A new width wraps the text anew: the box takes the new number of lines.
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { coordinator?.measure() }
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 36 || event.keyCode == 76 {   // Return, Enter
            if !mods.contains(.shift) && !mods.contains(.control) && !mods.contains(.option) && !hasMarkedText() {
                coordinator?.parent.onSubmit()
                return
            }
            if mods.contains(.shift) { insertNewlineIgnoringFieldEditor(nil); return }
        }
        if event.keyCode == 53 { window?.makeFirstResponder(nil); return }   // Escape leaves the composer
        super.keyDown(with: event)
    }
    override func paste(_ sender: Any?) {
        if coordinator?.parent.onPaste(NSPasteboard.general) == true { return }
        super.paste(sender)
    }
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { coordinator?.focusChanged(true) }
        needsDisplay = true
        return ok
    }
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { coordinator?.focusChanged(false) }
        needsDisplay = true
        return ok
    }

    // Files dropped from Finder become attachments, not their paths as text.
    private func droppedFiles(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = droppedFiles(sender)
        if files.isEmpty { return super.performDragOperation(sender) }
        coordinator?.parent.onDrop(files)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty && !placeholder.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: ComposerTextView.muted]
            let size = (placeholder as NSString).size(withAttributes: attrs)
            let y = (ComposerTextView.lineHeight - size.height) / 2
            (placeholder as NSString).draw(at: NSPoint(x: 0, y: isFlipped ? y : bounds.height - y - size.height), withAttributes: attrs)
        }
    }
}

// MARK: - Chips

/// One chip over the composer: 24px, `rounded-md bg-raise border`, 12px text, at most 150px; the accent while on, a ▾
/// after a picker's label.
struct ComposerChipView: View {
    var label: String
    var on = false
    var live = true
    var picker = false
    var action: (() -> Void)?
    var body: some View {
        let content = HStack(spacing: 4) {
            Text(label).font(Theme.caption).foregroundStyle(on ? Theme.accent : live ? Theme.ink : Theme.muted)
                .lineLimit(1).truncationMode(.tail)
            if picker { Text("\u{25BE}").font(Theme.tinySemibold).foregroundStyle(Theme.muted) }
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .frame(maxWidth: 150, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.raise))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(on ? Theme.accent : Theme.line, lineWidth: 1))
        .fixedSize(horizontal: true, vertical: false)
        if let action {
            Button(action: action) { content.contentShape(Rectangle()) }.buttonStyle(.plain)
        } else { content }
    }
}

// MARK: - Menus

/// One row of a chip's menu.
struct MenuRow {
    var title: String
    var checked = false
    var enabled = true
    var separator = false
    static let divider = MenuRow(title: "", separator: true)
}

/// Pops a menu of rows under the mouse, as the chips' TrackPopupMenu; the chosen row's index, or nil.
@MainActor
func popUpMenu(_ rows: [MenuRow]) -> Int? {
    final class Target: NSObject {
        var chosen: Int?
        @objc func pick(_ item: NSMenuItem) { chosen = item.tag }
    }
    let target = Target()
    let menu = NSMenu()
    menu.autoenablesItems = false
    for (i, row) in rows.enumerated() {
        if row.separator { menu.addItem(.separator()); continue }
        let item = NSMenuItem(title: row.title, action: #selector(Target.pick(_:)), keyEquivalent: "")
        item.target = target
        item.tag = i
        item.state = row.checked ? .on : .off
        item.isEnabled = row.enabled
        menu.addItem(item)
    }
    let mouse = NSEvent.mouseLocation
    menu.popUp(positioning: nil, at: NSPoint(x: mouse.x, y: mouse.y - 4), in: nil)
    return target.chosen
}

// MARK: - The box

/// `#composer-wrap`'s box: `rounded-2xl border bg-raise px-3 pt-2.5 pb-2`, line-strong while the text has the cursor; the
/// files, the text, and a row of buttons, the leading ones at the left and send at the right.
struct ComposerBox<Leading: View, Trailing: View>: View {
    @ObservedObject var files: Attachments
    @Binding var text: String
    @Binding var lines: Int
    @Binding var focused: Bool
    var placeholder: String
    var focus: FocusRequest
    var filesEnabled = true
    var onSubmit: () -> Void
    var onPaste: (NSPasteboard) -> Bool
    var onDrop: ([URL]) -> Void
    var onTap: () -> Void
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AttachmentChips(files: files, enabled: filesEnabled)
            ComposerTextView(text: $text, lines: $lines, focused: $focused, placeholder: placeholder, focus: focus,
                             onSubmit: onSubmit, onPaste: onPaste, onDrop: onDrop)
                .frame(height: CGFloat(min(max(lines, 1), 8)) * ComposerTextView.lineHeight)
            HStack(spacing: 6) {
                leading
                Spacer(minLength: 0)
                trailing
            }
            .frame(height: 30)
            .padding(.top, 6)
        }
        .padding(.horizontal, 12).padding(.top, 11).padding(.bottom, 9)
        // A click on the box around the text puts the cursor in it; the text takes its own clicks.
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.raise).onTapGesture(perform: onTap))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(focused ? Theme.lineStrong : Theme.line, lineWidth: 1).allowsHitTesting(false))
    }
}

/// `#btn-send`: 32×30, the accent with ↵ when there is something to send, the field colour otherwise.
struct SendButton: View {
    var filled: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text("\u{21B5}").font(Theme.body).foregroundStyle(filled ? Theme.onAccent : Theme.muted)
                .frame(width: 32, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(filled ? Theme.accent : Theme.field))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Send")
    }
}

/// A small square button of the composer's row: ■ to stop the agent, ✕ to discard a voice note.
struct ComposerSquareButton: View {
    var glyph: String
    var color: Color = Theme.muted
    var tip: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(glyph).font(Theme.caption).foregroundStyle(color)
                .frame(width: 32, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raise))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tip)
    }
}

/// The footer's column: 24px from each side, at most 860px, centered.
struct FooterColumn<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(maxWidth: 860)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
    }
}
