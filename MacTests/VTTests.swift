// Ported from the Windows client's tests/core_vt_tests.c: printing and wrapping, cursor moves, erases, scroll regions and
// the scrollback, SGR colours, the alternate screen, line drawing, titles, the reports it answers with, and resizing.
import XCTest
@testable import BriareusMacCore

final class VTTests: XCTestCase {
    private func put(_ vt: VTerminal, _ s: String) { vt.feed(s) }
    /// A screen row as text, trailing blanks dropped.
    private func row(_ vt: VTerminal, _ y: Int) -> String { vt.text(y0: y, x0: 0, y1: y, x1: vt.cols) }
    private func ch(_ vt: VTerminal, _ y: Int, _ x: Int) -> UInt32 { vt.cell(x: x, y: y)?.ch ?? 0 }

    func testPrintsTextAndMovesTheCursor() {
        let vt = VTerminal(cols: 10, rows: 3, scrollback: 100)
        put(vt, "hello")
        XCTAssertEqual(row(vt, 0), "hello")
        XCTAssertEqual(vt.cursor.x, 5); XCTAssertEqual(vt.cursor.y, 0); XCTAssertTrue(vt.cursor.visible)
        put(vt, "\r\nworld")
        XCTAssertEqual(row(vt, 1), "world")
    }

    func testWrapsAtTheEdgeOnlyWhenTheNextCharacterComes() {
        let vt = VTerminal(cols: 4, rows: 3, scrollback: 100)
        put(vt, "abcd")
        XCTAssertEqual(vt.cursor.x, 3); XCTAssertEqual(vt.cursor.y, 0)
        put(vt, "e")
        XCTAssertEqual(row(vt, 0), "abcd")
        XCTAssertEqual(row(vt, 1), "e")
        // A carriage return at the edge cancels the pending wrap.
        put(vt, "fgh\rX")
        XCTAssertEqual(row(vt, 1), "Xfgh")
    }

    func testScrollingOffTheTopFeedsTheScrollback() {
        let vt = VTerminal(cols: 8, rows: 2, scrollback: 100)
        put(vt, "one\r\ntwo\r\nthree\r\nfour")
        XCTAssertEqual(vt.scrollbackCount, 2)
        XCTAssertEqual(vt.text(y0: -2, x0: 0, y1: -2, x1: 8), "one")
        XCTAssertEqual(vt.text(y0: -1, x0: 0, y1: -1, x1: 8), "two")
        XCTAssertEqual(row(vt, 0), "three")
        XCTAssertEqual(row(vt, 1), "four")
        XCTAssertEqual(vt.text(y0: -1, x0: 0, y1: 0, x1: 8), "two\r\nthree")
        XCTAssertEqual(vt.linesPushed, 2)
        vt.clearScrollback()
        XCTAssertEqual(vt.scrollbackCount, 0)
    }

    func testTheScrollbackKeepsOnlyItsCapacity() {
        let vt = VTerminal(cols: 8, rows: 1, scrollback: 3)
        for i in 0..<10 { put(vt, "l\(i)\r\n") }
        XCTAssertEqual(vt.scrollbackCount, 3)
        XCTAssertEqual(vt.text(y0: -3, x0: 0, y1: -3, x1: 8), "l7")
        XCTAssertEqual(vt.text(y0: -1, x0: 0, y1: -1, x1: 8), "l9")
        XCTAssertNil(vt.line(-4))
    }

    func testCursorPositionAndErases() {
        let vt = VTerminal(cols: 10, rows: 4, scrollback: 100)
        put(vt, "aaaaaaaaaa\r\nbbbbbbbbbb\r\ncccccccccc\r\ndddddddddd")
        put(vt, "\u{1b}[2;4H\u{1b}[K")
        XCTAssertEqual(row(vt, 1), "bbb")
        put(vt, "\u{1b}[1;3H\u{1b}[1K")
        XCTAssertEqual(row(vt, 0), "   aaaaaaa")
        put(vt, "\u{1b}[3;5H\u{1b}[J")
        XCTAssertEqual(row(vt, 2), "cccc")
        XCTAssertEqual(row(vt, 3), "")
        put(vt, "\u{1b}[2J")
        for y in 0..<4 { XCTAssertEqual(row(vt, y), "") }
    }

    func testRelativeMovesStopAtTheEdges() {
        let vt = VTerminal(cols: 10, rows: 5, scrollback: 100)
        put(vt, "\u{1b}[3;3H\u{1b}[10A")
        XCTAssertEqual(vt.cursor.y, 0); XCTAssertEqual(vt.cursor.x, 2)
        put(vt, "\u{1b}[20C\u{1b}[2B")
        XCTAssertEqual(vt.cursor.x, 9); XCTAssertEqual(vt.cursor.y, 2)
        put(vt, "\u{1b}[4D\u{1b}[G")
        XCTAssertEqual(vt.cursor.x, 0)
        // Empty parameters take their defaults.
        put(vt, "\u{1b}[;5H")
        XCTAssertEqual(vt.cursor.x, 4); XCTAssertEqual(vt.cursor.y, 0)
    }

    func testInsertAndDeleteCharactersAndLines() {
        let vt = VTerminal(cols: 8, rows: 3, scrollback: 100)
        put(vt, "abcdef\u{1b}[1;3H\u{1b}[2@")
        XCTAssertEqual(row(vt, 0), "ab  cdef")
        put(vt, "\u{1b}[3P")
        XCTAssertEqual(row(vt, 0), "abdef")
        put(vt, "\u{1b}[1;1H\u{1b}[2;1Hline2\u{1b}[3;1Hline3\u{1b}[2;1H\u{1b}[L")
        XCTAssertEqual(row(vt, 1), "")
        XCTAssertEqual(row(vt, 2), "line2")
        put(vt, "\u{1b}[M")
        XCTAssertEqual(row(vt, 1), "line2")
        put(vt, "\u{1b}[1;2H\u{1b}[2X")
        XCTAssertEqual(row(vt, 0), "a  ef")
    }

    func testAScrollRegionScrollsInsideItselfWithoutTheScrollback() {
        let vt = VTerminal(cols: 6, rows: 4, scrollback: 100)
        put(vt, "top\r\nr1\r\nr2\r\nbottom")
        put(vt, "\u{1b}[2;3r\u{1b}[3;1H\nnew")
        XCTAssertEqual(row(vt, 0), "top")
        XCTAssertEqual(row(vt, 1), "r2")
        XCTAssertEqual(row(vt, 2), "new")
        XCTAssertEqual(row(vt, 3), "bottom")
        XCTAssertEqual(vt.scrollbackCount, 0)
        // Reverse index at the region's top scrolls it down.
        put(vt, "\u{1b}[2;1H\u{1b}M")
        XCTAssertEqual(row(vt, 1), "")
        XCTAssertEqual(row(vt, 2), "r2")
        XCTAssertEqual(row(vt, 3), "bottom")
    }

    func testSGRSetsColoursAndAttributes() throws {
        let vt = VTerminal(cols: 10, rows: 2, scrollback: 100)
        put(vt, "\u{1b}[1;31mA\u{1b}[0;4;38;5;200;48;2;1;2;3mB\u{1b}[0;97;104mC\u{1b}[7mD\u{1b}[27;39mE")
        let a = try XCTUnwrap(vt.cell(x: 0, y: 0)), b = try XCTUnwrap(vt.cell(x: 1, y: 0)), c = try XCTUnwrap(vt.cell(x: 2, y: 0))
        let d = try XCTUnwrap(vt.cell(x: 3, y: 0)), e = try XCTUnwrap(vt.cell(x: 4, y: 0))
        XCTAssertTrue(a.attr.contains(.bold)); XCTAssertEqual(a.fg, .indexed(1)); XCTAssertEqual(a.bg, .default)
        XCTAssertFalse(b.attr.contains(.bold)); XCTAssertTrue(b.attr.contains(.underline))
        XCTAssertEqual(b.fg, .indexed(200)); XCTAssertEqual(b.bg, .rgb(0x010203))
        XCTAssertEqual(c.fg, .indexed(15)); XCTAssertEqual(c.bg, .indexed(12))
        XCTAssertTrue(d.attr.contains(.inverse))
        XCTAssertFalse(e.attr.contains(.inverse)); XCTAssertEqual(e.fg, .default); XCTAssertEqual(e.bg, .indexed(12))
        // An erase takes the current background, as xterm's does.
        put(vt, "\u{1b}[2;1H\u{1b}[K")
        XCTAssertEqual(vt.cell(x: 5, y: 1)?.bg, .indexed(12))
    }

    func testTheAlternateScreenKeepsTheMainOne() {
        let vt = VTerminal(cols: 8, rows: 2, scrollback: 100)
        put(vt, "shell$ ")
        put(vt, "\u{1b}[?1049h")
        XCTAssertTrue(vt.altScreen)
        XCTAssertEqual(row(vt, 0), "")
        put(vt, "vim\r\n\r\n\r\n")   // the alternate screen never feeds the scrollback
        XCTAssertEqual(vt.scrollbackCount, 0)
        put(vt, "\u{1b}[?1049l")
        XCTAssertFalse(vt.altScreen)
        XCTAssertEqual(row(vt, 0), "shell$")
        XCTAssertEqual(vt.cursor.x, 7); XCTAssertEqual(vt.cursor.y, 0)
    }

    func testUTF8SplitAcrossWritesAndWideCharacters() {
        let vt = VTerminal(cols: 6, rows: 2, scrollback: 100)
        let s: [UInt8] = [0xC3, 0xA9, 0xE4, 0xB8, 0xAD]   // é 中
        vt.feed(s[0..<1]); vt.feed(s[1..<3]); vt.feed(s[3..<5])
        XCTAssertEqual(ch(vt, 0, 0), 0xE9)
        XCTAssertEqual(ch(vt, 0, 1), 0x4E2D)
        XCTAssertTrue(vt.cell(x: 1, y: 0)!.attr.contains(.wide))
        XCTAssertTrue(vt.cell(x: 2, y: 0)!.attr.contains(.wideTail))
        XCTAssertEqual(vt.cursor.x, 3)
        XCTAssertEqual(row(vt, 0), "é中")
        // A wide character at the last column wraps whole.
        put(vt, "ab中")
        XCTAssertEqual(row(vt, 0), "é中ab")
        XCTAssertEqual(row(vt, 1), "中")
        // A broken sequence becomes one replacement character.
        vt.feed([0x0D, 0x0A, 0xE4, 0x7A, 0x7A])
        XCTAssertEqual(row(vt, 1), "\u{FFFD}zz")
    }

    func testDECLineDrawing() {
        let vt = VTerminal(cols: 6, rows: 1, scrollback: 100)
        put(vt, "\u{1b}(0lqk\u{1b}(Bq")
        XCTAssertEqual(ch(vt, 0, 0), 0x250C)
        XCTAssertEqual(ch(vt, 0, 1), 0x2500)
        XCTAssertEqual(ch(vt, 0, 2), 0x2510)
        XCTAssertEqual(ch(vt, 0, 3), UInt32(UInt8(ascii: "q")))
    }

    func testTitlesAndTheBell() {
        let vt = VTerminal(cols: 6, rows: 1, scrollback: 100)
        XCTAssertNil(vt.title)
        put(vt, "\u{1b}]0;user@host: ~\u{07}")
        XCTAssertEqual(vt.title, "user@host: ~")
        XCTAssertTrue(vt.takeTitleChanged())
        XCTAssertFalse(vt.takeTitleChanged())
        put(vt, "\u{1b}]2;sp")
        put(vt, "lit\u{1b}\\x")
        XCTAssertEqual(vt.title, "split")
        XCTAssertEqual(row(vt, 0), "x")
        // Other strings are skipped whole.
        put(vt, "\u{1b}Pq#0;2;0;0;0\u{1b}\\y\u{07}")
        XCTAssertEqual(row(vt, 0), "xy")
        XCTAssertTrue(vt.takeBell())
        XCTAssertFalse(vt.takeBell())
    }

    func testReportsAnswerTheProgram() {
        let vt = VTerminal(cols: 10, rows: 5, scrollback: 100)
        XCTAssertNil(vt.takeResponse())
        put(vt, "\u{1b}[3;4H\u{1b}[6n\u{1b}[c")
        XCTAssertEqual(vt.takeResponse(), Data("\u{1b}[3;4R\u{1b}[?62;22c".utf8))
        XCTAssertNil(vt.takeResponse())
        // With a callback the answer goes out as the bytes are fed.
        var sent: [Data] = []
        vt.onResponse = { sent.append($0) }
        put(vt, "\u{1b}[5n\u{1b}[>c")
        XCTAssertEqual(sent, [Data("\u{1b}[0n\u{1b}[>1;10;0c".utf8)])
        XCTAssertNil(vt.takeResponse())
    }

    func testModesTheKeyboardDependsOn() {
        let vt = VTerminal(cols: 10, rows: 5, scrollback: 100)
        XCTAssertFalse(vt.appCursor); XCTAssertFalse(vt.bracketedPaste)
        put(vt, "\u{1b}[?1h\u{1b}[?2004h\u{1b}=\u{1b}[?25l")
        XCTAssertTrue(vt.appCursor); XCTAssertTrue(vt.bracketedPaste); XCTAssertTrue(vt.appKeypad)
        XCTAssertFalse(vt.cursor.visible)
        XCTAssertFalse(vt.focusEvents); XCTAssertFalse(vt.win32Input)
        put(vt, "\u{1b}[?9001h\u{1b}[?1004h")
        XCTAssertTrue(vt.focusEvents); XCTAssertTrue(vt.win32Input)
        put(vt, "\u{1b}[?9001l")
        XCTAssertFalse(vt.win32Input); XCTAssertTrue(vt.focusEvents)
        put(vt, "\u{1b}c")
        XCTAssertFalse(vt.appCursor); XCTAssertFalse(vt.bracketedPaste); XCTAssertFalse(vt.focusEvents)
    }

    func testResizingKeepsTheCursorLineOnScreen() {
        let vt = VTerminal(cols: 10, rows: 4, scrollback: 100)
        put(vt, "1\r\n2\r\n3\r\n4")
        vt.resize(cols: 6, rows: 2)
        XCTAssertEqual(vt.cols, 6); XCTAssertEqual(vt.rows, 2)
        XCTAssertEqual(row(vt, 0), "3")
        XCTAssertEqual(row(vt, 1), "4")
        XCTAssertEqual(vt.scrollbackCount, 2)
        XCTAssertEqual(vt.cursor.y, 1); XCTAssertEqual(vt.cursor.x, 1)
        vt.resize(cols: 12, rows: 3)
        XCTAssertEqual(row(vt, 0), "3")
        put(vt, "\r\n\r\nabcdefghijkl")
        XCTAssertEqual(row(vt, 2), "abcdefghijkl")
    }

    func testTabsAndBackspace() {
        let vt = VTerminal(cols: 20, rows: 1, scrollback: 100)
        put(vt, "a\tb\u{08}c")
        XCTAssertEqual(row(vt, 0), "a       c")
    }

    func testCharWidthsAndThePalette() {
        XCTAssertEqual(VTerminal.charWidth(UInt32(UInt8(ascii: "a"))), 1)
        XCTAssertEqual(VTerminal.charWidth(0x0301), 0)
        XCTAssertEqual(VTerminal.charWidth(0x4E2D), 2)
        XCTAssertEqual(VTerminal.charWidth(0x1F600), 2)
        XCTAssertEqual(VTerminal.indexRGB(16), 0x000000)
        XCTAssertEqual(VTerminal.indexRGB(231), 0xFFFFFF)
        XCTAssertEqual(VTerminal.indexRGB(232), 0x080808)
    }

    // MARK: - Beyond the C suite

    func testScrollbackLinesDropTrailingBlanksAndOneColumnScreensSurviveWideCharacters() {
        let vt = VTerminal(cols: 8, rows: 1, scrollback: 10)
        put(vt, "ab\r\n")
        XCTAssertEqual(vt.line(-1)?.count, 2)
        let narrow = VTerminal(cols: 1, rows: 2, scrollback: 10)
        narrow.feed("中中")
        XCTAssertEqual(narrow.text(y0: 1, x0: 0, y1: 1, x1: 1), "中")
    }

    func testTerminalInputEncodesKeysAndPastes() {
        XCTAssertEqual(TerminalInput.encode(.up), Array("\u{1b}[A".utf8))
        XCTAssertEqual(TerminalInput.encode(.up, appCursor: true), Array("\u{1b}OA".utf8))
        XCTAssertEqual(TerminalInput.encode(.left, modifiers: [.ctrl, .shift]), Array("\u{1b}[1;6D".utf8))
        XCTAssertEqual(TerminalInput.encode(.home, appCursor: true), Array("\u{1b}OH".utf8))
        XCTAssertEqual(TerminalInput.encode(.delete), Array("\u{1b}[3~".utf8))
        XCTAssertEqual(TerminalInput.encode(.pageUp, modifiers: .alt), Array("\u{1b}[5;3~".utf8))
        XCTAssertEqual(TerminalInput.encode(.function(1)), Array("\u{1b}OP".utf8))
        XCTAssertEqual(TerminalInput.encode(.function(4), modifiers: .shift), Array("\u{1b}[1;2S".utf8))
        XCTAssertEqual(TerminalInput.encode(.function(5)), Array("\u{1b}[15~".utf8))
        XCTAssertEqual(TerminalInput.encode(.function(12), modifiers: .ctrl), Array("\u{1b}[24;5~".utf8))
        XCTAssertEqual(TerminalInput.encode(.backspace), [0x7F])
        XCTAssertEqual(TerminalInput.encode(.backspace, modifiers: [.alt, .ctrl]), [0x1B, 0x08])
        XCTAssertEqual(TerminalInput.encode(.tab, modifiers: .shift), Array("\u{1b}[Z".utf8))
        XCTAssertEqual(TerminalInput.encode(.space, modifiers: .ctrl), [0])
        XCTAssertEqual(TerminalInput.control("c"), 3)
        XCTAssertEqual(TerminalInput.control("["), 0x1B)
        XCTAssertEqual(TerminalInput.text("é", alt: true), [0x1B, 0xC3, 0xA9])
        XCTAssertEqual(TerminalInput.paste("a\r\nb\n\u{1b}c", bracketed: true), Array("\u{1b}[200~a\rb\rc\u{1b}[201~".utf8))
        XCTAssertEqual(TerminalInput.wheel(notches: -1, altScreen: true, appCursor: false), Array("\u{1b}[B\u{1b}[B\u{1b}[B".utf8))
        XCTAssertNil(TerminalInput.wheel(notches: 1, altScreen: false, appCursor: false))
    }

    func testTargetsAndTheirArguments() {
        var t = TermTarget(key: "k", group: "g", label: "", user: "me", host: "example.com", port: 22)
        XCTAssertNil(t.problem)
        XCTAssertEqual(t.sshArguments, ["-p", "22", "-l", "me", "--", "example.com"])
        XCTAssertEqual(t.sftpArguments, ["-P", "22", "-o", "User=me", "-o", "ServerAliveInterval=30", "--", "example.com"])
        XCTAssertEqual(t.display, "me@example.com:22")
        t.host = "-oProxyCommand=x"; XCTAssertNotNil(t.problem)
        t.host = "a b"; XCTAssertNotNil(t.problem)
        t.host = "[::1]"; XCTAssertNil(t.problem)
        t.user = ""; XCTAssertEqual(t.problem, "This server has no username.")
        t.user = "DOMAIN\\me"; XCTAssertNil(t.problem)
        t.port = 0; XCTAssertEqual(t.problem, "The port 0 is not from 1 to 65535.")
    }

    func testSelectionFollowsItsTextAndCopies() {
        let vt = VTerminal(cols: 10, rows: 2, scrollback: 100)
        vt.feed("hello world\r\nnext")
        var view = TerminalView()
        let base = TerminalView.lineBase(vt)
        // The screen is "d" / "next" with "hello worl" above it.
        view.begin(at: TermMark(line: base - 1, col: 0))
        view.drag(to: TermMark(line: base, col: 1))
        XCTAssertEqual(view.selectionText(vt: vt), "hello worl\r\nd")
        XCTAssertTrue(view.isSelected(vt: vt, line: -1, col: 3))
        XCTAssertFalse(view.isSelected(vt: vt, line: 0, col: 1))
        view.selectWord(vt: vt, at: TermMark(line: base + 1, col: 2))
        XCTAssertEqual(view.selectionText(vt: vt), "next")
        // New lines push the text up; the marks stay on it, and a scrolled-back view follows.
        view.offset = 1
        let before = vt.linesPushed
        vt.feed("\r\nmore")
        view.follow(vt: vt, pushedBefore: before)
        XCTAssertEqual(view.offset, 2)
        XCTAssertEqual(view.selectionText(vt: vt), "next")
        view.selectAll(vt: vt)
        XCTAssertEqual(view.selectionText(vt: vt), "hello worl\r\nd\r\nnext\r\nmore")
        let m = view.mark(x: 6 + 8 * 2.6, y: 6 + 17, cellWidth: 8, cellHeight: 16, padding: 6, vt: vt)
        XCTAssertEqual(m, TermMark(line: TerminalView.lineBase(vt) + 1 - 2, col: 3))
    }

    func testPaletteResolvesColours() {
        XCTAssertEqual(TerminalPalette.resolve(.indexed(1), foreground: true, bold: true, dark: true), 0xEF8790)
        XCTAssertEqual(TerminalPalette.resolve(.indexed(196), foreground: true, bold: false, dark: true), 0xFF0000)
        XCTAssertEqual(TerminalPalette.resolve(.default, foreground: false, bold: false, dark: false), 0xFBFAF6)
        let inverse = VTCell(ch: 0x41, fg: .rgb(0x102030), bg: .default, attr: .inverse)
        XCTAssertEqual(TerminalPalette.colors(of: inverse, dark: true).bg, 0x102030)
    }
}
