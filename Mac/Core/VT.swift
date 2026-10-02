// A terminal emulator's state, without a window: the xterm subset that the programs behind ssh write (cursor moves,
// erases, scroll regions, SGR colours, the alternate screen, DEC line drawing, OSC titles), into a grid of cells with a
// scrollback above it. The app's terminal view paints the grid and feeds it what the pseudo-terminal prints.
// A port of the Windows client's core/vt.c: a VT500-style parser (ground, escape, CSI, OSC and the strings it skips) over
// a grid of cells, with the main and alternate screens and a ring of scrollback lines.
import Foundation

/// A colour: the terminal's default, one of the 256 indexed colours, or 24-bit RGB (0xRRGGBB).
enum VTColor: Hashable, Sendable {
    case `default`
    case indexed(UInt8)
    case rgb(UInt32)
}

struct VTAttributes: OptionSet, Hashable, Sendable {
    let rawValue: UInt16
    static let bold = VTAttributes(rawValue: 1)
    static let dim = VTAttributes(rawValue: 2)
    static let italic = VTAttributes(rawValue: 4)
    static let underline = VTAttributes(rawValue: 8)
    static let inverse = VTAttributes(rawValue: 16)
    static let hidden = VTAttributes(rawValue: 32)
    static let strike = VTAttributes(rawValue: 64)
    /// the first half of a double-width character
    static let wide = VTAttributes(rawValue: 128)
    /// the cell a double-width character's second half covers; never painted on its own
    static let wideTail = VTAttributes(rawValue: 256)
}

struct VTCell: Hashable, Sendable {
    /// The code point; 0 never appears in a written cell, but reads as a blank.
    var ch: UInt32
    var fg: VTColor
    var bg: VTColor
    var attr: VTAttributes

    static let blank = VTCell(ch: 0x20, fg: .default, bg: .default, attr: [])
    /// The character, a replacement character for anything that is not a scalar.
    var character: Character { Character(Unicode.Scalar(ch == 0 ? 0x20 : ch) ?? "\u{FFFD}") }
}

final class VTerminal {
    private enum State { case ground, esc, escInter, csi, osc, oscEsc, string, stringEsc, charset }
    private struct Saved {
        var x = 0, y = 0
        var pen = VTCell.blank
        var origin = false, autowrap = true, g0Lines = false, g1Lines = false, shiftOut = false
    }
    private static let maxParams = 16, oscMax = 4096

    private(set) var cols: Int
    private(set) var rows: Int
    private var main: [VTCell], alt: [VTCell]
    private var onAlt = false
    private var sb: [[VTCell]]
    private let sbCap: Int
    private var sbStart = 0, sbCount = 0
    /// How many lines ever left the top of the main screen, so a view or a selection can follow its text as it scrolls.
    private(set) var linesPushed: UInt64 = 0
    private var x = 0, y = 0
    private var wrapPending = false
    /// the attributes new characters and erases take
    private var pen = VTCell.blank
    /// the scroll region, inclusive
    private var top = 0, bottom = 0
    private var tabs: [Bool]
    private(set) var cursorVisible = true
    private var autowrap = true, origin = false, insert = false
    /// The modes the keyboard encoding depends on.
    private(set) var appCursor = false, appKeypad = false, bracketedPaste = false
    private var newlineMode = false
    /// Whether the program asked for focus in/out reports (mode 1004), and for keys as Win32 input records (mode 9001).
    private(set) var focusEvents = false, win32Input = false
    /// DEC special graphics in G0 / G1, and SO selecting G1
    private var g0Lines = false, g1Lines = false, shiftOut = false
    private var saved = Saved(), savedAlt = Saved()
    // The parser.
    private var state = State.ground
    /// -1 for a parameter left empty
    private var params = [Int](repeating: 0, count: VTerminal.maxParams)
    private var nparams = 0
    private var privateMark: UInt8 = 0, inter: UInt8 = 0
    private var charsetTarget = 0
    private var osc: [UInt8] = []
    private var utf8CP: UInt32 = 0, utf8Need = 0
    /// for REP
    private var lastChar: UInt32 = 0
    private var response: [UInt8] = []
    /// The title an OSC 0 or 2 set; nil when none was.
    private(set) var title: String?
    private var titleChanged = false, bell = false

    /// Called at the end of each `feed` with the bytes the terminal answers with (cursor position and device attribute
    /// reports), to write back to the program. When it is nil they wait for `takeResponse()`.
    var onResponse: ((Data) -> Void)?

    init(cols: Int, rows: Int, scrollback: Int) {
        let cols = max(cols, 1), rows = max(rows, 1)
        self.cols = cols; self.rows = rows
        main = []; alt = []
        tabs = [Bool](repeating: false, count: cols)
        sbCap = max(scrollback, 0)
        sb = []
        resetModes()
        resetTabs()
        main = [VTCell](repeating: blank(), count: cols * rows)
        alt = main
        saved.pen = pen; saved.autowrap = true
        savedAlt = saved
    }

    // MARK: - Reading

    /// Lines held above the screen.
    var scrollbackCount: Int { sbCount }
    var altScreen: Bool { onAlt }
    /// The cursor; `x` stays on screen while a wrap is pending at the right edge.
    var cursor: (x: Int, y: Int, visible: Bool) { (x < cols ? x : cols - 1, y, cursorVisible) }

    /// A line: 0...rows-1 on screen, -1...-scrollback above it. A scrollback line keeps the width it was written at, its
    /// trailing blanks dropped. nil past either end.
    func line(_ y: Int) -> [VTCell]? {
        if y >= 0 {
            if y >= rows { return nil }
            let g = onAlt ? alt : main
            return Array(g[(y * cols)..<((y + 1) * cols)])
        }
        if -y > sbCount { return nil }
        return sb[(sbStart + sbCount + y) % sbCap]
    }
    /// One cell, as `line(y)[x]`; nil outside the line.
    func cell(x: Int, y: Int) -> VTCell? {
        if y >= 0 {
            guard y < rows, x >= 0, x < cols else { return nil }
            return (onAlt ? alt : main)[y * cols + x]
        }
        guard let l = line(y), x >= 0, x < l.count else { return nil }
        return l[x]
    }

    /// Bytes the terminal answers with, to write back to the program; nil when there is nothing to send.
    func takeResponse() -> Data? {
        if response.isEmpty { return nil }
        defer { response = [] }
        return Data(response)
    }
    /// Whether the title changed or BEL rang since the last call; clears the flag.
    func takeTitleChanged() -> Bool { defer { titleChanged = false }; return titleChanged }
    func takeBell() -> Bool { defer { bell = false }; return bell }

    /// Empties the scrollback, keeping the screen.
    func clearScrollback() { sb = []; sbStart = 0; sbCount = 0 }

    /// The text of a range, row by row, trailing blanks dropped and rows joined with CRLF; rows as for `line`, the end
    /// column exclusive.
    func text(y0: Int, x0: Int, y1: Int, x1: Int) -> String {
        var s = String.UnicodeScalarView()
        if y0 <= y1 {
            for y in y0...y1 {
                let row = line(y)
                let width = row?.count ?? 0
                let from = y == y0 ? x0 : 0
                var to = y == y1 ? x1 : width
                if to > width { to = width }
                var lineScalars: [Unicode.Scalar] = []
                if let row {
                    var x = max(from, 0)
                    while x < to {
                        if !row[x].attr.contains(.wideTail) { lineScalars.append(Unicode.Scalar(row[x].ch == 0 ? 0x20 : row[x].ch) ?? "\u{FFFD}") }
                        x += 1
                    }
                }
                while lineScalars.last == " " { lineScalars.removeLast() }
                s.append(contentsOf: lineScalars)
                if y < y1 { s.append(contentsOf: "\r\n".unicodeScalars) }
            }
        }
        return String(s)
    }

    // MARK: - Character widths and colours

    /// How many cells a code point takes: 0 for combining marks, 2 for East Asian wide characters and emoji, else 1.
    static func charWidth(_ c: UInt32) -> Int {
        if c == 0 { return 0 }
        // Combining marks and zero-width joiners ride on the cell before them.
        if (0x0300...0x036F).contains(c) || (0x1AB0...0x1AFF).contains(c) || (0x1DC0...0x1DFF).contains(c) || (0x20D0...0x20FF).contains(c)
            || (0xFE20...0xFE2F).contains(c) || c == 0x200B || c == 0x200C || c == 0x200D || c == 0xFE0F || c == 0xFE0E { return 0 }
        if (0x1100...0x115F).contains(c) || (0x2E80...0x303E).contains(c) || (0x3041...0x33FF).contains(c) || (0x3400...0x4DBF).contains(c)
            || (0x4E00...0x9FFF).contains(c) || (0xA000...0xA4CF).contains(c) || (0xAC00...0xD7A3).contains(c) || (0xF900...0xFAFF).contains(c)
            || (0xFE30...0xFE4F).contains(c) || (0xFF00...0xFF60).contains(c) || (0xFFE0...0xFFE6).contains(c)
            || (0x1F300...0x1F64F).contains(c) || (0x1F900...0x1F9FF).contains(c) || (0x1F680...0x1F6FF).contains(c)
            || (0x20000...0x3FFFD).contains(c) { return 2 }
        return 1
    }

    /// The 256-colour palette's RGB for an index from 16 up (the cube and the greys); the first 16 are the app's to choose.
    static func indexRGB(_ index: Int) -> UInt32 {
        var i = index
        if i < 16 { return 0 }
        if i < 232 {
            let steps: [UInt32] = [0, 95, 135, 175, 215, 255]
            i -= 16
            return steps[i / 36] << 16 | steps[(i / 6) % 6] << 8 | steps[i % 6]
        }
        let g = UInt32(8 + (i - 232) * 10)
        return g << 16 | g << 8 | g
    }

    // MARK: - The grid

    private func blank() -> VTCell { VTCell(ch: 0x20, fg: .default, bg: pen.bg, attr: []) }
    private subscript(gy: Int, gx: Int) -> VTCell {
        get { onAlt ? alt[gy * cols + gx] : main[gy * cols + gx] }
        set { if onAlt { alt[gy * cols + gx] = newValue } else { main[gy * cols + gx] = newValue } }
    }
    private func fillRows(_ from: Int, _ count: Int, _ v: VTCell) {
        let r = (from * cols)..<((from + count) * cols)
        if onAlt { alt.replaceSubrange(r, with: repeatElement(v, count: r.count)) } else { main.replaceSubrange(r, with: repeatElement(v, count: r.count)) }
    }
    /// Copies `count` whole rows from `src` to `dst`, as memmove does.
    private func moveRows(from src: Int, to dst: Int, count: Int) {
        if count <= 0 || src == dst { return }
        let n = count * cols
        if onAlt {
            let chunk = Array(alt[(src * cols)..<(src * cols + n)]); alt.replaceSubrange((dst * cols)..<(dst * cols + n), with: chunk)
        } else {
            let chunk = Array(main[(src * cols)..<(src * cols + n)]); main.replaceSubrange((dst * cols)..<(dst * cols + n), with: chunk)
        }
    }

    private func resetTabs() { for i in 0..<cols { tabs[i] = i > 0 && i % 8 == 0 } }
    private func resetModes() {
        pen = VTCell.blank
        top = 0; bottom = rows - 1
        cursorVisible = true; autowrap = true; origin = false; insert = false
        appCursor = false; appKeypad = false; bracketedPaste = false; newlineMode = false
        focusEvents = false; win32Input = false
        g0Lines = false; g1Lines = false; shiftOut = false
        wrapPending = false
    }

    // MARK: - Scrolling

    private func pushScrollback(_ row: ArraySlice<VTCell>) {
        linesPushed += 1
        if sbCap == 0 { return }
        var width = row.count
        let base = row.startIndex
        while width > 0, case let c = row[base + width - 1], c.ch == 0x20, c.attr.isEmpty, c.bg == .default { width -= 1 }
        let cells = Array(row.prefix(width))
        if sbCount == sbCap {
            sb[sbStart] = cells
            sbStart = (sbStart + 1) % sbCap
        } else if sb.count < sbCap {
            sb.append(cells)
            sbCount += 1
        } else {
            sb[(sbStart + sbCount) % sbCap] = cells
            sbCount += 1
        }
    }

    /// Moves the lines between `top` and `bottom` up by `n`, blanking the ones that come in at the bottom. Lines leaving the top
    /// of the main screen's full-height region are kept in the scrollback.
    private func scrollUp(_ top: Int, _ bottom: Int, _ n: Int) {
        let height = bottom - top + 1
        if n <= 0 || height <= 0 { return }
        let n = min(n, height)
        if top == 0 && !onAlt { for i in 0..<n { pushScrollback(main[(i * cols)..<((i + 1) * cols)]) } }
        moveRows(from: top + n, to: top, count: height - n)
        fillRows(bottom - n + 1, n, blank())
    }
    private func scrollDown(_ top: Int, _ bottom: Int, _ n: Int) {
        let height = bottom - top + 1
        if n <= 0 || height <= 0 { return }
        let n = min(n, height)
        moveRows(from: top, to: top + n, count: height - n)
        fillRows(top, n, blank())
    }

    private func linefeed() {
        wrapPending = false
        if y == bottom { scrollUp(top, bottom, 1) } else if y < rows - 1 { y += 1 }
    }
    private func reverseIndex() {
        wrapPending = false
        if y == top { scrollDown(top, bottom, 1) } else if y > 0 { y -= 1 }
    }

    // MARK: - Cursor

    private func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { v < lo ? lo : v > hi ? hi : v }
    private func moveTo(_ nx: Int, _ ny: Int) {
        wrapPending = false
        let lo = origin ? top : 0, hi = origin ? bottom : rows - 1
        x = clamp(nx, 0, cols - 1)
        y = clamp(ny, lo, hi)
    }
    /// Up or down without leaving the scroll region when the cursor starts inside it.
    private func moveRowsBy(_ dy: Int) {
        var lo = 0, hi = rows - 1
        if y >= top && y <= bottom { lo = top; hi = bottom }
        wrapPending = false
        y = clamp(y + dy, lo, hi)
    }

    private func saveCursor() {
        let s = Saved(x: x, y: y, pen: pen, origin: origin, autowrap: autowrap, g0Lines: g0Lines, g1Lines: g1Lines, shiftOut: shiftOut)
        if onAlt { savedAlt = s } else { saved = s }
    }
    private func restoreCursor() {
        let s = onAlt ? savedAlt : saved
        pen = s.pen; origin = s.origin; autowrap = s.autowrap
        g0Lines = s.g0Lines; g1Lines = s.g1Lines; shiftOut = s.shiftOut
        x = clamp(s.x, 0, cols - 1); y = clamp(s.y, 0, rows - 1)
        wrapPending = false
    }

    private func setAlt(_ on: Bool, save: Bool, clear: Bool) {
        if on == onAlt { return }
        if on {
            if save { saveCursor() }
            onAlt = true
            if clear { alt = [VTCell](repeating: blank(), count: cols * rows) }
        } else {
            if clear { alt = [VTCell](repeating: blank(), count: cols * rows) }
            onAlt = false
            if save { restoreCursor() }
        }
        wrapPending = false
    }

    // MARK: - Printing

    private static let decGraphics: [UInt32] = [
        0x25C6, 0x2592, 0x2409, 0x240C, 0x240D, 0x240A, 0x00B0, 0x00B1, 0x2424, 0x240B, 0x2518, 0x2510, 0x250C, 0x2514, 0x253C,
        0x23BA, 0x23BB, 0x2500, 0x23BC, 0x23BD, 0x251C, 0x2524, 0x2534, 0x252C, 0x2502, 0x2264, 0x2265, 0x03C0, 0x2260, 0x00A3,
        0x00B7,
    ]
    /// DEC special graphics: the line-drawing set `ESC ( 0` selects, for 0x60...0x7E.
    private static func decGraphic(_ c: UInt32) -> UInt32 { c >= 0x60 && c <= 0x7E ? decGraphics[Int(c - 0x60)] : c }

    private func putChar(_ c0: UInt32) {
        var c = c0
        if (shiftOut ? g1Lines : g0Lines) && c < 0x80 { c = Self.decGraphic(c) }
        var w = Self.charWidth(c)
        if w == 0 { return }
        if wrapPending {
            if autowrap { x = 0; linefeed() }
            wrapPending = false
        }
        if w == 2 && x == cols - 1 {
            // A wide character never straddles the edge: it wraps whole, or overwrites the last cell when wrapping is off.
            if autowrap { self[y, x] = blank(); x = 0; linefeed() } else { w = 1 }
        }
        // A one-column screen has no room for a wide character's tail.
        if w == 2 && x + 1 >= cols { w = 1 }
        if insert {
            let n = cols - x - w
            if n > 0 {
                let base = y * cols
                if onAlt { let chunk = Array(alt[(base + x)..<(base + x + n)]); alt.replaceSubrange((base + x + w)..<(base + x + w + n), with: chunk) }
                else { let chunk = Array(main[(base + x)..<(base + x + n)]); main.replaceSubrange((base + x + w)..<(base + x + w + n), with: chunk) }
            }
        }
        // Overwriting half of a wide character blanks its other half.
        if self[y, x].attr.contains(.wideTail) && x > 0 { self[y, x - 1] = blank() }
        if self[y, x].attr.contains(.wide) && x + 1 < cols { self[y, x + 1] = blank() }
        var cell = pen
        cell.ch = c
        cell.attr.subtract([.wide, .wideTail])
        if w == 2 {
            if x + 2 < cols && self[y, x + 1].attr.contains(.wide) { self[y, x + 2] = blank() }
            cell.attr.insert(.wide)
            self[y, x] = cell
            var tail = cell
            tail.ch = 0x20
            tail.attr = cell.attr.subtracting(.wide).union(.wideTail)
            self[y, x + 1] = tail
        } else {
            self[y, x] = cell
        }
        lastChar = c
        if x + w >= cols { x = cols - 1; wrapPending = true } else { x += w }
    }

    // MARK: - Erasing and editing

    private func eraseCells(_ ey: Int, _ x0: Int, _ x1: Int) {
        let a = clamp(x0, 0, cols), b = clamp(x1, 0, cols)
        if b > a { let v = blank(); for i in a..<b { self[ey, i] = v } }
    }
    private func eraseDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseCells(y, x, cols)
            for r in (y + 1)..<max(rows, y + 1) { eraseCells(r, 0, cols) }
        case 1:
            for r in 0..<y { eraseCells(r, 0, cols) }
            eraseCells(y, 0, x + 1)
        case 2: for r in 0..<rows { eraseCells(r, 0, cols) }
        case 3: clearScrollback()
        default: break
        }
    }
    private func eraseLine(_ mode: Int) {
        if mode == 0 { eraseCells(y, x, cols) } else if mode == 1 { eraseCells(y, 0, x + 1) } else if mode == 2 { eraseCells(y, 0, cols) }
    }
    private func insertChars(_ count: Int) {
        let n = clamp(count, 1, cols - x)
        var row = Array((onAlt ? alt : main)[(y * cols)..<((y + 1) * cols)])
        let moved = Array(row[x..<(cols - n)])
        row.replaceSubrange((x + n)..<cols, with: moved)
        for i in x..<(x + n) { row[i] = blank() }
        setRow(y, row)
        wrapPending = false
    }
    private func deleteChars(_ count: Int) {
        let n = clamp(count, 1, cols - x)
        var row = Array((onAlt ? alt : main)[(y * cols)..<((y + 1) * cols)])
        let moved = Array(row[(x + n)..<cols])
        row.replaceSubrange(x..<(cols - n), with: moved)
        for i in (cols - n)..<cols { row[i] = blank() }
        setRow(y, row)
        wrapPending = false
    }
    private func setRow(_ r: Int, _ row: [VTCell]) {
        if onAlt { alt.replaceSubrange((r * cols)..<((r + 1) * cols), with: row) } else { main.replaceSubrange((r * cols)..<((r + 1) * cols), with: row) }
    }
    private func insertLines(_ n: Int) {
        if y < top || y > bottom { return }
        scrollDown(y, bottom, n)
        x = 0; wrapPending = false
    }
    private func deleteLines(_ count: Int) {
        if y < top || y > bottom { return }
        // Deleting lines inside the screen never feeds the scrollback, even from its first line.
        let height = bottom - y + 1
        let n = min(count, height)
        moveRows(from: y + n, to: y, count: height - n)
        fillRows(bottom - n + 1, n, blank())
        x = 0; wrapPending = false
    }

    // MARK: - SGR

    /// 38;5;N or 38;2;R;G;B from `p` (the parameters from the 38 or 48 on); how many past it were read.
    private func extendedColor(_ p: ArraySlice<Int>) -> (VTColor, Int) {
        let n = p.count, b = p.startIndex
        if n >= 3 && p[b + 1] == 5 { return (.indexed(UInt8(clamp(p[b + 2], 0, 255))), 2) }
        if n >= 2 && p[b + 1] == 2 {
            let r = n > 2 ? clamp(p[b + 2], 0, 255) : 0, g = n > 3 ? clamp(p[b + 3], 0, 255) : 0, bl = n > 4 ? clamp(p[b + 4], 0, 255) : 0
            return (.rgb(UInt32(r << 16 | g << 8 | bl)), 4)
        }
        return (.default, n - 1)
    }
    private func sgr() {
        let n = nparams > 0 ? nparams : 1
        var i = 0
        while i < n {
            var p = nparams > 0 ? params[i] : 0
            if p < 0 { p = 0 }
            switch p {
            case 0: pen.attr = []; pen.fg = .default; pen.bg = .default
            case 1: pen.attr.insert(.bold)
            case 2: pen.attr.insert(.dim)
            case 3: pen.attr.insert(.italic)
            case 4, 21: pen.attr.insert(.underline)
            case 7: pen.attr.insert(.inverse)
            case 8: pen.attr.insert(.hidden)
            case 9: pen.attr.insert(.strike)
            case 22: pen.attr.subtract([.bold, .dim])
            case 23: pen.attr.remove(.italic)
            case 24: pen.attr.remove(.underline)
            case 27: pen.attr.remove(.inverse)
            case 28: pen.attr.remove(.hidden)
            case 29: pen.attr.remove(.strike)
            case 39: pen.fg = .default
            case 49: pen.bg = .default
            case 38, 48:
                let (c, used) = extendedColor(params[i..<n])
                if p == 38 { pen.fg = c } else { pen.bg = c }
                i += used
            case 30...37: pen.fg = .indexed(UInt8(p - 30))
            case 40...47: pen.bg = .indexed(UInt8(p - 40))
            case 90...97: pen.fg = .indexed(UInt8(p - 90 + 8))
            case 100...107: pen.bg = .indexed(UInt8(p - 100 + 8))
            default: break
            }
            i += 1
        }
    }

    // MARK: - Modes

    private func setMode(_ on: Bool) {
        for i in 0..<nparams {
            let p = params[i]
            if privateMark == UInt8(ascii: "?") {
                switch p {
                case 1: appCursor = on
                case 6: origin = on; moveTo(0, on ? top : 0)
                case 7: autowrap = on; if !on { wrapPending = false }
                case 25: cursorVisible = on
                case 47, 1047: setAlt(on, save: false, clear: p == 1047 && !on)
                case 1048: if on { saveCursor() } else { restoreCursor() }
                case 1049: setAlt(on, save: true, clear: true)
                case 1004: focusEvents = on
                case 2004: bracketedPaste = on
                case 9001: win32Input = on
                default: break
                }
            } else if privateMark == 0 {
                if p == 4 { insert = on } else if p == 20 { newlineMode = on }
            }
        }
    }

    private func respond(_ s: String) { response += Array(s.utf8) }

    private func deviceStatus() {
        let p = nparams > 0 ? params[0] : 0
        if p == 5 { respond("\u{1b}[0n") }
        else if p == 6 {
            let ry = y + 1 - (origin ? top : 0)
            respond("\u{1b}[\(ry);\((x < cols ? x : cols - 1) + 1)R")
        }
    }

    private func softReset() {
        resetModes()
        saved.pen = pen; saved.x = 0; saved.y = 0
    }
    private func fullReset() {
        onAlt = false
        resetModes()
        resetTabs()
        main = [VTCell](repeating: blank(), count: cols * rows)
        alt = main
        clearScrollback()
        x = 0; y = 0
        saved = Saved(); saved.pen = pen; saved.autowrap = true
        savedAlt = saved
    }

    // MARK: - CSI

    private func param(_ i: Int, _ fallback: Int) -> Int {
        let p = i < nparams ? params[i] : -1
        return p <= 0 ? fallback : p
    }
    private func csiDispatch(_ final: UInt8) {
        let q = UInt8(ascii: "?")
        if privateMark == q && final != UInt8(ascii: "h") && final != UInt8(ascii: "l") { return }
        if privateMark == UInt8(ascii: ">") {
            // Secondary device attributes: a VT220-class terminal, version 10.
            if final == UInt8(ascii: "c") { respond("\u{1b}[>1;10;0c") }
            return
        }
        if privateMark != 0 && privateMark != q { return }
        if inter == UInt8(ascii: "!") && final == UInt8(ascii: "p") { softReset(); return }
        if inter != 0 { return }   // DECSCUSR (` q`) and the rest change nothing that is drawn
        let n = param(0, 1)
        switch Unicode.Scalar(final) {
        case "@": insertChars(n)
        case "A": moveRowsBy(-n)
        case "B", "e": moveRowsBy(n)
        case "C", "a": moveTo(x + n, y)
        case "D": moveTo((x < cols ? x : cols - 1) - n, y)
        case "E": moveRowsBy(n); x = 0
        case "F": moveRowsBy(-n); x = 0
        case "G", "`": moveTo(n - 1, y)
        case "H", "f": moveTo(param(1, 1) - 1, n - 1 + (origin ? top : 0))
        case "d": moveTo(x, n - 1 + (origin ? top : 0))
        case "I":
            for _ in 0..<n { var nx = x + 1; while nx < cols - 1 && !tabs[nx] { nx += 1 }; moveTo(nx, y) }
        case "Z":
            for _ in 0..<n { var nx = x - 1; while nx > 0 && !tabs[nx] { nx -= 1 }; moveTo(nx, y) }
        case "J": eraseDisplay(param(0, 0))
        case "K": eraseLine(param(0, 0))
        case "L": insertLines(n)
        case "M": deleteLines(n)
        case "P": deleteChars(n)
        case "S": scrollUp(top, bottom, n)
        case "T": scrollDown(top, bottom, n)
        case "X": eraseCells(y, x, x + n); wrapPending = false
        case "b": if lastChar != 0 { for _ in 0..<min(n, 65535) { putChar(lastChar) } }
        case "c": if param(0, 0) == 0 { respond("\u{1b}[?62;22c") }
        case "g": if param(0, 0) == 3 { tabs = [Bool](repeating: false, count: cols) } else if x < cols { tabs[x] = false }
        case "h": setMode(true)
        case "l": setMode(false)
        case "m": sgr()
        case "n": deviceStatus()
        case "r":
            let t = param(0, 1) - 1
            var b = param(1, rows) - 1
            if b >= rows { b = rows - 1 }
            if t < b { top = t; bottom = b; moveTo(0, origin ? t : 0) }
        case "s": saveCursor()
        case "u": restoreCursor()
        default: break
        }
    }

    // MARK: - OSC

    private func oscDispatch() {
        guard let semi = osc.firstIndex(of: UInt8(ascii: ";")) else { return }
        let kind = osc[..<semi]
        if kind.elementsEqual("0".utf8) || kind.elementsEqual("2".utf8) {
            let t = String(decoding: osc[(semi + 1)...], as: UTF8.self)
            if title != t { title = t; titleChanged = true }
        }
    }
    private func oscPut(_ c: UInt8) { if osc.count < Self.oscMax { osc.append(c) } }

    // MARK: - The parser

    private func csiBegin() {
        state = .csi
        nparams = 0; privateMark = 0; inter = 0
    }

    private func control(_ c: UInt32) {
        switch c {
        case 0x07: bell = true
        case 0x08: if wrapPending { wrapPending = false } else if x > 0 { x -= 1 }
        case 0x09:
            var nx = x + 1
            while nx < cols - 1 && !tabs[nx] { nx += 1 }
            x = clamp(nx, 0, cols - 1); wrapPending = false
        case 0x0A, 0x0B, 0x0C: linefeed(); if newlineMode { x = 0 }
        case 0x0D: x = 0; wrapPending = false
        case 0x0E: shiftOut = true
        case 0x0F: shiftOut = false
        default: break
        }
    }

    private func escDispatch(_ c: UInt32) {
        state = .ground
        switch c {
        case 0x5B: csiBegin()                                  // [
        case 0x5D: state = .osc; osc = []                      // ]
        case 0x50, 0x58, 0x5E, 0x5F: state = .string           // P X ^ _
        case 0x28, 0x29: state = .charset; charsetTarget = c == 0x28 ? 0 : 1   // ( )
        case 0x2A, 0x2B: state = .charset; charsetTarget = 2   // * +
        case 0x23, 0x25, 0x20: state = .escInter               // # % space
        case 0x37: saveCursor()                                // 7
        case 0x38: restoreCursor()                             // 8
        case 0x44: linefeed()                                  // D
        case 0x45: x = 0; linefeed()                           // E
        case 0x48: if x < cols { tabs[x] = true }              // H
        case 0x4D: reverseIndex()                              // M
        case 0x63: fullReset()                                 // c
        case 0x3D: appKeypad = true                            // =
        case 0x3E: appKeypad = false                           // >
        default: break
        }
    }

    private func feedCode(_ c: UInt32) {
        // CAN and SUB abandon a sequence; ESC starts a new one from anywhere but inside a string, where it may begin ST.
        if c == 0x18 || c == 0x1A { state = .ground; return }
        switch state {
        case .ground:
            if c == 0x1B { state = .esc }
            else if c < 0x20 || c == 0x7F { control(c) }
            else if c >= 0x80 && c < 0xA0 { if c == 0x9B { csiBegin() } else if c == 0x9D { state = .osc; osc = [] } }
            else { putChar(c) }
        case .esc:
            if c == 0x1B { break }
            if c < 0x20 { control(c); break }
            escDispatch(c)
        case .escInter:
            if c >= 0x30 { state = .ground }
        case .charset:
            if charsetTarget == 0 { g0Lines = c == 0x30 } else if charsetTarget == 1 { g1Lines = c == 0x30 }
            state = .ground
        case .csi:
            if c == 0x1B { state = .esc; break }
            if c < 0x20 { control(c); break }
            if c >= 0x30 && c <= 0x39 {
                if nparams == 0 { nparams = 1; params[0] = -1 }
                if params[nparams - 1] < 0 { params[nparams - 1] = 0 }
                if params[nparams - 1] < 100000 { params[nparams - 1] = params[nparams - 1] * 10 + Int(c - 0x30) }
            } else if c == 0x3B || c == 0x3A {
                // An empty parameter counts, so `CSI ;5H` is row default, column 5; -1 marks one left empty.
                if nparams == 0 { nparams = 1; params[0] = -1 }
                if nparams < Self.maxParams { params[nparams] = -1; nparams += 1 }
            } else if c >= 0x3C && c <= 0x3F { if nparams == 0 { privateMark = UInt8(c) } }
            else if c >= 0x20 && c <= 0x2F { inter = UInt8(c) }
            else if c >= 0x40 && c <= 0x7E {
                for i in 0..<nparams where params[i] < 0 { params[i] = 0 }
                state = .ground
                csiDispatch(UInt8(c))
            } else { state = .ground }
        case .osc:
            if c == 0x07 || c == 0x9C { oscDispatch(); state = .ground }
            else if c == 0x1B { state = .oscEsc }
            else if c >= 0x20 { for b in String(Character(Unicode.Scalar(c) ?? "\u{FFFD}")).utf8 { oscPut(b) } }
        case .oscEsc:
            if c == 0x5C { oscDispatch(); state = .ground } else { state = .esc; feedCode(c) }
        case .string:
            if c == 0x1B { state = .stringEsc } else if c == 0x9C || c == 0x07 { state = .ground }
        case .stringEsc:
            state = c == 0x5C ? .ground : .string
        }
    }

    // MARK: - Feeding

    /// Feeds bytes as the program printed them; UTF-8 and escape sequences may be split across calls.
    func feed<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        for b in bytes {
            if utf8Need > 0 {
                if b & 0xC0 == 0x80 {
                    utf8CP = utf8CP << 6 | UInt32(b & 0x3F)
                    utf8Need -= 1
                    if utf8Need == 0 {
                        let cp = utf8CP
                        feedCode(cp >= 0x80 && cp <= 0x10FFFF && !(cp >= 0xD800 && cp <= 0xDFFF) ? cp : 0xFFFD)
                    }
                    continue
                }
                // A sequence cut short: what it had becomes one replacement character and this byte starts afresh.
                utf8Need = 0
                feedCode(0xFFFD)
            }
            if b < 0x80 { feedCode(UInt32(b)) }
            else if b & 0xE0 == 0xC0 { utf8CP = UInt32(b & 0x1F); utf8Need = 1 }
            else if b & 0xF0 == 0xE0 { utf8CP = UInt32(b & 0x0F); utf8Need = 2 }
            else if b & 0xF8 == 0xF0 { utf8CP = UInt32(b & 0x07); utf8Need = 3 }
            else { feedCode(0xFFFD) }
        }
        if let onResponse, let r = takeResponse() { onResponse(r) }
    }
    func feed(_ text: String) { feed(Array(text.utf8)) }

    // MARK: - Resizing

    private func regrid(_ old: [VTCell], _ newCols: Int, _ newRows: Int, _ shift: Int) -> [VTCell] {
        let b = VTCell.blank
        var grid = [VTCell](repeating: b, count: newCols * newRows)
        let keep = min(newCols, cols)
        for gy in 0..<newRows {
            let from = gy + shift
            if from < 0 || from >= rows { continue }
            grid.replaceSubrange((gy * newCols)..<(gy * newCols + keep), with: old[(from * cols)..<(from * cols + keep)])
            // A wide character cut in half at the new edge goes.
            if keep < cols && keep > 0 && grid[gy * newCols + keep - 1].attr.contains(.wide) { grid[gy * newCols + keep - 1] = b }
        }
        return grid
    }

    /// A new size; the cursor's line stays on screen, lines pushed off the top go to the scrollback.
    func resize(cols newCols: Int, rows newRows: Int) {
        let newCols = max(newCols, 1), newRows = max(newRows, 1)
        if newCols == cols && newRows == rows { return }
        // Lines above a cursor that would fall off the bottom move into the scrollback, as the screen shrinks from the top.
        let shift = y >= newRows ? y - newRows + 1 : 0
        if shift > 0 && !onAlt { for r in 0..<shift { pushScrollback(main[(r * cols)..<((r + 1) * cols)]) } }
        let altShift = onAlt ? shift : 0, mainShift = onAlt ? 0 : shift
        let m = regrid(main, newCols, newRows, mainShift), a = regrid(alt, newCols, newRows, altShift)
        main = m; alt = a
        cols = newCols; rows = newRows
        tabs = [Bool](repeating: false, count: newCols)
        resetTabs()
        top = 0; bottom = newRows - 1
        y = clamp(y - shift, 0, newRows - 1)
        x = clamp(x, 0, newCols - 1)
        wrapPending = false
        saved.x = clamp(saved.x, 0, newCols - 1); saved.y = clamp(saved.y - mainShift, 0, newRows - 1)
        savedAlt.x = clamp(savedAlt.x, 0, newCols - 1); savedAlt.y = clamp(savedAlt.y - altShift, 0, newRows - 1)
    }
}
