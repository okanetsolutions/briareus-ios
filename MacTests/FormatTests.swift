// Ported from the Windows client's tests/app_format_tests.c and the pure parts of tests/app_common_tests.c.
import XCTest
@testable import BriareusMacCore

final class FormatTests: XCTestCase {
    // MARK: - Findings and rows (app_common_tests.c)

    func testSeverityLabels() {
        XCTAssertEqual(findingSeverityLabel("critical"), "CRIT")
        XCTAssertEqual(findingSeverityLabel("CRITICAL"), "CRIT")
        XCTAssertEqual(findingSeverityLabel("High"), "HIGH")
        XCTAssertEqual(findingSeverityLabel("low"), "LOW")
        XCTAssertEqual(findingSeverityLabel("medium"), "MED")
    }
    func testUnknownSeverityReadsAsMedium() {
        XCTAssertEqual(findingSeverityLabel(""), "MED")
        XCTAssertEqual(findingSeverityLabel(nil), "MED")
        XCTAssertEqual(findingSeverityLabel("blocker"), "MED")
    }
    func testDecisionsAreIndexedByTheirAPISpelling() {
        XCTAssertEqual(findingDecisionIndex("fix"), 0)
        XCTAssertEqual(findingDecisionIndex("optional"), 1)
        XCTAssertEqual(findingDecisionIndex("dismissed"), 2)
        XCTAssertEqual(findingDecisionTitles, ["Fix", "Optional", "Dismiss"])
        for (k, id) in findingDecisionIds.enumerated() { XCTAssertEqual(findingDecisionIndex(id), k) }
    }
    func testUnknownDecisionsHaveNoIndex() {
        for d in ["Fix", "dismiss", "undecided", "", nil] { XCTAssertNil(findingDecisionIndex(d), d ?? "(nil)") }
    }
    func testSessionSubtitleIsStatusAndModel() {
        XCTAssertEqual(sessionSubtitle(Session(j(#"{"id":"s1","status":"waiting","model":"opus"}"#))!), "Waiting \u{00B7} opus")
        XCTAssertEqual(sessionSubtitle(Session(j(#"{"id":"s2","status":"idle"}"#))!), "Idle")
        XCTAssertEqual(sessionSubtitle(Session(j(#"{"id":"s3","status":"running","model":""}"#))!), "Running")
    }
    func testPeopleListsLoginsUpToALimit() {
        let logins = ["ana", "bo", "cy", "di"]
        XCTAssertEqual(people(Array(logins.prefix(1)), limit: 2), "@ana")
        XCTAssertEqual(people(Array(logins.prefix(2)), limit: 2), "@ana, @bo")
        XCTAssertEqual(people(Array(logins.prefix(3)), limit: 2), "@ana, @bo +1")
        XCTAssertEqual(people(logins, limit: 2), "@ana, @bo +2")
        XCTAssertEqual(people(logins, limit: 10), "@ana, @bo, @cy, @di")
        XCTAssertEqual(people([], limit: 2), "")
    }
    func testLinkedStateText() {
        XCTAssertEqual(linkedStateText(BoardLink(j(#"{"number":1,"draft":true,"state":"open"}"#))!), "draft")
        XCTAssertEqual(linkedStateText(BoardLink(j(#"{"number":1,"state":"closed","stateReason":"not_planned"}"#))!), "not planned")
        XCTAssertEqual(linkedStateText(BoardLink(j(#"{"number":1,"state":"open"}"#))!), "open")
        XCTAssertEqual(linkedStateText(BoardLink(j(#"{"number":1,"state":"closed"}"#))!), "closed")
        XCTAssertNil(linkedStateText(BoardLink(j(#"{"number":1}"#))!))
    }

    // MARK: - Times

    private let posix = Locale(identifier: "en_US_POSIX")
    /// Newer ICU puts a narrow no-break space before AM and PM.
    private func plain(_ s: String) -> String { s.replacingOccurrences(of: "\u{202F}", with: " ") }
    private let utc = TimeZone(identifier: "UTC")!
    private func clock(_ d: Date, _ tz: TimeZone) -> String {
        let f = DateFormatter(); f.locale = posix; f.timeZone = tz; f.dateStyle = .none; f.timeStyle = .short
        return f.string(from: d)
    }
    private func date(_ d: Date, _ format: String, _ tz: TimeZone) -> String {
        let f = DateFormatter(); f.locale = posix; f.timeZone = tz; f.dateFormat = format
        return f.string(from: d)
    }
    func testEventTimeTodayIsTheClockAlone() {
        let now = Date()
        XCTAssertEqual(formatEventTime(now, now: now, locale: posix, timeZone: utc), clock(now, utc))
        let noon = Date(timeIntervalSince1970: 1790596800)   // 2026-09-28 12:00 UTC
        XCTAssertEqual(plain(formatEventTime(noon, now: noon.addingTimeInterval(3600), locale: posix, timeZone: utc)), "12:00 PM")
    }
    func testEventTimeOnAnotherDayNamesTheDay() {
        let now = Date()
        for when in [now.addingTimeInterval(-3 * 86400), now.addingTimeInterval(3 * 86400)] {
            XCTAssertEqual(formatEventTime(when, now: now, locale: posix, timeZone: utc), "\(date(when, "MMM d", utc)), \(clock(when, utc))")
        }
        let noon = Date(timeIntervalSince1970: 1790596800)
        XCTAssertEqual(plain(formatEventTime(noon, now: noon.addingTimeInterval(3 * 86400), locale: posix, timeZone: utc)), "Sep 28, 12:00 PM")
    }
    func testEventTimesTakeTheOffsetOfTheirOwnDate() {
        // Noon UTC on 1 January and 1 July 2026: one in standard time and one in daylight time wherever the zone has both.
        let ny = TimeZone(identifier: "America/New_York")!
        let winter = Date(timeIntervalSince1970: 1767268800), summer = Date(timeIntervalSince1970: 1782907200)
        let later = Date(timeIntervalSince1970: 1790596800)
        XCTAssertEqual(plain(formatEventTime(winter, now: later, locale: posix, timeZone: ny)), "Jan 1, 7:00 AM")
        XCTAssertEqual(plain(formatEventTime(summer, now: later, locale: posix, timeZone: ny)), "Jul 1, 8:00 AM")
        XCTAssertEqual(formatDateAbbrev(winter, locale: posix, timeZone: ny), "Jan 1, 2026")
        XCTAssertEqual(formatDateAbbrev(summer, locale: posix, timeZone: ny), "Jul 1, 2026")
    }
    func testDateAbbrevIsMonthDayAndYear() {
        let now = Date()
        XCTAssertEqual(formatDateAbbrev(now, locale: posix, timeZone: utc), date(now, "MMM d, yyyy", utc))
        XCTAssertTrue(formatDateAbbrev(now).contains(String(Calendar.current.component(.year, from: now))))
    }
    func testRelativeTimeStepsFromMinutesToYears() {
        let now = Date()
        func ago(_ s: Double) -> String { formatRelative(now.addingTimeInterval(-s), now: now) }
        XCTAssertEqual(ago(0), "now")
        XCTAssertEqual(ago(30), "now")
        XCTAssertEqual(ago(60), "1m ago")
        XCTAssertEqual(ago(59 * 60 + 20), "59m ago")
        XCTAssertEqual(ago(3600), "1h ago")
        XCTAssertEqual(ago(23 * 3600 + 60), "23h ago")
        XCTAssertEqual(ago(86400), "1d ago")
        XCTAssertEqual(ago(6 * 86400 + 60), "6d ago")
        XCTAssertEqual(ago(7 * 86400), "1w ago")
        XCTAssertEqual(ago(29 * 86400), "4w ago")
        XCTAssertEqual(ago(30 * 86400), "1mo ago")
        XCTAssertEqual(ago(364 * 86400), "12mo ago")
        XCTAssertEqual(ago(365 * 86400), "1y ago")
        XCTAssertEqual(ago(3 * 365 * 86400 + 60), "3y ago")
    }
    func testRelativeTimeInTheFutureHasNoAgo() {
        let now = Date()
        func ahead(_ s: Double) -> String { formatRelative(now.addingTimeInterval(s), now: now) }
        XCTAssertEqual(ahead(30), "now")
        XCTAssertEqual(ahead(150), "2m")
        XCTAssertEqual(ahead(2 * 3600 + 30), "2h")
        XCTAssertEqual(ahead(3 * 86400 + 30), "3d")
    }
    func testDurationShowsTheTwoLargestUnits() {
        XCTAssertEqual(formatDurationMs(0), "0s")
        XCTAssertEqual(formatDurationMs(999), "0s")
        XCTAssertEqual(formatDurationMs(1000), "1s")
        XCTAssertEqual(formatDurationMs(59999), "59s")
        XCTAssertEqual(formatDurationMs(60000), "1m 0s")
        XCTAssertEqual(formatDurationMs(3599000), "59m 59s")
        XCTAssertEqual(formatDurationMs(3600000), "1h 0m")
        XCTAssertEqual(formatDurationMs(3661000), "1h 1m")
        XCTAssertEqual(formatDurationMs(25.0 * 3600000 + 61000), "25h 1m")
    }
    func testNegativeDurationsAndClocksAreZero() {
        XCTAssertEqual(formatDurationMs(-5000), "0s")
        XCTAssertEqual(formatClock(-5), "0:00")
    }
    func testClockIsMinutesAndPaddedSeconds() {
        XCTAssertEqual(formatClock(0), "0:00")
        XCTAssertEqual(formatClock(9), "0:09")
        XCTAssertEqual(formatClock(59), "0:59")
        XCTAssertEqual(formatClock(60), "1:00")
        XCTAssertEqual(formatClock(605), "10:05")
        XCTAssertEqual(formatClock(3600), "60:00")
    }

    // MARK: - Numbers

    func testTokensAbbreviateAsTheDashboardDoes() {
        XCTAssertEqual(formatTokens(0), "0")
        XCTAssertEqual(formatTokens(999), "999")
        XCTAssertEqual(formatTokens(999.9), "999")
        XCTAssertEqual(formatTokens(1000), "1.0k")
        XCTAssertEqual(formatTokens(42900), "42.9k")
        XCTAssertEqual(formatTokens(1e6), "1.0M")
        XCTAssertEqual(formatTokens(19.1e6), "19.1M")
        XCTAssertEqual(formatTokens(839.1e6), "839.1M")
        XCTAssertEqual(formatTokens(1e9), "1.0B")
        XCTAssertEqual(formatTokens(21.6e9), "21.6B")
    }
    func testTokensThatRoundUpToTheNextUnitTakeIt() {
        XCTAssertEqual(formatTokens(999949), "999.9k")
        XCTAssertEqual(formatTokens(999999), "1.0M")
        XCTAssertEqual(formatTokens(999949999), "999.9M")
        XCTAssertEqual(formatTokens(999999999), "1.0B")
    }
    func testCostHasADollarSignAndTwoDecimals() {
        XCTAssertEqual(formatCost(33.35), "$33.35")
        XCTAssertEqual(formatCost(0), "$0.00")
        XCTAssertEqual(formatCost(0.004), "$0.00")
        XCTAssertEqual(formatCost(2), "$2.00")
        XCTAssertEqual(formatCost(1234.5), "$1234.50")
    }
    func testFileSizesRoundUpToWholeKilobytes() {
        XCTAssertEqual(formatFileSize(0), "1 KB")
        XCTAssertEqual(formatFileSize(1), "1 KB")
        XCTAssertEqual(formatFileSize(1023), "1 KB")
        XCTAssertEqual(formatFileSize(1024), "1 KB")
        XCTAssertEqual(formatFileSize(1025), "2 KB")
        XCTAssertEqual(formatFileSize(500 * 1024), "500 KB")
        XCTAssertEqual(formatFileSize(1024 * 1024 - 1), "1024 KB")
    }
    func testFileSizesFromAMegabyteHaveOneDecimal() {
        XCTAssertEqual(formatFileSize(1024 * 1024), "1.0 MB")
        XCTAssertEqual(formatFileSize(1024 * 1024 + 1024 * 1024 / 2), "1.5 MB")
        XCTAssertEqual(formatFileSize(1024 * 1024 + 1024 * 1024 / 20 - 1), "1.0 MB")
        XCTAssertEqual(formatFileSize(25 * 1024 * 1024), "25.0 MB")
    }

    // MARK: - Working indicator

    func testWorkingGlyphCyclesEveryTenTicks() {
        XCTAssertEqual(workingGlyph(0), "\u{00B7}")
        XCTAssertEqual(workingGlyph(1), "\u{2722}")
        XCTAssertEqual(workingGlyph(4), "\u{273B}")
        XCTAssertEqual(workingGlyph(5), "\u{273D}")
        XCTAssertEqual(workingGlyph(9), "\u{2722}")
        XCTAssertEqual(workingGlyph(10), workingGlyph(0))
        XCTAssertEqual(workingGlyph(1234567), workingGlyph(7))
    }
    func testWorkingGlyphWrapsNegativeTicks() {
        XCTAssertEqual(workingGlyph(-1), workingGlyph(9))
        XCTAssertEqual(workingGlyph(-10), workingGlyph(0))
        XCTAssertEqual(workingGlyph(-13), workingGlyph(7))
        XCTAssertFalse(workingGlyph(Int.min).isEmpty)
    }
    func testWorkingVerbChangesEvery25Ticks() {
        XCTAssertEqual([0, 24, 25, 50, 75, 100, 125, 150].map(workingVerb),
                       ["Working", "Working", "Thinking", "Reasoning", "Tinkering", "Crafting", "Pondering", "Working"])
    }
    func testWorkingVerbWrapsNegativeTicks() {
        // Division truncates toward zero, so -24...24 all read "Working".
        XCTAssertEqual(workingVerb(-24), "Working")
        XCTAssertEqual(workingVerb(-25), "Pondering")
        XCTAssertEqual(workingVerb(-150), "Working")
        XCTAssertFalse(workingVerb(Int.min).isEmpty)
    }
}
