// The settings forms' bodies and unsaved-change tracking, as screen_settings.c, screen_provider_settings.c and
// screen_db_servers.c build them.
import XCTest
@testable import BriareusMacCore

final class SettingsLogicTests: XCTestCase {
    func testListsSplitTrimAndDropBlankLines() {
        XCTAssertEqual(SettingsText.list(from: " composer install \n\n  npm ci\r\n"), ["composer install", "npm ci"])
        XCTAssertEqual(SettingsText.listText(["a", 1, "b"]), "a\nb")
        XCTAssertEqual(SettingsText.lineCount("a\nb\nc"), 3)
        XCTAssertEqual(SettingsText.numberText(12.5), "12.5")
        XCTAssertEqual(SettingsText.numberText(.null), "")
    }

    func testRowHasEveryKeyWhenEmpty() {
        XCTAssertTrue(SettingsText.rowHas([:], "anything"))
        XCTAssertTrue(SettingsText.rowHas(["a": nil], "a"))
        XCTAssertFalse(SettingsText.rowHas(["a": 1], "b"))
    }

    func testProjectBodyKeepsUnknownFieldsAndDropsServerOnes() throws {
        var s = ProjectFormState(row: ["id": 4, "repo": "o/r", "sortOrder": 2, "createdAt": 1, "extra": "kept", "setupCommands": ["a"],
                                       "workerBudgetUsd": nil, "reviewProviderId": 2, "reviewModel": "m", "reviewEffort": "high"])
        XCTAssertEqual(s.id, 4)
        XCTAssertFalse(s.tabChanged(.project))
        s.texts[.setup] = "a\n\n b "
        XCTAssertTrue(s.tabChanged(.project))
        s.texts[.budget] = "25"
        let body = try s.body().get()
        XCTAssertEqual(body["extra"], "kept")
        XCTAssertTrue(body["id"].isNull && body["sortOrder"].isNull && body["createdAt"].isNull)
        XCTAssertEqual(body["setupCommands"], ["a", "b"])
        XCTAssertEqual(body["workerBudgetUsd"], 25)
        XCTAssertEqual(body["reviewProviderId"], 2)
        // A field the server's projects do not carry is not sent.
        XCTAssertNil(body.object?["localDir"])
    }

    func testProjectBodyRefusesABadRepoOrBudget() {
        var s = ProjectFormState(row: [:])
        s.texts[.repo] = "nope"
        XCTAssertEqual(s.body().failureMessage, "Enter the repository as owner/name.")
        s.texts[.repo] = "o/r"
        s.texts[.budget] = "-3"
        if case .failure(let p) = s.body() {
            XCTAssertEqual(p.tab, ProjectTab.orchestrator.rawValue)
            XCTAssertTrue(p.message.hasPrefix("Budget (USD) must be a number"))
        } else { XCTFail() }
    }

    func testStepRuntimesLeftOnTheReviewAreNoEntry() throws {
        var s = ProjectFormState(row: ["repo": "o/r", "stepRuntimes": ["testSheet": ["providerId": 3, "model": "x", "effort": ""]]])
        XCTAssertEqual(s.pick(.testSheet).providerId, 3)
        s.picks[.testSheet] = RuntimePick()
        s.picks[.testRun] = RuntimePick(providerId: 5, model: "m", effort: nil)
        let body = try s.body().get()
        XCTAssertTrue(body["stepRuntimes"]["testSheet"].isNull)
        XCTAssertEqual(body["stepRuntimes"]["testRun"], ["providerId": 5, "model": "m", "effort": ""])
        XCTAssertTrue(s.tabChanged(.review))
        XCTAssertFalse(s.tabChanged(.orchestrator))
    }

    func testPickTextKeepsAProviderTheCatalogLost() {
        let s = ProjectFormState(row: ["repo": "o/r", "reviewProviderId": 9, "reviewModel": "m"])
        XCTAssertEqual(s.pickText(.review, part: 0, catalog: RuntimeCatalog()), "Provider #9 (unavailable)")
        XCTAssertEqual(s.pickText(.review, part: 0, catalog: nil), "Provider #9")
        XCTAssertEqual(s.pickText(.review, part: 1, catalog: nil), "m")
        XCTAssertEqual(s.pickText(.review, part: 2, catalog: nil), "—")
        XCTAssertEqual(s.pickText(.worker, part: 0, catalog: nil), "Same as the orchestrator")
    }

    func testProviderModeAndBody() throws {
        var s = ProviderFormState(row: ["id": 2, "label": "Max", "binary": "claude", "apiKey": "", "baseUrl": "", "hasLogin": true])
        XCTAssertFalse(s.token)
        XCTAssertTrue(s.canLogIn)
        s.texts[.apiKey] = "secret"
        // The login mode drops the endpoint and its token.
        XCTAssertEqual(try s.body().get()["apiKey"], "")
        XCTAssertNil(try s.body().get().object?["hasLogin"])
        s.token = true
        XCTAssertEqual(try s.body().get()["apiKey"], "secret")
        XCTAssertTrue(s.tabChanged(.provider))
        s.texts[.label] = ""
        XCTAssertEqual(s.body().failureMessage, "Enter a label: it is what the provider picker shows.")
        XCTAssertNotNil(try? s.body(validate: false).get())
        XCTAssertTrue(ProviderFormState(row: ["binary": "opencode"]).usesToken)
        XCTAssertFalse(ProviderFormState.modeOffered("grok"))
    }

    func testProviderStatusHeadline() {
        XCTAssertNil(ProviderStatusText.headline(.null))
        XCTAssertEqual(ProviderStatusText.headline(["available": false])?.text, "The CLI is not installed on this machine")
        let ok = ProviderStatusText.headline(["auth": ["loggedIn": true, "email": "a@b"]])
        XCTAssertEqual(ok?.text, "Connected: a@b")
        XCTAssertEqual(ok?.dot, "idle")
        XCTAssertEqual(ProviderStatusText.headline(["auth": ["loggedIn": false]])?.dot, "failed")
        let r = ProviderStatusText.testResult(["models": ["a", "b"]], modelsNow: "a")
        XCTAssertEqual(r.text, "OK: the endpoint offers 2 models; they are in the Models tab, save to keep them")
        XCTAssertEqual(r.models, "a\nb")
    }

    func testDBServerPortAndTest() throws {
        var s = DBServerFormState(row: ["id": 1, "host": "h", "port": 3306, "enabled": true, "password": " p "])
        XCTAssertEqual(s.text(.port), "3306")
        s.texts[.port] = "70000"
        XCTAssertEqual(s.body().failureMessage, "The port must be a whole number from 1 to 65535.")
        s.texts[.port] = ""
        let body = try s.body().get()
        XCTAssertTrue(body["port"].isNull)
        XCTAssertEqual(body["password"], " p ")
        XCTAssertEqual(DBServerFormState.testText(["version": "8.0", "databases": 1, "claimedBy": ["title": "Fix"]]),
                       "Healthy: MySQL 8.0, 1 database · claimed by session Fix")
        XCTAssertEqual(DBServerFormState.poolText(capacity: 1, total: 3),
                       "1 server in the pool, so 1 session with a database may be open at once. 2 more are listed but taken out of the pool.")
    }

    func testSSHServerDefaultsAndChecks() {
        var s = SSHServerFormState(row: [:], firstRepo: "o/r")
        XCTAssertEqual(s.repo, "o/r")
        XCTAssertEqual(s.text(.port), "22")
        XCTAssertEqual(s.mode, "ask")
        XCTAssertEqual(s.body().failureMessage, "Enter the host: a hostname or an IP address.")
        s.texts[.host] = "h"
        s.texts[.username] = "u"
        XCTAssertEqual(try s.body().get()["port"], 22)
        XCTAssertTrue(s.changed)
        XCTAssertEqual(SSHServerFormState.subtitle(["username": "u", "host": "h", "port": 22, "repo": "o/r"]), "u@h:22 · o/r")
        XCTAssertEqual(SSHServerFormState.rowID(["id": 1712345678901]), 1712345678901)
    }
}

private extension Result where Failure == FormProblem {
    var failureMessage: String? { if case .failure(let p) = self { return p.message }; return nil }
}
