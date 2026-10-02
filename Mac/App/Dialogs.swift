// Modal dialogs: confirmations, choices, alerts and one line of text, as the Windows client's task dialogs.
import AppKit

@MainActor
enum Dialogs {
    /// A confirmation with one continue button; true when confirmed.
    static func confirm(_ title: String, _ message: String? = nil, continueLabel: String = "Continue", destructive: Bool = false) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message ?? ""
        alert.alertStyle = destructive ? .warning : .informational
        let ok = alert.addButton(withTitle: continueLabel)
        if destructive { ok.hasDestructiveAction = true }
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    /// A choice among several buttons; the chosen index or nil.
    static func choose(_ title: String, _ message: String? = nil, choices: [String]) -> Int? {
        guard !choices.isEmpty else { return nil }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message ?? ""
        for c in choices { alert.addButton(withTitle: c) }
        alert.addButton(withTitle: "Cancel")
        let r = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return r >= 0 && r < choices.count ? r : nil
    }
    static func alert(_ title: String, _ message: String? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message ?? ""
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    /// One line of text under a caption and a label, with `okLabel` on its button; nil when cancelled.
    static func text(_ caption: String, label: String? = nil, okLabel: String = "OK", current: String = "", placeholder: String = "",
                     multiline: Bool = false, secure: Bool = false) -> String? {
        let alert = NSAlert()
        alert.messageText = caption
        alert.informativeText = label ?? ""
        alert.addButton(withTitle: okLabel)
        alert.addButton(withTitle: "Cancel")
        let field: NSView
        let read: () -> String
        if multiline {
            let scroll = NSTextView.scrollableTextView()
            scroll.frame = NSRect(x: 0, y: 0, width: 360, height: 120)
            let tv = scroll.documentView as! NSTextView
            tv.string = current
            tv.font = .systemFont(ofSize: 13)
            tv.isRichText = false
            field = scroll
            read = { tv.string }
        } else {
            let f: NSTextField = secure ? NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
                                        : NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            f.stringValue = current
            f.placeholderString = placeholder
            field = f
            read = { f.stringValue }
        }
        alert.accessoryView = field
        alert.window.initialFirstResponder = (field as? NSScrollView)?.documentView ?? field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return read()
    }
    /// A password or passphrase, typed hidden under `label`; nil when cancelled.
    static func password(_ caption: String, label: String) -> String? { text(caption, label: label, secure: true) }
}
