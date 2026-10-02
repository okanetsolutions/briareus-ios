// Ported from the Windows client's tests/core_markdown_tests.c.
import XCTest
@testable import BriareusMacCore

final class MarkdownTests: XCTestCase {
    /// Blocks written out as one string: <kind attrs>text for each, so a whole parse reads as one expectation.
    private func blocks(_ source: String?) -> String {
        var s = ""
        for k in Markdown.parse(source) {
            switch k.kind {
            case .paragraph: s += "<p>"
            case .heading: s += "<h\(k.level)>"
            case .bullet: s += "<li\(k.indent) \(k.marker ?? "")\(k.task == .unchecked ? " [ ]" : k.task == .checked ? " [x]" : "")>"
            case .quote: s += "<quote>"
            case .code: s += "<code\(k.language.map { " " + $0 } ?? "")>"
            case .rule: s += "<hr>"
            case .table:
                s += "<table \(String(k.aligns.map(\.rawValue))) \(k.rows)x\(k.cols)>"
                s += k.cells.flatMap { $0 }.joined(separator: "|")
            }
            s += k.text
        }
        return s
    }

    /// Spans written out as [flags:text@url], flags as B I C L S.
    private func spans(_ text: String?) -> String {
        var s = ""
        for span in Markdown.inline(text) {
            s += "["
            if span.flags.contains(.bold) { s += "B" }
            if span.flags.contains(.italic) { s += "I" }
            if span.flags.contains(.code) { s += "C" }
            if span.flags.contains(.link) { s += "L" }
            if span.flags.contains(.strike) { s += "S" }
            s += ":" + span.text
            if let url = span.url { s += "@" + url }
            s += "]"
        }
        return s
    }

    func testEmptyAndNullSourcesHaveNoBlocks() {
        XCTAssertEqual(Markdown.parse(nil).count, 0)
        XCTAssertEqual(Markdown.parse("").count, 0)
        XCTAssertEqual(Markdown.parse("\n\n  \n\t\n").count, 0)
    }
    func testHeadingsTakeOneToSixHashesAndASpace() {
        XCTAssertEqual(blocks("# One\n## Two\n### Three\n#### Four\n##### Five\n###### Six"), "<h1>One<h2>Two<h3>Three<h4>Four<h5>Five<h6>Six")
        XCTAssertEqual(blocks("####### Seven"), "<p>####### Seven")
        XCTAssertEqual(blocks("#nospace"), "<p>#nospace")
        XCTAssertEqual(blocks("#\ttab"), "<p>#\ttab")
        XCTAssertEqual(blocks("#"), "<p>#")
        XCTAssertEqual(blocks("#   Spaced   out   "), "<h1>Spaced   out")
        XCTAssertEqual(blocks("   ## Indented"), "<h2>Indented")
        XCTAssertEqual(blocks("## Keeps **bold** markers"), "<h2>Keeps **bold** markers")
    }
    func testHeadingsAndRulesEndAParagraph() {
        XCTAssertEqual(blocks("intro\n# Title\nbody"), "<p>intro<h1>Title<p>body")
        XCTAssertEqual(blocks("above\n---\nbelow"), "<p>above<hr><p>below")
    }
    func testParagraphLinesJoinAndBlankLinesSplitThem() {
        XCTAssertEqual(blocks("one\ntwo\nthree"), "<p>one\ntwo\nthree")
        XCTAssertEqual(blocks("one\n\ntwo"), "<p>one<p>two")
        XCTAssertEqual(blocks("one\n   \n\t\ntwo"), "<p>one<p>two")
        XCTAssertEqual(blocks("\n\none\n\n\n"), "<p>one")
        XCTAssertEqual(blocks("  indented\nflush"), "<p>  indented\nflush")
    }
    func testCrlfSourcesParseLikeLf() {
        XCTAssertEqual(blocks("# Title\r\none\r\ntwo\r\n\r\n- item\r\n```c\r\nx\r\n```\r\n"), "<h1>Title<p>one\ntwo<li0 \u{2022}>item<code c>x")
    }
    func testRulesNeedThreeOfTheSameMark() {
        XCTAssertEqual(blocks("---"), "<hr>")
        XCTAssertEqual(blocks("***"), "<hr>")
        XCTAssertEqual(blocks("___"), "<hr>")
        XCTAssertEqual(blocks("- - -"), "<hr>")
        XCTAssertEqual(blocks("* * *"), "<hr>")
        XCTAssertEqual(blocks("----------"), "<hr>")
        XCTAssertEqual(blocks("  ---  "), "<hr>")
        XCTAssertEqual(blocks("--"), "<p>--")
        XCTAssertEqual(blocks("-*-"), "<p>-*-")
        XCTAssertEqual(blocks("--- x"), "<p>--- x")
        XCTAssertEqual(blocks("==="), "<p>===")
    }
    func testBulletsTakeDashStarOrPlusAndNestByTwoSpaces() {
        XCTAssertEqual(blocks("- dash\n* star\n+ plus"), "<li0 \u{2022}>dash<li0 \u{2022}>star<li0 \u{2022}>plus")
        XCTAssertEqual(blocks("- a\n  - b\n    - c\n   - d\n\t- e\n\t\t- f"), "<li0 \u{2022}>a<li1 \u{2022}>b<li2 \u{2022}>c<li1 \u{2022}>d<li0 \u{2022}>e<li1 \u{2022}>f")
        XCTAssertEqual(blocks("-nospace"), "<p>-nospace")
        XCTAssertEqual(blocks("- "), "<li0 \u{2022}>")
        XCTAssertEqual(blocks("-  two spaces"), "<li0 \u{2022}> two spaces")
    }
    func testOrderedMarkersKeepTheirNumberWithADot() {
        XCTAssertEqual(blocks("1. one\n2) two\n10. ten\n999. big"), "<li0 1.>one<li0 2.>two<li0 10.>ten<li0 999.>big")
        XCTAssertEqual(blocks("  3. nested"), "<li1 3.>nested")
        XCTAssertEqual(blocks("1000. too long"), "<p>1000. too long")
        XCTAssertEqual(blocks("1.no space"), "<p>1.no space")
        XCTAssertEqual(blocks("1:x"), "<p>1:x")
        XCTAssertEqual(blocks("v1. not a number"), "<p>v1. not a number")
    }
    func testAParagraphEndsWhereAListStarts() {
        XCTAssertEqual(blocks("Steps:\n1. one\n2. two\nafter"), "<p>Steps:<li0 1.>one<li0 2.>two<p>after")
    }
    func testIndentedLinesContinueTheListItemAbove() {
        XCTAssertEqual(blocks("- one\n  more\n   and more\nflush"), "<li0 \u{2022}>one\nmore\nand more<p>flush")
        XCTAssertEqual(blocks("- one\n\n  later"), "<li0 \u{2022}>one\nlater")
        XCTAssertEqual(blocks("- one\n\tafter tab"), "<li0 \u{2022}>one<p>\tafter tab")
    }
    func testTaskItemsCarryTheirBox() {
        XCTAssertEqual(blocks("- [ ] open\n- [x] done\n- [X] Done\n+ [ ]\n- [x]\n1. [x] numbered"), "<li0 \u{2022} [ ]>open<li0 \u{2022} [x]>done<li0 \u{2022} [x]>Done<li0 \u{2022} [ ]><li0 \u{2022} [x]><li0 1. [x]>numbered")
        XCTAssertEqual(blocks("- [ ]tight"), "<li0 \u{2022}>[ ]tight")
        XCTAssertEqual(blocks("- [y] other"), "<li0 \u{2022}>[y] other")
        XCTAssertEqual(blocks("- [] empty"), "<li0 \u{2022}>[] empty")
        XCTAssertEqual(blocks("  - [ ] nested"), "<li1 \u{2022} [ ]>nested")
        XCTAssertEqual(blocks("[ ] not a bullet"), "<p>[ ] not a bullet")
    }
    func testQuotesGatherLinesWithoutTheirMarker() {
        XCTAssertEqual(blocks("> one\n>two\n>   three  "), "<quote>one\ntwo\nthree")
        XCTAssertEqual(blocks("> a\n>\n> b"), "<quote>a\n\nb")
        XCTAssertEqual(blocks("> > nested"), "<quote>> nested")
        XCTAssertEqual(blocks("  > indented"), "<quote>indented")
        XCTAssertEqual(blocks("> # not a heading"), "<quote># not a heading")
    }
    func testQuotesEndAtBlankLinesAndOtherBlocks() {
        XCTAssertEqual(blocks("> q\n\n> r"), "<quote>q<quote>r")
        XCTAssertEqual(blocks("> q\nplain"), "<quote>q<p>plain")
        XCTAssertEqual(blocks("para\n> q"), "<p>para<quote>q")
        XCTAssertEqual(blocks("> q\n# H"), "<quote>q<h1>H")
        XCTAssertEqual(blocks("> q\n- item"), "<quote>q<li0 \u{2022}>item")
        XCTAssertEqual(blocks("> q\n```\nc\n```"), "<quote>q<code>c")
        XCTAssertEqual(blocks("> q\n---"), "<quote>q<hr>")
    }
    func testFencesKeepTheirLinesVerbatim() {
        XCTAssertEqual(blocks("```\n  indented\n# not heading\n- not bullet\n\n> not quote\n```"), "<code>  indented\n# not heading\n- not bullet\n\n> not quote")
        XCTAssertEqual(blocks("```python  \nx = 1\n```"), "<code python>x = 1")
        XCTAssertEqual(blocks("```   js\nx\n```"), "<code js>x")
        XCTAssertEqual(blocks("~~~sh\nls\n~~~"), "<code sh>ls")
        XCTAssertEqual(blocks("```\n```"), "<code>")
        XCTAssertEqual(blocks("```\n\n```"), "<code>")
        XCTAssertEqual(blocks("  ```\nx\n  ```  "), "<code>x")
        XCTAssertEqual(blocks("```\ncode\n```\nafter"), "<code>code<p>after")
        XCTAssertEqual(blocks("before\n```\ncode\n```"), "<p>before<code>code")
    }
    func testAFenceClosesOnlyOnItsOwnMarkAtLeastAsLong() {
        XCTAssertEqual(blocks("````\n```\n````"), "<code>```")
        XCTAssertEqual(blocks("```\n~~~\n```"), "<code>~~~")
        XCTAssertEqual(blocks("~~~\n```\n~~~"), "<code>```")
        XCTAssertEqual(blocks("```\nx\n``````"), "<code>x")
        XCTAssertEqual(blocks("```\n``` not closing\n```"), "<code>``` not closing")
    }
    func testAnUnterminatedFenceRunsToTheEnd() {
        XCTAssertEqual(blocks("```go\nfunc a() {}\n\n# still code"), "<code go>func a() {}\n\n# still code")
        XCTAssertEqual(blocks("text\n```"), "<p>text<code>")
        XCTAssertEqual(blocks("````\n```"), "<code>```")
    }
    func testTablesReadAlignmentsFromTheDelimiterRow() {
        XCTAssertEqual(blocks("| a | b | c | d |\n| --- | :--- | :---: | ---: |\n| 1 | 2 | 3 | 4 |"), "<table llcr 2x4>a|b|c|d|1|2|3|4")
        XCTAssertEqual(blocks("|a|b|\n|-|:-:|"), "<table lc 1x2>a|b")
        XCTAssertEqual(blocks("a | b\n--|--\n1 | 2"), "<table ll 2x2>a|b|1|2")
        XCTAssertEqual(blocks("| a |\n|---|\n| 1 |"), "<table l 2x1>a|1")
    }
    func testTableRowsArePaddedOrCutToTheHeader() {
        XCTAssertEqual(blocks("| a | b | c |\n|---|---|---|\n| 1 |\n| 1 | 2 | 3 | 4 | 5 |\n| | x | |"), "<table lll 4x3>a|b|c|1|||1|2|3||x|")
    }
    func testTableCellsUnescapePipes() {
        let b = Markdown.parse("| code | note |\n|---|---|\n| `a \\| b` | trailing \\|\n")
        XCTAssertEqual(b.count, 1)
        if b.count == 1 {
            XCTAssertEqual(b[0].rows, 2); XCTAssertEqual(b[0].cols, 2)
            XCTAssertEqual(b[0].cells[1][0], "`a | b`")
            XCTAssertEqual(b[0].cells[1][1], "trailing |")
        }
    }
    func testTablesEndAtABlankLineOrALineWithoutAPipe() {
        XCTAssertEqual(blocks("| a |\n|---|\n| 1 |\n\n| 2 |"), "<table l 2x1>a|1<p>| 2 |")
        XCTAssertEqual(blocks("| a |\n|---|\n| 1 |\nafter"), "<table l 2x1>a|1<p>after")
        XCTAssertEqual(blocks("| a |\n|---|"), "<table l 1x1>a")
        XCTAssertEqual(blocks("intro\n| a |\n|---|\n| 1 |"), "<p>intro<table l 2x1>a|1")
        XCTAssertEqual(blocks("> q\n| a |\n|---|"), "<quote>q<table l 1x1>a")
        XCTAssertEqual(blocks("| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n# Next"), "<table ll 3x2>a|b|1|2|3|4<h1>Next")
    }
    func testPipesWithoutAMatchingDelimiterRowAreText() {
        XCTAssertEqual(blocks("| a | b |"), "<p>| a | b |")
        XCTAssertEqual(blocks("| a | b |\n|---|\n"), "<p>| a | b |\n|---|")
        XCTAssertEqual(blocks("| a | b |\n| --- | x |"), "<p>| a | b |\n| --- | x |")
        XCTAssertEqual(blocks("| a |\n|:|"), "<p>| a |\n|:|")
        XCTAssertEqual(blocks("a | b\n---"), "<p>a | b<hr>")
        XCTAssertEqual(blocks("| a | b |\n\n|---|---|"), "<p>| a | b |<p>|---|---|")
    }
    func testAFullReplyMixesEveryBlock() {
        let reply = "# Summary\nI changed **two** files:\n\n1. `core/a.c`\n   - [x] parse\n   - [ ] free\n2. `core/b.c`\n\n> Note: run the tests\n\n"
            + "| File | Lines |\n|:-----|------:|\n| a.c | 12 |\n\n```diff\n-old\n+new\n```\n***\nDone."
        XCTAssertEqual(blocks(reply), "<h1>Summary<p>I changed **two** files:<li0 1.>`core/a.c`<li1 \u{2022} [x]>parse<li1 \u{2022} [ ]>free<li0 2.>`core/b.c`<quote>Note: run the tests<table lr 2x2>File|Lines|a.c|12<code diff>-old\n+new<hr><p>Done.")
    }
    func testPlainTextIsOneSpanWithoutAUrl() {
        XCTAssertEqual(Markdown.inline("just words"), [MdSpan(flags: [], text: "just words", url: nil)])
        XCTAssertEqual(Markdown.inline("").count, 0)
        XCTAssertEqual(Markdown.inline(nil).count, 0)
    }
    func testNewlinesStayInTheText() {
        XCTAssertEqual(spans("a\nb\n**c\nd**"), "[:a\nb\n][B:c\nd]")
    }
    func testCodeSpansTakeMatchingBacktickRuns() {
        XCTAssertEqual(spans("`x`"), "[C:x]")
        XCTAssertEqual(spans("``a ` b``"), "[C:a ` b]")
        XCTAssertEqual(spans("`` `ticks` ``"), "[C:`ticks`]")
        XCTAssertEqual(spans("` x`"), "[C: x]")
        XCTAssertEqual(spans("`**not bold** &amp; [no](https://x.y)`"), "[C:**not bold** &amp; [no](https://x.y)]")
        XCTAssertEqual(spans("a `b` c `d`"), "[:a ][C:b][: c ][C:d]")
    }
    func testUnclosedBackticksAreLiteral() {
        XCTAssertEqual(spans("`open"), "[:`open]")
        XCTAssertEqual(spans("``a`"), "[:``a`]")
        XCTAssertEqual(spans("a ``` b"), "[:a ``` b]")
        XCTAssertEqual(spans("``"), "[:``]")
    }
    func testBoldItalicAndStrikeMarkers() {
        XCTAssertEqual(spans("**b** __b__ *i* _i_ ~~s~~"), "[B:b][: ][B:b][: ][I:i][: ][I:i][: ][S:s]")
        XCTAssertEqual(spans("**bold *it* x**"), "[B:bold ][BI:it][B: x]")
        XCTAssertEqual(spans("~~**gone**~~"), "[BS:gone]")
        XCTAssertEqual(spans("_**both**_"), "[BI:both]")
    }
    func testTripledMarkersAreBoldAndItalic() {
        XCTAssertEqual(spans("***bi***"), "[BI:bi]")
        XCTAssertEqual(spans("a ___bi___ b"), "[:a ][BI:bi][: b]")
        XCTAssertEqual(spans("a___b___c"), "[:a___b___c]")
        XCTAssertEqual(spans("***open"), "[:***open]")
    }
    func testItalicsStepOverBoldInsideThem() {
        XCTAssertEqual(spans("*a **b** c*"), "[I:a ][BI:b][I: c]")
        XCTAssertEqual(spans("_a __b__ c_"), "[I:a ][BI:b][I: c]")
        XCTAssertEqual(spans("*a **b***"), "[I:a ][BI:b]")
        XCTAssertEqual(spans("*a**"), "[I:a][:*]")
    }
    func testEmphasisNeedsTextHuggingItsMarkers() {
        XCTAssertEqual(spans("2 * 3 * 4"), "[:2 * 3 * 4]")
        XCTAssertEqual(spans("* not*"), "[:* not*]")
        XCTAssertEqual(spans("*not *"), "[:*not *]")
        XCTAssertEqual(spans("** no**"), "[:** no**]")
        XCTAssertEqual(spans("~~ no~~"), "[:~~ no~~]")
        XCTAssertEqual(spans("~one~"), "[:~one~]")
        XCTAssertEqual(spans("**"), "[:**]")
        XCTAssertEqual(spans("*"), "[:*]")
        XCTAssertEqual(spans("~~~~"), "[:~~~~]")
    }
    func testUnclosedEmphasisIsLiteral() {
        XCTAssertEqual(spans("**open"), "[:**open]")
        XCTAssertEqual(spans("*open"), "[:*open]")
        XCTAssertEqual(spans("~~open"), "[:~~open]")
        XCTAssertEqual(spans("__open"), "[:__open]")
    }
    func testIntrawordUnderscoresAreLiteral() {
        XCTAssertEqual(spans("snake_case_name"), "[:snake_case_name]")
        XCTAssertEqual(spans("a__b__c"), "[:a__b__c]")
        XCTAssertEqual(spans("x_1 and _real_"), "[:x_1 and ][I:real]")
        XCTAssertEqual(spans("un*frigging*believable"), "[:un][I:frigging][:believable]")
    }
    func testBackslashEscapesDropTheBackslash() {
        XCTAssertEqual(spans("\\*not\\*"), "[:*not*]")
        XCTAssertEqual(spans("\\`x\\` \\[a\\](b) \\_ \\# \\~ \\! \\| \\< \\> \\( \\)"), "[:`x` [a](b) _ # ~ ! | < > ( )]")
        XCTAssertEqual(spans("\\\\"), "[:\\]")
        XCTAssertEqual(spans("\\a \\n"), "[:\\a \\n]")
        XCTAssertEqual(spans("end\\"), "[:end\\]")
        XCTAssertEqual(spans("*a\\*b*"), "[I:a*b]")
        XCTAssertEqual(spans("**a\\**b**"), "[B:a**b]")
    }
    func testLinksCarryTheirUrlOnEveryLabelSpan() {
        XCTAssertEqual(spans("[text](https://a.example/x)"), "[L:text@https://a.example/x]")
        XCTAssertEqual(spans("[rel](docs/readme.md)"), "[L:rel@docs/readme.md]")
        XCTAssertEqual(spans("[a **b** c](u)"), "[L:a @u][BL:b@u][L: c@u]")
        XCTAssertEqual(spans("[`code`](u)"), "[CL:code@u]")
        XCTAssertEqual(spans("**[bold link](u)**"), "[BL:bold link@u]")
        XCTAssertEqual(spans("[t](https://a.example \"Title\")"), "[L:t@https://a.example]")
        XCTAssertEqual(spans("[a [b] c](u)"), "[L:a [b] c@u]")
        XCTAssertEqual(spans("go [here](u) now"), "[:go ][L:here@u][: now]")
    }
    func testLinkUrlsKeepBalancedParentheses() {
        XCTAssertEqual(spans("[w](https://en.wikipedia.org/wiki/A_(b))"), "[L:w@https://en.wikipedia.org/wiki/A_(b)]")
        XCTAssertEqual(spans("([w](u)) x"), "[:(][L:w@u][:) x]")
        XCTAssertEqual(spans("[w](u(v)"), "[:[w](u(v)]")
    }
    func testLinksWithAnEmptyLabelShowTheirUrl() {
        XCTAssertEqual(spans("see [](https://a.example) now"), "[:see ][L:https://a.example@https://a.example][: now]")
        XCTAssertEqual(spans("[]()"), "")
    }
    func testAdjacentLinksStaySeparateSpans() {
        XCTAssertEqual(spans("[a](u)[b](u)"), "[L:a@u][L:b@u]")
        XCTAssertEqual(spans("[a](u) [b](v)"), "[L:a@u][: ][L:b@v]")
    }
    func testBracketsThatAreNotLinksAreLiteral() {
        XCTAssertEqual(spans("[just brackets]"), "[:[just brackets]]")
        XCTAssertEqual(spans("[text] (u)"), "[:[text] (u)]")
        XCTAssertEqual(spans("[text](unclosed"), "[:[text](unclosed]")
        XCTAssertEqual(spans("[open"), "[:[open]")
        XCTAssertEqual(spans("a]b(c)"), "[:a]b(c)]")
        XCTAssertEqual(spans("arr[0](x)"), "[:arr][L:0@x]")
    }
    func testImagesShowTheirAltTextAsALink() {
        XCTAssertEqual(spans("![diagram](https://x.example/d.png)"), "[L:diagram@https://x.example/d.png]")
        XCTAssertEqual(spans("Wow! [x](u)"), "[:Wow! ][L:x@u]")
        XCTAssertEqual(spans("!["), "[:[]")
        XCTAssertEqual(spans("!"), "[:!]")
    }
    func testAngleAutolinks() {
        XCTAssertEqual(spans("<https://a.example/p?q=1>"), "[L:https://a.example/p?q=1@https://a.example/p?q=1]")
        XCTAssertEqual(spans("see <http://x.y>."), "[:see ][L:http://x.y@http://x.y][:.]")
        XCTAssertEqual(spans("<notaurl>"), "[:<notaurl>]")
        XCTAssertEqual(spans("<ftp://x.y>"), "[:<ftp://x.y>]")
        XCTAssertEqual(spans("<https://open"), "[:<][L:https://open@https://open]")
    }
    func testBareUrlsDropTrailingPunctuation() {
        XCTAssertEqual(spans("https://a.example/x"), "[L:https://a.example/x@https://a.example/x]")
        XCTAssertEqual(spans("See https://a.example/x."), "[:See ][L:https://a.example/x@https://a.example/x][:.]")
        XCTAssertEqual(spans("http://a.b/c?!,;:"), "[L:http://a.b/c@http://a.b/c][:?!,;:]")
        XCTAssertEqual(spans("(https://a.b/c)"), "[:(][L:https://a.b/c@https://a.b/c][:)]")
        XCTAssertEqual(spans("\"https://a.b\""), "[:\"][L:https://a.b@https://a.b][:\"]")
        XCTAssertEqual(spans("https://a.b/c d"), "[L:https://a.b/c@https://a.b/c][: d]")
        XCTAssertEqual(spans("https://a.b/q?x=1&y=2#frag"), "[L:https://a.b/q?x=1&y=2#frag@https://a.b/q?x=1&y=2#frag]")
        XCTAssertEqual(spans("**https://a.b**"), "[BL:https://a.b@https://a.b]")
    }
    func testUrlSchemesInsideWordsAreNotLinks() {
        XCTAssertEqual(spans("xhttps://a.b"), "[:xhttps://a.b]")
        XCTAssertEqual(spans("ftp://a.b"), "[:ftp://a.b]")
        XCTAssertEqual(spans("https:/a.b"), "[:https:/a.b]")
        XCTAssertEqual(spans("-https://a.b"), "[:-][L:https://a.b@https://a.b]")
    }
    func testHtmlEntitiesAreDecoded() {
        XCTAssertEqual(spans("&amp; &lt; &gt; &quot; &#39; &apos; &nbsp;"), "[:& < > \" ' ' \u{A0}]")
        XCTAssertEqual(spans("&unknown; & &amp &#40;"), "[:&unknown; & &amp &#40;]")
        XCTAssertEqual(spans("&amp;lt;"), "[:&lt;]")
        XCTAssertEqual(spans("**&lt;tag&gt;**"), "[B:<tag>]")
        XCTAssertEqual(spans("&"), "[:&]")
    }
    func testSpansWithTheSameStyleMerge() {
        let s = Markdown.inline("a &amp; b \\* c [x")
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.first?.text, "a & b * c [x")
        XCTAssertEqual(spans("**a****b**"), "[B:ab]")
        XCTAssertEqual(spans("*a**b*"), "[I:ab]")
        XCTAssertEqual(spans("**a** **b**"), "[B:a][: ][B:b]")
    }
    func testMdPlainStripsEveryMarker() {
        XCTAssertEqual(Markdown.plain("# not a block"), "# not a block")
        XCTAssertEqual(Markdown.plain("**b** *i* ~~s~~ `c` [l](u) ![img](u) <https://x.y> &amp;"), "b i s c l img https://x.y &")
        XCTAssertEqual(Markdown.plain("snake_case \\*lit\\*"), "snake_case *lit*")
        XCTAssertEqual(Markdown.plain("line\nbreak"), "line\nbreak")
        XCTAssertEqual(Markdown.plain(""), "")
        XCTAssertEqual(Markdown.plain(nil), "")
    }

}
