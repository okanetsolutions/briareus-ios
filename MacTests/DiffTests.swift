// Ported from the Windows client's tests/core_diff_tests.c.
import XCTest
@testable import BriareusMacCore

final class DiffTests: XCTestCase {
    /// Lines written out one per row as "kind old new text", kinds as @ + - = \.
    private func desc(_ patch: String) -> String {
        diffParse(patch).map { line in
            let k: String
            switch line.kind { case .hunk: k = "@"; case .added: k = "+"; case .removed: k = "-"; case .context: k = "="; case .note: k = "\\" }
            return "\(k) \(line.oldLine) \(line.newLine) \(line.text)\n"
        }.joined()
    }

    func testNilAndEmptyPatchesHaveNoLines() {
        XCTAssertEqual(diffParse(nil).count, 0)
        XCTAssertEqual(diffParse("").count, 0)
    }
    func testALoneNewlineIsOneEmptyContextLine() { XCTAssertEqual(desc("\n"), "= 0 0 \n") }
    func testCountsInHunkHeadersAreOptional() {
        XCTAssertEqual(desc("@@ -5 +7 @@\n a\n-b\n+c"), "@ 0 0 @@ -5 +7 @@\n= 5 7 a\n- 6 0 b\n+ 0 8 c\n")
        XCTAssertEqual(desc("@@ -5,2 +7 @@\n a"), "@ 0 0 @@ -5,2 +7 @@\n= 5 7 a\n")
        XCTAssertEqual(desc("@@ -5 +7,3 @@\n a"), "@ 0 0 @@ -5 +7,3 @@\n= 5 7 a\n")
        // Without the closing @@ the numbers still read.
        XCTAssertEqual(desc("@@ -3 +4\n a"), "@ 0 0 @@ -3 +4\n= 3 4 a\n")
    }
    func testHunkTextKeepsTheWholeHeaderWithItsContext() {
        let lines = diffParse("@@ -1,2 +1,2 @@ static int main(void) {\n x")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.first, DiffLine(id: 0, kind: .hunk, text: "@@ -1,2 +1,2 @@ static int main(void) {", oldLine: 0, newLine: 0))
    }
    func testAddedRemovedAndContextLinesCountTheirOwnSides() {
        XCTAssertEqual(desc("@@ -10,4 +20,5 @@\n keep\n-gone1\n-gone2\n+new1\n+new2\n+new3\n keep2\n-last"),
                       "@ 0 0 @@ -10,4 +20,5 @@\n= 10 20 keep\n- 11 0 gone1\n- 12 0 gone2\n+ 0 21 new1\n+ 0 22 new2\n+ 0 23 new3\n= 13 24 keep2\n- 14 0 last\n")
    }
    func testEachHunkRestartsTheNumbering() {
        XCTAssertEqual(desc("@@ -1,2 +1,2 @@\n-a\n+b\n c\n@@ -50,1 +60,2 @@\n x\n+y\n@@ -100 +101 @@\n-z"),
                       "@ 0 0 @@ -1,2 +1,2 @@\n- 1 0 a\n+ 0 1 b\n= 2 2 c\n"
                       + "@ 0 0 @@ -50,1 +60,2 @@\n= 50 60 x\n+ 0 61 y\n"
                       + "@ 0 0 @@ -100 +101 @@\n- 100 0 z\n")
    }
    func testNewAndDeletedFilesNumberFromTheirSingleSide() {
        XCTAssertEqual(desc("@@ -0,0 +1,3 @@\n+one\n+two\n+three\n"), "@ 0 0 @@ -0,0 +1,3 @@\n+ 0 1 one\n+ 0 2 two\n+ 0 3 three\n")
        XCTAssertEqual(desc("@@ -1,2 +0,0 @@\n-one\n-two\n"), "@ 0 0 @@ -1,2 +0,0 @@\n- 1 0 one\n- 2 0 two\n")
    }
    func testNoNewlineNotesTakeNoLineNumber() {
        XCTAssertEqual(desc("@@ -1 +1 @@\n-old\n\\ No newline at end of file\n+new\n\\ No newline at end of file\n"),
                       "@ 0 0 @@ -1 +1 @@\n- 1 0 old\n\\ 0 0 No newline at end of file\n+ 0 1 new\n\\ 0 0 No newline at end of file\n")
        XCTAssertEqual(desc("@@ -1 +1 @@\n\\No space\n\\   many\n\\"), "@ 0 0 @@ -1 +1 @@\n\\ 0 0 No space\n\\ 0 0 many\n\\ 0 0 \n")
        // A note between context lines leaves the count running.
        XCTAssertEqual(desc("@@ -7 +7 @@\n a\n\\ note\n b"), "@ 0 0 @@ -7 +7 @@\n= 7 7 a\n\\ 0 0 note\n= 8 8 b\n")
    }
    func testLineTextDropsOnlyTheFirstColumn() {
        XCTAssertEqual(desc("@@ -1 +1 @@\n+  indented\n-\t tab\n   two spaces\n+\n-\n \n++x\n--y"),
                       "@ 0 0 @@ -1 +1 @@\n+ 0 1   indented\n- 1 0 \t tab\n= 2 2   two spaces\n+ 0 3 \n- 3 0 \n= 4 4 \n+ 0 5 +x\n- 5 0 -y\n")
    }
    func testEmptyLinesInsideAHunkAreContext() {
        XCTAssertEqual(desc("@@ -1,3 +1,3 @@\n a\n\n b"), "@ 0 0 @@ -1,3 +1,3 @@\n= 1 1 a\n= 2 2 \n= 3 3 b\n")
    }
    func testOnlyOneFinalNewlineIsDropped() {
        XCTAssertEqual(desc("@@ -1 +1 @@\n a\n"), "@ 0 0 @@ -1 +1 @@\n= 1 1 a\n")
        XCTAssertEqual(desc("@@ -1 +1 @@\n a\n\n"), "@ 0 0 @@ -1 +1 @@\n= 1 1 a\n= 2 2 \n")
        XCTAssertEqual(desc("@@ -1 +1 @@\n a"), "@ 0 0 @@ -1 +1 @@\n= 1 1 a\n")
    }
    func testCRLFAndLoneCREndLinesLikeLF() {
        XCTAssertEqual(desc("@@ -1,2 +1,2 @@\r\n a\r\n-b\r\n+c\r\n"), "@ 0 0 @@ -1,2 +1,2 @@\n= 1 1 a\n- 2 0 b\n+ 0 2 c\n")
        XCTAssertEqual(desc("@@ -1 +1 @@\r-b\r+c\r"), "@ 0 0 @@ -1 +1 @@\n- 1 0 b\n+ 0 1 c\n")
        // CR LF is one break, LF CR is two.
        XCTAssertEqual(desc("@@ -1 +1 @@\n a\n\r b"), "@ 0 0 @@ -1 +1 @@\n= 1 1 a\n= 2 2 \n= 3 3 b\n")
        let lines = diffParse("+x\r\n")
        XCTAssertEqual(lines.count, 1)
        XCTAssertFalse(lines[0].text.unicodeScalars.contains("\r"))
    }
    func testMalformedHunkHeadersKeepTheRunningNumbers() {
        for header in ["@@ bogus @@", "@@ -x +1 @@", "@@ -1 +y @@", "@@ -1;2 +1 @@", "@@ +1 -1 @@", "@@", "@@ -9"] {
            XCTAssertEqual(desc("@@ -3 +4 @@\n a\n\(header)\n b"), "@ 0 0 @@ -3 +4 @@\n= 3 4 a\n@ 0 0 \(header)\n= 4 5 b\n", header)
        }
    }
    func testIdsFollowTheLineOrder() {
        let lines = diffParse("@@ -1 +1 @@\n a\n\\ note\n-b\n+c\n@@ -9 +9 @@\n d")
        XCTAssertEqual(lines.map(\.id), Array(0..<7))
    }
    func testLongPatchesKeepEveryLine() {
        var patch = "@@ -1,300 +1,300 @@\n"
        for i in 0..<300 { patch += "\(i % 3 == 0 ? " " : i % 3 == 1 ? "-" : "+")\(i)\n" }
        let lines = diffParse(patch)
        XCTAssertEqual(lines.count, 301)
        guard lines.count == 301 else { return }
        XCTAssertEqual(lines[300].id, 300); XCTAssertEqual(lines[300].kind, .added); XCTAssertEqual(lines[300].text, "299"); XCTAssertEqual(lines[300].newLine, 200)
        XCTAssertEqual(lines[298].kind, .context); XCTAssertEqual(lines[298].oldLine, 199); XCTAssertEqual(lines[298].newLine, 199)
        XCTAssertEqual(lines[299].kind, .removed); XCTAssertEqual(lines[299].oldLine, 200)
    }
}
