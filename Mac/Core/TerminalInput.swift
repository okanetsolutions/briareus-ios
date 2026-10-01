// The SSH sessions tab's platform-independent parts, ported from the Windows client's app/terminal.c: what a session
// connects to and the ssh arguments it runs with, keys and pastes turned into what the program reads, the selection
// (which follows its text as output scrolls) and the colours cells are painted in. Launching ssh in a pseudo-terminal and
// drawing the grid belong to the app.
import Foundation

/// What a session connects to. `key` names the registered server, so a second click finds its open session; `group` is
/// the project it belongs to, whose tab lists it.
struct TermTarget: Equatable, Sendable {
    var key: String
    var group: String
    var label: String
    var user: String
    var host: String
    var port: Int

    /// user@host:port
    var display: String { "\(user)@\(host):\(port)" }
    /// The label shown on its tab: its own, else the host.
    var tabLabel: String { label.isEmpty ? host : label }

    private static func safeWord(_ z: String, _ extra: String) -> Bool {
        if z.isEmpty || z.hasPrefix("-") { return false }
        let allowed = Set(extra.utf8)
        return z.utf8.allSatisfy { c in
            (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39) || c >= 0x80 || allowed.contains(c)
        }
    }

    /// Why a target cannot be handed to ssh as it is (an empty or option-like host or user, a port out of range); nil when
    /// it can.
    var problem: String? {
        if host.isEmpty { return "This server has no host." }
        // The host and user go to ssh as its arguments: nothing that reads as an option or splits into more than one.
        if !Self.safeWord(host, ".-_:[]%") { return "The host \u{201C}\(host)\u{201D} is not a hostname or an IP address ssh can be given." }
        if user.isEmpty { return "This server has no username." }
        if !Self.safeWord(user, ".-_$\\") { return "The username \u{201C}\(user)\u{201D} cannot be given to ssh." }
        if port < 1 || port > 65535 { return "The port \(port) is not from 1 to 65535." }
        return nil
    }

    /// The arguments ssh runs with (after the program itself): `ssh -p PORT -l USER -- HOST`.
    var sshArguments: [String] { ["-p", String(port), "-l", user, "--", host] }
    /// The arguments sftp runs with: `sftp -P PORT -o User=USER -o ServerAliveInterval=30 -- HOST`.
    var sftpArguments: [String] { ["-P", String(port), "-o", "User=\(user)", "-o", "ServerAliveInterval=30", "--", host] }
}

// MARK: - Keys

/// The keys that are sent as escape sequences rather than as the text they type.
enum TermKey: Equatable, Sendable {
    case up, down, right, left, home, end, insert, delete, pageUp, pageDown
    /// F1...F12
    case function(Int)
    case backspace, tab, enter, escape, space
}

struct TermModifiers: OptionSet, Hashable, Sendable {
    let rawValue: Int
    static let shift = TermModifiers(rawValue: 1)
    static let alt = TermModifiers(rawValue: 2)
    static let ctrl = TermModifiers(rawValue: 4)
}

/// The terminal's own shortcuts on Windows, handled before a key reaches the program.
enum TermShortcut: Equatable, Sendable { case copy, copyAndClearSelection, paste, nextTab, previousTab, pageUp, pageDown }

enum TerminalInput {
    /// xterm's modifier parameter: 1 + Shift + 2·Alt + 4·Ctrl.
    static func modifierParameter(_ m: TermModifiers) -> Int {
        1 + (m.contains(.shift) ? 1 : 0) + (m.contains(.alt) ? 2 : 0) + (m.contains(.ctrl) ? 4 : 0)
    }

    /// What a key sends to the program, as xterm does; nil for a key that types text instead (send `text(_:alt:)`).
    /// `appCursor` is the terminal's application cursor mode (DECCKM), which arrows, Home and End follow.
    static func encode(_ key: TermKey, modifiers m: TermModifiers = [], appCursor: Bool = false) -> [UInt8]? {
        let mp = modifierParameter(m)
        func s(_ z: String) -> [UInt8] { Array(z.utf8) }
        func cursorKey(_ f: Character) -> [UInt8] {
            mp > 1 ? s("\u{1b}[1;\(mp)\(f)") : s(appCursor ? "\u{1b}O\(f)" : "\u{1b}[\(f)")
        }
        func tilde(_ n: Int) -> [UInt8] { mp > 1 ? s("\u{1b}[\(n);\(mp)~") : s("\u{1b}[\(n)~") }
        switch key {
        case .up: return cursorKey("A")
        case .down: return cursorKey("B")
        case .right: return cursorKey("C")
        case .left: return cursorKey("D")
        case .home: return cursorKey("H")
        case .end: return cursorKey("F")
        case .insert: return tilde(2)
        case .delete: return tilde(3)
        case .pageUp: return tilde(5)
        case .pageDown: return tilde(6)
        case .function(let n):
            guard n >= 1 && n <= 12 else { return nil }
            let i = n - 1
            if i < 4 {
                let f = Array("PQRS")[i]
                return mp > 1 ? s("\u{1b}[1;\(mp)\(f)") : s("\u{1b}O\(f)")
            }
            let codes = [0, 0, 0, 0, 15, 17, 18, 19, 20, 21, 23, 24]
            return tilde(codes[i])
        case .backspace:
            // Backspace is DEL, Ctrl+Backspace BS; Alt puts ESC before either.
            return (m.contains(.alt) ? [0x1B] : []) + [m.contains(.ctrl) ? 0x08 : 0x7F]
        case .tab:
            if m.contains(.shift) { return s("\u{1b}[Z") }
            return (m.contains(.alt) ? [0x1B] : []) + [0x09]
        case .enter: return (m.contains(.alt) ? [0x1B] : []) + [0x0D]
        case .escape: return (m.contains(.alt) ? [0x1B] : []) + [0x1B]
        case .space:
            if m.contains(.ctrl) { return [0x00] }
            return (m.contains(.alt) ? [0x1B] : []) + [0x20]
        }
    }

    /// Ctrl with a character, as Windows' keyboard layer turns it into a control code: letters to 1...26, `@`/`2`/space
    /// to NUL, `[ \ ] ^ _` to 27...31 (`6` and `-` as `^` and `_`); nil for a character with no control code.
    static func control(_ c: Character) -> UInt8? {
        guard let a = c.asciiValue else { return nil }
        switch a {
        case 0x61...0x7A: return a - 0x60
        case 0x40...0x5F: return a - 0x40
        case 0x32, 0x20: return 0x00
        case 0x36: return 0x1E
        case 0x2D: return 0x1F
        default: return nil
        }
    }

    /// Typed text; with Alt, ESC before it, as terminals send Meta.
    static func text(_ s: String, alt: Bool = false) -> [UInt8] { (alt ? [0x1B] : []) + Array(s.utf8) }

    /// A paste: lines end in a carriage return, as the Enter key sends them, and escapes are dropped (one could end
    /// bracketed paste early); wrapped in ESC[200~ … ESC[201~ when the program asked for bracketed paste.
    static func paste(_ text: String, bracketed: Bool) -> [UInt8] {
        var out: [UInt8] = bracketed ? Array("\u{1b}[200~".utf8) : []
        let b = Array(text.utf8)
        for (i, c) in b.enumerated() {
            if c == 0x0D && i + 1 < b.count && b[i + 1] == 0x0A { continue }
            if c == 0x1B { continue }
            out.append(c == 0x0A ? 0x0D : c)
        }
        if bracketed { out += Array("\u{1b}[201~".utf8) }
        return out
    }

    /// Focus in or out, for a program that asked to be told (mode 1004). Sent when focus changes, and once at the
    /// moment the program turns the mode on.
    static func focusReport(focused: Bool) -> [UInt8] { Array((focused ? "\u{1b}[I" : "\u{1b}[O").utf8) }

    /// The mouse wheel on the alternate screen: full-screen programs (less, vim, htop) have no scrollback, so each notch
    /// is three arrow presses (up for positive notches). nil on the main screen, where the wheel scrolls the view by three
    /// lines a notch instead.
    static func wheel(notches: Int, altScreen: Bool, appCursor: Bool) -> [UInt8]? {
        guard altScreen, notches != 0 else { return nil }
        let key = notches > 0 ? (appCursor ? "\u{1b}OA" : "\u{1b}[A") : (appCursor ? "\u{1b}OB" : "\u{1b}[B")
        return Array(String(repeating: key, count: 3 * abs(notches)).utf8)
    }

    /// The Windows client's terminal shortcuts: Ctrl+Shift+C copies, Ctrl+Shift+V and Shift+Insert paste, Ctrl+C copies
    /// (and clears) when there is a selection, Ctrl+Insert copies, Ctrl+Tab and Ctrl+Shift+Tab step through the project's
    /// sessions, Shift+PageUp/PageDown scroll the view a page.
    static func shortcut(_ key: TermKey?, character: Character?, modifiers m: TermModifiers, hasSelection: Bool) -> TermShortcut? {
        let ctrl = m.contains(.ctrl), shift = m.contains(.shift)
        let letter = character.map { Character($0.lowercased()) }
        if ctrl && shift && letter == "c" { return .copy }
        if ctrl && shift && letter == "v" { return .paste }
        if ctrl && !shift && letter == "c" && hasSelection { return .copyAndClearSelection }
        if shift && key == .insert { return .paste }
        if ctrl && key == .insert { return .copy }
        if ctrl && key == .tab { return shift ? .previousTab : .nextTab }
        if shift && !ctrl && key == .pageUp { return .pageUp }
        if shift && !ctrl && key == .pageDown { return .pageDown }
        return nil
    }

    /// What the terminal prints when its program ends; Enter then reconnects.
    static func sessionClosedNote(exitCode: Int32) -> String {
        exitCode == 0
            ? "\r\n\u{1b}[0;2m[Session closed. Press Enter to reconnect.]\u{1b}[0m\r\n"
            : "\r\n\u{1b}[0;2m[Session closed (exit code \(UInt32(bitPattern: exitCode))). Press Enter to reconnect.]\u{1b}[0m\r\n"
    }
    /// What the terminal prints as it starts the program again.
    static func connectingNote(target: TermTarget) -> String { "\u{1b}[0;2m[Connecting to \(target.display)\u{2026}]\u{1b}[0m\r\n" }
    /// A failure to reconnect, printed in the terminal.
    static func errorNote(_ error: String) -> String { "\r\n\(error)\r\n" }

    /// The title to show for a session: the remote shell's, ignoring one that is just the client's path (as ConPTY titles
    /// the window until the shell names it).
    static func displayTitle(_ vtTitle: String?, clientSuffix: String = "ssh") -> String? {
        guard let vtTitle else { return nil }
        return vtTitle.hasSuffix(clientSuffix) ? nil : vtTitle
    }
}

// MARK: - The view and the selection

/// A selection end: a line counted from the first that ever scrolled away, so it stays on its text as output scrolls.
struct TermMark: Comparable, Hashable, Sendable {
    var line: Int64
    var col: Int
    static func < (a: TermMark, b: TermMark) -> Bool { a.line != b.line ? a.line < b.line : a.col < b.col }
}

/// The view's scroll position and selection over a `VTerminal`.
struct TerminalView: Sendable {
    /// lines scrolled back from the bottom
    var offset = 0
    var selecting = false
    var hasSelection = false
    var anchor = TermMark(line: 0, col: 0)
    var head = TermMark(line: 0, col: 0)

    static func lineBase(_ vt: VTerminal) -> Int64 { Int64(vt.linesPushed) }

    /// The mark under a point of the view: `x`, `y` in points from the view's corner, past `padding`; the column rounds
    /// to the nearest cell boundary.
    func mark(x: Double, y: Double, cellWidth: Double, cellHeight: Double, padding: Double, vt: VTerminal) -> TermMark {
        let cw = cellWidth > 0 ? cellWidth : 1, chh = cellHeight > 0 ? cellHeight : 1
        var col = Int(((x - padding + cw / 2) / cw).rounded(.towardZero))
        var row = Int(((y - padding) / chh).rounded(.towardZero))
        row = max(0, min(row, vt.rows - 1))
        col = max(0, min(col, vt.cols))
        return TermMark(line: Self.lineBase(vt) + Int64(row) - Int64(offset), col: col)
    }

    /// A view row (0 at the top of the view) as a `VTerminal.line` index.
    func lineIndex(row: Int) -> Int { row - offset }

    var bounds: (from: TermMark, to: TermMark) { anchor <= head ? (anchor, head) : (head, anchor) }

    /// Whether the cell at `line` (a `VTerminal.line` index) and `col` is selected.
    func isSelected(vt: VTerminal, line: Int, col: Int) -> Bool {
        guard hasSelection else { return false }
        let m = TermMark(line: Self.lineBase(vt) + Int64(line), col: col), (from, to) = bounds
        return m >= from && m < to
    }

    /// The selected text, rows joined with CRLF; nil when nothing is selected or it scrolled out of the scrollback.
    func selectionText(vt: VTerminal) -> String? {
        guard hasSelection else { return nil }
        var (from, to) = bounds
        if from == to { return nil }
        let base = Self.lineBase(vt)
        var y0 = Int(from.line - base)
        let y1 = Int(to.line - base), lo = -vt.scrollbackCount
        if y1 < lo { return nil }
        if y0 < lo { y0 = lo; from.col = 0 }
        return vt.text(y0: y0, x0: from.col, y1: y1, x1: to.col)
    }

    mutating func begin(at m: TermMark) { selecting = true; hasSelection = false; anchor = m; head = m }
    mutating func drag(to m: TermMark) { head = m; hasSelection = anchor != head }
    mutating func end() { selecting = false }
    mutating func clearSelection() { hasSelection = false; selecting = false }

    mutating func selectAll(vt: VTerminal) {
        hasSelection = true
        anchor = TermMark(line: Self.lineBase(vt) - Int64(vt.scrollbackCount), col: 0)
        head = TermMark(line: Self.lineBase(vt) + Int64(vt.rows - 1), col: vt.cols)
    }

    /// Double-click: the run of non-blank characters under the mouse.
    mutating func selectWord(vt: VTerminal, at m: TermMark) {
        guard let row = vt.line(Int(m.line - Self.lineBase(vt))), m.col < row.count else { return }
        let col = m.col
        if row[col].ch == 0x20 { return }
        var a = col, b = col
        while a > 0 && row[a - 1].ch != 0x20 { a -= 1 }
        while b < row.count && row[b].ch != 0x20 { b += 1 }
        hasSelection = true
        anchor = TermMark(line: m.line, col: a); head = TermMark(line: m.line, col: b)
    }

    /// Scrolls the view, kept between the bottom and the top of the scrollback; whether it moved.
    @discardableResult mutating func scroll(to newOffset: Int, vt: VTerminal) -> Bool {
        let o = max(0, min(newOffset, vt.scrollbackCount))
        if o == offset { return false }
        offset = o
        return true
    }

    /// After output: a view scrolled back stays on the text it shows while new lines arrive below. `pushedBefore` is
    /// `vt.linesPushed` from before the output was fed.
    mutating func follow(vt: VTerminal, pushedBefore: UInt64) {
        let pushed = Int(vt.linesPushed - pushedBefore)
        if offset > 0 && pushed > 0 { offset = min(offset + pushed, vt.scrollbackCount) }
    }

    /// After a resize: the offset kept within the scrollback.
    mutating func clamp(vt: VTerminal) { if offset > vt.scrollbackCount { offset = vt.scrollbackCount } }

    /// The cell size a view of `width` × `height` points holds, at least 20 × 5 as the Windows client keeps it.
    static func gridSize(width: Double, height: Double, cellWidth: Double, cellHeight: Double, padding: Double, scrollbar: Double = 0) -> (cols: Int, rows: Int) {
        let w = width - 2 * padding - scrollbar, h = height - 2 * padding
        let cols = cellWidth > 0 ? Int(w / cellWidth) : 80, rows = cellHeight > 0 ? Int(h / cellHeight) : 24
        return (max(cols, 20), max(rows, 5))
    }
}

// MARK: - Colours

/// The colours cells are painted in: One Half, dark or light as the app is, for the first 16; the 256-colour cube and
/// greys above them; RGB as given. Colours are 0xRRGGBB.
enum TerminalPalette {
    static let dark16: [UInt32] = [0x282C34, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xDCDFE4,
                                   0x5A6374, 0xEF8790, 0xB3DB94, 0xF0D49E, 0x84C3F5, 0xD99BE8, 0x7DCBD4, 0xFFFFFF]
    static let light16: [UInt32] = [0x383A42, 0xE45649, 0x50A14F, 0xC18401, 0x0184BC, 0xA626A4, 0x0997B3, 0xA0A1A7,
                                    0x4F525D, 0xDF6C75, 0x3E953A, 0xA87000, 0x2F6FD0, 0xC577DD, 0x0B8A9E, 0x202227]

    static func background(dark: Bool) -> UInt32 { dark ? 0x16181D : 0xFBFAF6 }
    static func foreground(dark: Bool) -> UInt32 { dark ? 0xDCDFE4 : 0x2B2D33 }
    static func palette16(_ i: Int, dark: Bool) -> UInt32 { (dark ? dark16 : light16)[i & 15] }

    /// A cell colour as RGB; bold brightens the eight basic colours, as most terminals still do.
    static func resolve(_ c: VTColor, foreground fg: Bool, bold: Bool, dark: Bool) -> UInt32 {
        switch c {
        case .indexed(let n):
            let i = Int(n)
            if i < 16 { return palette16(bold && i < 8 ? i + 8 : i, dark: dark) }
            return VTerminal.indexRGB(i)
        case .rgb(let rgb): return rgb & 0xFFFFFF
        case .default: return fg ? foreground(dark: dark) : background(dark: dark)
        }
    }

    /// `color` over `background` at `alpha` (0...1), per channel: alpha 1 is `color` itself.
    static func blend(_ color: UInt32, _ background: UInt32, _ alpha: Double) -> UInt32 {
        let t = max(0, min(alpha, 1))
        func ch(_ v: UInt32, _ s: UInt32) -> Double { Double((v >> s) & 0xFF) }
        func mix(_ s: UInt32) -> UInt32 { UInt32((ch(color, s) * t + ch(background, s) * (1 - t)).rounded()) << s }
        return mix(16) | mix(8) | mix(0)
    }

    /// The foreground and background a cell is painted with: inverse swaps them, dim paints the foreground at 60% over the
    /// background, hidden paints it in the background.
    static func colors(of cell: VTCell, dark: Bool) -> (fg: UInt32, bg: UInt32) {
        var fg = resolve(cell.fg, foreground: true, bold: cell.attr.contains(.bold), dark: dark)
        var bg = resolve(cell.bg, foreground: false, bold: false, dark: dark)
        if cell.attr.contains(.inverse) { swap(&fg, &bg) }
        if cell.attr.contains(.dim) { fg = blend(fg, bg, 0.6) }
        if cell.attr.contains(.hidden) { fg = bg }
        return (fg, bg)
    }
}
