import XCTest
@testable import BriareusCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, headers, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class CoreTests: XCTestCase {
    private let token = "brm_" + String(repeating: "a", count: 43)
    private func client() throws -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return try APIClient(address: ServerAddress("https://example.com"), token: token, configuration: configuration)
    }
    override func tearDown() { StubProtocol.handler = nil; super.tearDown() }
    func testNormalizesOriginAndAPIPath() throws {
        let a = try ServerAddress(" https://EXAMPLE.com:443/api/mobile/v1/ ")
        XCTAssertEqual(a.origin, "https://example.com")
        XCTAssertEqual(a.baseURL.absoluteString, "https://example.com/api/mobile/v1/")
        XCTAssertEqual(try ServerAddress("https://example.com:8443").origin, "https://example.com:8443")
    }
    func testRejectsUnsafeOrAmbiguousAddresses() {
        for value in ["http://example.com", "https://user:pass@example.com", "https://example.com?token=x",
                      "https://example.com/#x", "https://example.com/api/dev", "file:///secret", "example.com", "https://"] {
            XCTAssertThrowsError(try ServerAddress(value), value)
        }
    }
    func testRejectsInvalidTokens() throws {
        for token in ["", "Bearer brm_bad", "brm_short", "brm_" + String(repeating: "a", count: 44), self.token + "\n"] {
            XCTAssertThrowsError(try APIClient(address: ServerAddress("https://example.com"), token: token))
        }
    }
    func testOperationUsesExactMobilePathAndJSONBody() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/api/mobile/v1/operations/session")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + self.token)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            let body = try JSONDecoder().decode(JSONValue.self, from: self.body(of: request))
            XCTAssertEqual(body["since"], .number(7)); XCTAssertEqual(body["sessionId"], .string("abc"))
            return (200, ["Content-Type": "application/json"], Data(#"{"session":{"id":"abc","status":"running","extra":42},"events":[]}"#.utf8))
        }
        let result: SessionResult = try await client().operation("session", arguments: ["sessionId": .string("abc"), "since": .number(7)])
        XCTAssertEqual(result.session.status, "running"); XCTAssertEqual(result.events?.count, 0)
    }
    func testDiscoveryValidatesVersionAndMilliseconds() async throws {
        StubProtocol.handler = { _ in
            (200, ["Content-Type": "application/json; charset=utf-8"], Data(#"{"version":1,"device":{"id":"d","label":"iPhone","repos":["a/b"],"permission":"read","expiresAt":1000000}}"#.utf8))
        }
        let result = try await client().discovery()
        XCTAssertFalse(result.device.canManage)
        XCTAssertEqual(result.device.expiry.timeIntervalSince1970, 1000)
        StubProtocol.handler = { _ in
            (200, ["Content-Type": "application/json"], Data(#"{"version":2,"device":{"id":"d","label":"Phone","repos":[],"permission":"manage","expiresAt":0}}"#.utf8))
        }
        do { _ = try await client().discovery(); XCTFail("Accepted incompatible API") }
        catch { XCTAssertEqual(error as? APIError, .incompatibleVersion) }
    }
    func testRedirectAndHTMLAreNotAccepted() async throws {
        for (status, expected) in [(302, APIError.redirected), (200, APIError.nonJSON)] {
            StubProtocol.handler = { _ in (status, ["Content-Type": "text/html", "Location": "https://login.example.com"], Data("<html>Login</html>".utf8)) }
            do { let _: JSONValue = try await client().operation("projects"); XCTFail("Accepted proxy response") }
            catch { XCTAssertEqual(error as? APIError, expected) }
        }
    }
    func testDelegateRefusesRedirect() throws {
        let url = URL(string: "https://example.com")!
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: url)
        var called = false
        RejectRedirects().urlSession(session, task: task,
            willPerformHTTPRedirection: HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)!,
            newRequest: URLRequest(url: URL(string: "https://attacker.example")!)) { request in
                called = true; XCTAssertNil(request)
            }
        XCTAssertTrue(called)
    }
    func testErrorsKeepStatusAndRetryAfterWithoutRetryingWrite() async throws {
        var calls = 0
        StubProtocol.handler = { _ in
            calls += 1
            return (429, ["Content-Type": "application/json", "Retry-After": "90"], Data(#"{"error":"Wait"}"#.utf8))
        }
        do { let _: JSONValue = try await client().operation("message"); XCTFail("Accepted error") }
        catch { XCTAssertEqual(error as? APIError, .http(429, "Wait", retryAfter: 90)) }
        XCTAssertEqual(calls, 1)
        StubProtocol.handler = { _ in (401, ["Content-Type": "application/json"], Data(#"{"error":"Expired"}"#.utf8)) }
        do { let _: JSONValue = try await client().operation("projects"); XCTFail("Accepted expired token") }
        catch { XCTAssertTrue((error as? APIError)?.isUnauthorized == true) }
    }
    func testTimeoutDoesNotRetryWrite() async throws {
        var calls = 0
        StubProtocol.handler = { _ in calls += 1; throw URLError(.timedOut) }
        do { let _: JSONValue = try await client().operation("start_session"); XCTFail("Expected timeout") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        XCTAssertEqual(calls, 1)
    }
    func testVoiceNoteIsPostedAsRecordedAndAnsweredWithItsText() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/api/mobile/v1/transcribe?lang=es-ES")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + self.token)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "audio/mp4")
            XCTAssertEqual(self.body(of: request), Data([0, 1, 2, 255]))
            return (200, ["Content-Type": "application/json"], Data(#"{"text":"hola mundo"}"#.utf8))
        }
        let text = try await client().transcribe(Data([0, 1, 2, 255]), language: "es-ES")
        XCTAssertEqual(text, "hola mundo")
        StubProtocol.handler = { request in
            XCTAssertNil(request.url?.query)
            return (502, ["Content-Type": "application/json"], Data(#"{"error":"OpenAI answered 400"}"#.utf8))
        }
        do { _ = try await client().transcribe(Data([1])); XCTFail("Accepted a failed transcription") }
        catch { XCTAssertEqual(error as? APIError, .http(502, "OpenAI answered 400", retryAfter: nil)) }
        StubProtocol.handler = { _ in (200, ["Content-Type": "application/json"], Data(#"{"ok":true}"#.utf8)) }
        do { _ = try await client().transcribe(Data([1])); XCTFail("Accepted an answer without text") }
        catch { XCTAssertEqual(error as? APIError, .nonJSON) }
    }
    func testDiscoverySaysWhetherTheServerTranscribes() throws {
        let device = #""device":{"id":"d","label":"iPhone","repos":[],"permission":"manage","expiresAt":0}"#
        XCTAssertNil(try JSONDecoder().decode(Discovery.self, from: Data("{\"version\":1,\(device)}".utf8)).transcribe)
        XCTAssertEqual(try JSONDecoder().decode(Discovery.self, from: Data("{\"version\":1,\(device),\"transcribe\":true}".utf8)).transcribe, true)
        let saved = try JSONDecoder().decode(Connection.self, from: Data("{\(device),\"operations\":[]}".utf8))
        XCTAssertNil(saved.transcribe)
        XCTAssertNil(Discovery.voiceNotesOff(true))
        XCTAssertTrue(Discovery.voiceNotesOff(false)?.contains("OPENAI_TRANSCRIBE_API_KEY") == true)
        XCTAssertTrue(Discovery.voiceNotesOff(nil)?.contains("Update Briareus") == true)
    }
    func testRevokeUsesDeleteToken() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/api/mobile/v1/token")
            return (200, ["Content-Type": "application/json"], Data(#"{"ok":true}"#.utf8))
        }
        try await client().revoke()
    }
    func testOversizedWriteNeverLeavesClient() async throws {
        StubProtocol.handler = { _ in XCTFail("Oversized request sent"); throw URLError(.badURL) }
        do {
            let _: JSONValue = try await client().operation("message", arguments: ["text": .string(String(repeating: "x", count: 1_048_576))])
            XCTFail("Accepted oversized body")
        } catch { XCTAssertEqual(error as? APIError, .oversizedRequest) }
    }
    func testRejectsOperationPathTraversal() async throws {
        do { let _: JSONValue = try await client().operation("../projects"); XCTFail("Accepted traversal") }
        catch { if case .http(400, _, _) = error as? APIError {} else { XCTFail("Wrong error: \(error)") } }
    }
    func testTranscriptDeduplicatesSortsAndAdvancesUnknownEvents() throws {
        let data = Data(#"[{"seq":3,"kind":"future_event"},{"seq":1,"kind":"user","text":"Hi"},{"seq":2,"kind":"text","text":"Hello"},{"seq":2,"kind":"text","text":"Hello"}]"#.utf8)
        let events = try JSONDecoder().decode([Event].self, from: data)
        var transcript = Transcript(); transcript.append(events); transcript.append(events)
        XCTAssertEqual(transcript.events.map(\.seq), [1, 2, 3]); XCTAssertEqual(transcript.cursor, 3)
        XCTAssertEqual(transcript.events.filter(\.visible).count, 2)
        transcript.append([]); XCTAssertEqual(transcript.cursor, 3)
        XCTAssertEqual(Transcript().cursor, 0)
    }
    func testSessionReadsReviewLoopAndHeldTriage() throws {
        let data = Data(#"[{"id":"a","status":"idle","reviewLoop":{"triage":{"round":2,"findings":[{"key":"k1"}]}}},{"id":"b","status":"idle","reviewBranch":"feature","reviewTriage":{"mine":false,"findings":[{"key":"k2"}]},"reviewLoop":null},{"id":"c","status":"closed","local":false}]"#.utf8)
        let sessions = try JSONDecoder().decode([Session].self, from: data)
        XCTAssertEqual(sessions.map(\.reviewLoopOn), [true, false, false])
        XCTAssertEqual(sessions.map(\.canReviewLoop), [true, false, false])
        XCTAssertEqual(sessions.map { $0.heldTriage?["findings"].array.first?["key"].string }, ["k1", "k2", nil])
    }
    func testFindingsQueueHoldsTheOldestRoundFirst() throws {
        let data = Data(#"[{"id":"a","status":"idle","reviewLoop":{"triage":{"heldAt":"2026-09-29T10:00:00Z","findings":[{"key":"k1"}]}}},{"id":"b","status":"idle"},{"id":"c","status":"idle","reviewTriage":{"heldAt":"2026-09-28T09:00:00Z","findings":[{"key":"k2"}]}},{"id":"d","status":"idle","reviewTriage":{"findings":[]}}]"#.utf8)
        let sessions = try JSONDecoder().decode([Session].self, from: data)
        XCTAssertEqual(Session.holdingFindings(sessions).map(\.id), ["c", "a"])
    }
    func testSetupEventsAreHidden() throws {
        let data = Data(#"[{"seq":1,"kind":"setup","text":"Installing dependencies"},{"seq":2,"kind":"text","text":"Done"}]"#.utf8)
        let events = try JSONDecoder().decode([Event].self, from: data)
        XCTAssertEqual(events.filter(\.visible).map(\.seq), [2])
    }
    func testOnlyWhatWasSaidIsShown() throws {
        let data = Data(#"[{"seq":1,"kind":"user","text":"Go"},{"seq":2,"kind":"tool","name":"Bash","summary":"ls"},{"seq":3,"kind":"tool_error","text":"No such file"},{"seq":4,"kind":"cmd","text":"npm test"},{"seq":5,"kind":"git","text":"git push"},{"seq":6,"kind":"text","text":"Done"},{"seq":7,"kind":"ask","question":"Ship it?"},{"seq":8,"kind":"result"}]"#.utf8)
        let events = try JSONDecoder().decode([Event].self, from: data)
        XCTAssertEqual(events.filter(\.visible).map(\.seq), [1, 6, 7, 8])
    }
    func testOptionalFieldsAndUnknownStatusesDoNotBreakDecoding() throws {
        let result = try JSONDecoder().decode(SessionResult.self, from: Data(#"{"session":{"id":"x","status":"future","title":null,"model":null,"unknown":true},"events":null}"#.utf8))
        XCTAssertEqual(result.session.displayTitle, "New conversation")
        XCTAssertFalse(result.session.isActive); XCTAssertNil(result.events)
    }
    func testSessionFindsItsPullRequest() throws {
        func session(_ extra: String) throws -> Session {
            try JSONDecoder().decode(Session.self, from: Data(#"{"id":"s","status":"idle"\#(extra)}"#.utf8))
        }
        XCTAssertNil(try session("").pullNumber)
        XCTAssertNil(try session(#","prStatus":null,"startedOnPr":null"#).pullNumber)
        XCTAssertEqual(try session(#","startedOnPr":4"#).pullNumber, 4)
        XCTAssertEqual(try session(#","prStatus":{"number":9,"state":"open"},"startedOnPr":4"#).pullNumber, 9)
    }
    func testActiveRunsAreCountedPerPullRequest() throws {
        let data = Data(#"[{"id":"a","status":"running","startedOnPr":4},{"id":"b","status":"queued","prStatus":{"number":4}},{"id":"c","status":"idle","startedOnPr":4},{"id":"d","status":"closed","startedOnPr":7},{"id":"e","status":"preparing","startedOnPr":9},{"id":"f","status":"running"}]"#.utf8)
        XCTAssertEqual(Session.activeRuns(try JSONDecoder().decode([Session].self, from: data)), [4: 2, 9: 1])
    }
    func testRetryAfterHTTPDate() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(APIClient.retryAfter("Thu, 01 Jan 1970 00:02:00 GMT", now: now), 120)
        XCTAssertNil(APIClient.retryAfter("nonsense")); XCTAssertEqual(APIClient.retryAfter("-10"), 0)
    }
    func testMarkdownBlocks() {
        let source = "## Plan\nFirst **line**\nsame paragraph\n\n- one\n  wrapped\n2. two\n\n```swift\nlet x = 1\n\n```\n> quoted\n---\ntail"
        XCTAssertEqual(MarkdownBlock.parse(source), [
            .heading(level: 2, text: "Plan"), .paragraph("First **line**\nsame paragraph"),
            .bullet(indent: 0, marker: "•", text: "one\nwrapped"), .bullet(indent: 0, marker: "2.", text: "two"),
            .code(language: "swift", text: "let x = 1\n"), .quote("quoted"), .rule, .paragraph("tail")
        ])
        XCTAssertEqual(MarkdownBlock.parse("```\nunterminated"), [.code(language: nil, text: "unterminated")])
        XCTAssertEqual(MarkdownBlock.parse("#hashtag"), [.paragraph("#hashtag")])
    }
    func testRuntimeCatalogResolvesChoicesPerModel() throws {
        let json = #"{"default":{"providerId":2,"model":"opus","effort":"high"},"providers":[{"id":1,"label":"Codex","available":false,"models":[{"id":"gpt","label":"gpt","efforts":["low"],"defaultEffort":"low"}],"defaultModel":"gpt"},{"id":2,"label":"Claude","available":true,"models":[{"id":"sonnet","label":"Sonnet","efforts":["low","medium"],"defaultEffort":"medium"},{"id":"opus","label":"opus","efforts":["low","high"],"defaultEffort":"high"}],"defaultModel":"opus","future":1}]}"#
        let catalog = try JSONDecoder().decode(RuntimeCatalog.self, from: Data(json.utf8))
        XCTAssertEqual(catalog.default, RuntimeChoice(providerId: 2, model: "opus", effort: "high"))
        XCTAssertEqual(catalog.choice(provider: 2), RuntimeChoice(providerId: 2, model: "opus", effort: "high"))
        XCTAssertEqual(catalog.choice(provider: 2, model: "sonnet"), RuntimeChoice(providerId: 2, model: "sonnet", effort: "medium"))
        XCTAssertEqual(catalog.choice(provider: 2, model: "gone")?.model, "opus")
        XCTAssertNil(catalog.choice(provider: 9))
        XCTAssertEqual(catalog.firstAvailable?.providerId, 2)
        XCTAssertEqual(catalog.efforts(for: RuntimeChoice(providerId: 2, model: "sonnet")), ["low", "medium"])
        XCTAssertEqual(catalog.label(for: catalog.default!), "Claude · opus")
        XCTAssertEqual(RuntimeChoice(providerId: 2, model: "opus", effort: "high").arguments,
                       ["providerId": .number(2), "model": .string("opus"), "effort": .string("high")])
        XCTAssertEqual(RuntimeChoice(providerId: 3).arguments, ["providerId": .number(3)])
        let empty = try JSONDecoder().decode(RuntimeCatalog.self, from: Data(#"{"default":null,"providers":[]}"#.utf8))
        XCTAssertNil(empty.default); XCTAssertNil(empty.firstAvailable)
    }
    func testPullFilePagesPinLaterPagesToTheFirstRevision() throws {
        let first = #"{"pr":{"number":7,"headSha":"h1","baseSha":"b1","body":"Why"},"files":[{"filename":"src/a.js","previousFilename":null,"status":"modified","additions":3,"deletions":1,"patch":"@@ -1 +1 @@","url":"https://github.com/o/r/blob/x/src/a.js"}],"nextPage":2,"truncated":false}"#
        let second = #"{"pr":{"number":7,"headSha":"h1","baseSha":"b1"},"files":[{"filename":"src/a.js"},{"filename":"logo.png","status":"added","patch":null}],"nextPage":null}"#
        var list = PullFileList()
        XCTAssertEqual(list.arguments(repo: "o/r", number: 7), ["repo": .string("o/r"), "pr": .number(7)])
        list.append(try JSONDecoder().decode(PullFilesPage.self, from: Data(first.utf8)))
        XCTAssertEqual(list.arguments(repo: "o/r", number: 7),
                       ["repo": .string("o/r"), "pr": .number(7), "page": .number(2), "headSha": .string("h1"), "baseSha": .string("b1")])
        list.append(try JSONDecoder().decode(PullFilesPage.self, from: Data(second.utf8)))
        XCTAssertEqual(list.files.map(\.filename), ["src/a.js", "logo.png"])
        XCTAssertEqual(list.pr["body"].string, "Why")
        XCTAssertNil(list.arguments(repo: "o/r", number: 7)); XCTAssertFalse(list.truncated)
        XCTAssertEqual(list.files[0].name, "a.js"); XCTAssertEqual(list.files[0].directory, "src")
        XCTAssertNil(list.files[1].patch); XCTAssertEqual(list.files[1].directory, "")
    }
    func testDiffLinesAreNumberedFromHunkHeaders() {
        let lines = DiffLine.parse("@@ -10,3 +10,4 @@ func a()\n one\n-two\n+2\n+3\n\n\\ No newline at end of file\n@@ -40 +41 @@\n-x\r\n+y\n")
        XCTAssertEqual(lines.map(\.kind), [.hunk, .context, .removed, .added, .added, .context, .note, .hunk, .removed, .added])
        XCTAssertEqual(lines.map(\.old), [nil, 10, 11, nil, nil, 12, nil, nil, 40, nil])
        XCTAssertEqual(lines.map(\.new), [nil, 10, nil, 11, 12, 13, nil, nil, nil, 41])
        XCTAssertEqual(lines[2].text, "two"); XCTAssertEqual(lines[6].text, "No newline at end of file")
        XCTAssertEqual(lines[8].text, "x")
        XCTAssertEqual(DiffLine.parse(""), [])
    }
    func testCacheRestoresTranscriptSoOnlyNewEventsAreRequested() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = DiskCache(directory: directory)
        let saved: [Event] = await cache.lines("transcript:s/1")
        XCTAssertTrue(saved.isEmpty)
        let first = try JSONDecoder().decode([Event].self, from: Data(#"[{"seq":1,"kind":"user","text":"Hi\nthere"},{"seq":2,"kind":"tool","name":"Bash","summary":"ls","options":[{"label":"a"}]}]"#.utf8))
        let second = try JSONDecoder().decode([Event].self, from: Data(#"[{"seq":2,"kind":"tool"},{"seq":3,"kind":"result","costUsd":0.5,"isError":false}]"#.utf8))
        let wrote = await cache.append(first, to: "transcript:s/1")
        XCTAssertTrue(wrote)
        // A write cut short must cost only its own line.
        let handle = try FileHandle(forWritingTo: try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first))
        try handle.seekToEnd(); try handle.write(contentsOf: Data("\n{\"seq\":9,\"kin".utf8)); try handle.close()
        await cache.append(second, to: "transcript:s/1")
        var transcript = Transcript()
        transcript.append(await cache.lines("transcript:s/1"))
        XCTAssertEqual(transcript.events.map(\.seq), [1, 2, 3]); XCTAssertEqual(transcript.cursor, 3)
        XCTAssertEqual(transcript.events[0].text, "Hi\nthere"); XCTAssertEqual(transcript.events[1].summary, "ls")
        XCTAssertEqual(transcript.events[2].costUsd, 0.5)
        let timed = try JSONDecoder().decode(Event.self, from: Data(#"{"seq":4,"kind":"text","t":"2026-09-28T15:55:49.120Z","text":"Hi"}"#.utf8))
        XCTAssertEqual(timed.time.map { Int($0.timeIntervalSince1970) }, 1790610949)
        XCTAssertNil(transcript.events[2].time)
        await cache.replace(second, in: "transcript:s/1")
        let replaced: [Event] = await cache.lines("transcript:s/1")
        XCTAssertEqual(replaced.map(\.seq), [2, 3])
        await cache.remove("transcript:s/1")
        let removed: [Event] = await cache.lines("transcript:s/1")
        XCTAssertTrue(removed.isEmpty)
    }
    func testCacheKeepsValuesPerKeyInsideItsDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = DiskCache(directory: directory)
        let sessions = try JSONDecoder().decode([Session].self, from: Data(#"[{"id":"a","status":"running","title":"One","reviewLoop":{"triage":{"findings":[{"key":"k"}]}},"prStatus":{"number":4},"local":false,"queued":[{"text":"next"}]}]"#.utf8))
        await cache.store(sessions, for: "sessions:o/r")
        await cache.store([Project(repo: "o/r", label: "Repo")], for: "../../projects")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names.count, 2); XCTAssertFalse(names.contains { $0.contains("/") || $0.hasPrefix(".") })
        let found: [Session]? = await cache.value("sessions:o/r")
        let restored = try XCTUnwrap(found)
        XCTAssertEqual(restored[0].title, "One"); XCTAssertTrue(restored[0].reviewLoopOn); XCTAssertTrue(restored[0].canReviewLoop)
        XCTAssertEqual(restored[0].pullNumber, 4); XCTAssertEqual(restored[0].queued?.first?["text"].string, "next")
        XCTAssertEqual(restored[0].heldTriage?["findings"].array.count, 1)
        let other: [Session]? = await cache.value("sessions:o/other")
        XCTAssertNil(other)
        let mistyped: [Session]? = await cache.value("../../projects")
        XCTAssertNil(mistyped)
        await cache.prune(olderThan: 60)
        let kept: [Project]? = await cache.value("../../projects")
        XCTAssertEqual(kept?.first?.title, "Repo")
        await cache.prune(olderThan: 60, now: Date().addingTimeInterval(3600))
        let pruned: [Project]? = await cache.value("../../projects")
        XCTAssertNil(pruned)
        await cache.store(sessions, for: "sessions:o/r")
        await cache.removeAll()
        let cleared: [Session]? = await cache.value("sessions:o/r")
        XCTAssertNil(cleared)
    }
    func testSavedPullFilesAreKeptOnlyForTheSameRevision() throws {
        func page(_ json: String) throws -> PullFilesPage { try JSONDecoder().decode(PullFilesPage.self, from: Data(json.utf8)) }
        var list = PullFileList()
        list.append(try page(#"{"pr":{"headSha":"h1","baseSha":"b1","body":"Old"},"files":[{"filename":"a"},{"filename":"b"}],"nextPage":null}"#))
        var saved = try JSONDecoder().decode(PullFileList.self, from: JSONEncoder().encode(list))
        XCTAssertEqual(saved.files.map(\.filename), ["a", "b"]); XCTAssertNil(saved.nextPage)
        XCTAssertTrue(saved.confirm(try page(#"{"pr":{"headSha":"h1","baseSha":"b1","body":"New"},"files":[{"filename":"a"}],"nextPage":2}"#)))
        XCTAssertEqual(saved.pr["body"].string, "New"); XCTAssertEqual(saved.files.count, 2); XCTAssertNil(saved.nextPage)
        XCTAssertFalse(saved.confirm(try page(#"{"pr":{"headSha":"h2","baseSha":"b1"},"files":[],"nextPage":null}"#)))
        XCTAssertFalse(saved.confirm(try page(#"{"pr":{"headSha":"h1","baseSha":"b2"},"files":[],"nextPage":null}"#)))
        var empty = PullFileList()
        XCTAssertFalse(empty.confirm(try page(#"{"pr":{},"files":[],"nextPage":null}"#)))
    }
    private func board() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"author":"TheBot","pulls":[
          {"number":7,"title":"Add invoices","branch":"feat/invoices","baseBranch":"main","draft":false,"author":"thebot","assignees":["ana"],
           "reviewers":[{"user":"Ana","state":"requested"},{"user":"luis","state":"approved"}],
           "labels":[{"name":"Has-Conflicts","color":"d93f0b"},{"name":"backend","color":"zzz"}],
           "issues":[{"number":3,"title":"Invoices","state":"closed","stateReason":"not_planned","repo":"acme/other","labels":[]}],
           "mergeable":"unknown","checks":"failure","reviewDecision":"review_required","recommended":"solve-conflicts","updatedAt":"2026-09-28T15:55:49Z"},
          {"number":8,"title":"Fix login","branch":"fix/login","author":"ana","labels":[{"name":"feedback-given","color":"fbca04"},{"name":"backend"}],
           "reviewers":[{"user":"luis","state":"commented"}],"mergeable":"conflicting","checks":"pending","updatedAt":"2026-09-28T15:55:49.120Z"},
          {"number":9,"title":"Docs","branch":"docs","author":"luis","mergeable":"mergeable"},
          {"title":"No number"}],
         "issues":[
          {"number":20,"title":"Child","author":"ana","labels":[],"parent":{"number":21,"title":"Epic","repo":"o/r"},"pulls":[{"number":8,"title":"Fix login","draft":true,"repo":"o/r"}]},
          {"number":21,"title":"Epic","labels":[{"name":"backend"}],"subIssues":{"total":3,"completed":1,"open":2}},
          {"number":22,"title":"Elsewhere","parent":{"number":21,"title":"Theirs","repo":"acme/other"}},
          {"number":23,"title":"Loop a","parent":{"number":24,"title":"Loop b"}},
          {"number":24,"title":"Loop b","parent":{"number":23,"title":"Loop a"}}]}
        """#.utf8))
    }
    func testBoardRowsReadLabelsConflictsAndWhatEachAsksFor() throws {
        let pulls = try board()["pulls"].array.compactMap(PullSummary.init)
        XCTAssertEqual(pulls.map(\.number), [7, 8, 9])
        XCTAssertEqual(pulls[0].labels.map(\.name), ["Has-Conflicts", "backend"])
        XCTAssertEqual(pulls[0].labels[0].rgb?.map { Int(($0 * 255).rounded()) }, [0xd9, 0x3f, 0x0b])
        XCTAssertNil(pulls[0].labels[1].rgb)
        // The label says so before GitHub has finished computing the merge.
        XCTAssertFalse(pulls[0].conflicting); XCTAssertTrue(pulls[0].hasConflicts); XCTAssertTrue(pulls[0].checksFailed)
        XCTAssertTrue(pulls[1].conflicting); XCTAssertTrue(pulls[1].awaitsFeedback); XCTAssertFalse(pulls[1].checksFailed)
        XCTAssertFalse(pulls[2].hasConflicts); XCTAssertNil(pulls[2].checks); XCTAssertEqual(pulls[2].labels, [])
        XCTAssertEqual(pulls[0].recommended, "solve-conflicts")
        XCTAssertEqual(pulls[0].reviewers.map(\.state), ["requested", "approved"])
        XCTAssertNotNil(pulls[0].updatedAt); XCTAssertNotNil(pulls[1].updatedAt); XCTAssertNil(pulls[2].updatedAt)
        let issue = try XCTUnwrap(pulls[0].issues.first)
        XCTAssertTrue(issue.notPlanned); XCTAssertEqual(issue.reference(in: "o/r"), "acme/other#3")
        XCTAssertEqual(pulls[0].raw["branch"].string, "feat/invoices")
    }
    func testBoardFilterCountsEachPickerAgainstTheOthers() throws {
        let pulls = try board()["pulls"].array.compactMap(PullSummary.init)
        var filter = BoardFilter(opening: "TheBot", rows: pulls)
        XCTAssertEqual(filter.author, "thebot")
        XCTAssertEqual(pulls.filter { filter.passes($0) }.map(\.number), [7])
        XCTAssertEqual(filter.options(.author, in: pulls).map { "\($0.text) \($0.count)" }, ["ana 1", "luis 1", "thebot 1"])
        XCTAssertEqual(filter.options(.label, in: pulls).map { "\($0.value) \($0.count)" }, ["backend 1", "has-conflicts 1"])
        filter[.author] = ""; filter[.label] = "Backend"
        XCTAssertEqual(pulls.filter { filter.passes($0) }.map(\.number), [7, 8])
        XCTAssertEqual(filter.options(.reviewer, in: pulls).map { "\($0.text) \($0.count)" }, ["Ana 1", "luis 2"])
        filter[.reviewer] = "ANA"
        XCTAssertEqual(pulls.filter { filter.passes($0) }.map(\.number), [7])
        // A pick the other filters have emptied still lists itself, so the board can be widened again.
        filter[.author] = "luis"
        XCTAssertEqual(pulls.filter { filter.passes($0) }.map(\.number), [])
        XCTAssertEqual(filter.options(.reviewer, in: pulls), [.init(value: "ana", text: "ana", count: 0)])
        XCTAssertTrue(filter.isOn)
        // Nobody to open on when the configured author has nothing open.
        XCTAssertFalse(BoardFilter(opening: "ghost", rows: pulls).isOn); XCTAssertFalse(BoardFilter(opening: nil, rows: pulls).isOn)
    }
    func testBoardOffersTheErrandsAPullRequestIsInAStateFor() throws {
        let pulls = try board()["pulls"].array.compactMap(PullSummary.init)
        XCTAssertEqual(BoardAction.offered(pull: pulls[0]).map(\.id),
                       ["run", "review", "solve-conflicts", "fix-checks", "custom-feedback", "pr-body-summary", "delete-self-comments"])
        XCTAssertEqual(BoardAction.offered(pull: pulls[1]).map(\.id),
                       ["run", "review", "solve-conflicts", "implement-feedback", "custom-feedback", "pr-body-summary", "delete-self-comments"])
        XCTAssertFalse(BoardAction.offered(pull: pulls[2]).contains { ["solve-conflicts", "fix-checks", "implement-feedback"].contains($0.id) })
        XCTAssertTrue(BoardAction.offered(pull: pulls[2], failedChecks: 1).contains { $0.id == "fix-checks" })
        // Off the board nothing is known about its state, so the errands that answer one stay on offer.
        XCTAssertTrue(BoardAction.offered(pull: nil).contains { $0.id == "solve-conflicts" })
        let catalog = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        [{"id":"custom-feedback","label":"Give feedback","hint":"h","input":{"label":"Tell it","placeholder":"e.g.","required":true}},
         {"id":"qa","label":"QA"},{"id":"test-sheet","label":"Test sheet"},{"id":"test-run","label":"Run test sheet"},
         {"id":"release-notes","label":"Release notes","icon":"📝","hint":"Draft them","input":null},{"label":"No id"}]
        """#.utf8)).array
        let offered = BoardAction.offered(catalog: catalog, pull: pulls[2])
        XCTAssertEqual(offered.last?.id, "release-notes"); XCTAssertEqual(offered.last?.operation, "release_notes")
        // QA and the test sheet are gone from the app, whatever the server still lists.
        XCTAssertFalse(offered.contains { ["qa", "test-sheet", "test-run"].contains($0.id) })
        let feedback = try XCTUnwrap(offered.first { $0.id == "custom-feedback" })
        XCTAssertEqual(feedback.input?.label, "Tell it")
        XCTAssertEqual(feedback.arguments(repo: "o/r", number: 9, branch: "docs", input: " Use 404 \n"),
                       ["repo": .string("o/r"), "prNumber": .number(9), "input": .string("Use 404")])
        // The board's list names the errand a row asks for, but only one that would be offered on it.
        XCTAssertEqual(BoardAction.suggested(pull: pulls[0])?.label, "Solve conflicts")
        XCTAssertNil(BoardAction.suggested(pull: pulls[1]))
        let asking = { (id: String) in try XCTUnwrap(PullSummary(.object(["number": .number(9), "mergeable": .string("mergeable"), "recommended": .string(id)]))) }
        XCTAssertNil(BoardAction.suggested(pull: try asking("solve-conflicts")))
        XCTAssertNil(BoardAction.suggested(pull: try asking("release-notes")))
        XCTAssertEqual(BoardAction.suggested(catalog: catalog, pull: try asking("release-notes"))?.label, "Release notes")
        XCTAssertNil(BoardAction.suggested(catalog: catalog, pull: try asking("test-run")))
        let known = Dictionary(uniqueKeysWithValues: BoardAction.known.map { ($0.id, $0) })
        XCTAssertEqual(known["run"]?.operation, "serve_pull"); XCTAssertEqual(known["solve-conflicts"]?.operation, "solve_conflicts")
        XCTAssertEqual(known["review"]?.arguments(repo: "o/r", number: 9, branch: "docs", input: "ignored"),
                       ["repo": .string("o/r"), "prNumber": .number(9), "branch": .string("docs")])
        XCTAssertEqual(known["run"]?.arguments(repo: "o/r", number: 9, branch: "docs"), ["repo": .string("o/r"), "prNumber": .number(9)])
    }
    func testIssuesNestUnderTheirEpicAndWordTheirOwnSession() throws {
        let issues = try board()["issues"].array.compactMap(IssueSummary.init)
        let rows = IssueSummary.nested(issues, repo: "o/r")
        // A child follows its epic; one whose epic is elsewhere, and a loop of parents, stay flat and are drawn once.
        XCTAssertEqual(rows.map { "\($0.issue.number):\($0.depth)" }, ["21:0", "20:1", "22:0", "23:0", "24:1"])
        XCTAssertTrue(issues[1].isEpic); XCTAssertEqual(issues[1].subIssuesDone, 1); XCTAssertFalse(issues[0].isEpic)
        XCTAssertEqual(issues[0].pulls.map(\.number), [8]); XCTAssertTrue(issues[0].pulls[0].draft)
        XCTAssertEqual(IssueSummary.nested(Array(issues.prefix(1)), repo: "o/r").map(\.depth), [0])
        let prompt = issues[0].prompt(repo: "o/r")
        XCTAssertTrue(prompt.hasPrefix("Issue #20: Child\n"))
        XCTAssertTrue(prompt.contains("gh issue view 20 --repo o/r --comments"))
        XCTAssertTrue(prompt.contains("sub-issue of o/r#21 (Epic)")); XCTAssertTrue(prompt.contains("`Closes #20`"))
        XCTAssertTrue(issues[2].prompt(repo: "o/r").contains("sub-issue of acme/other#21"))
        XCTAssertFalse(issues[1].prompt(repo: "o/r").contains("sub-issue of"))
    }
    func testMergeWarningsSayWhatStandsInTheWay() {
        XCTAssertEqual(MergeState.warnings(mergeable: .bool(true), state: "clean"), [])
        XCTAssertEqual(MergeState.warnings(mergeable: .bool(false), state: "dirty").count, 1)
        XCTAssertTrue(MergeState.warnings(mergeable: .null, state: "unknown")[0].contains("still checking"))
        XCTAssertTrue(MergeState.warnings(mergeable: .bool(true), state: "behind")[0].contains("behind"))
        XCTAssertTrue(MergeState.warnings(mergeable: .bool(true), state: "blocked")[0].contains("blocked"))
    }
    func testMergeIsASquashUnlessTheRepositoryRefusesIt() {
        XCTAssertEqual(MergeState.method(allowed: []), "squash")
        XCTAssertEqual(MergeState.method(allowed: ["merge", "squash", "rebase"]), "squash")
        XCTAssertEqual(MergeState.method(allowed: ["rebase", "merge"]), "merge")
        XCTAssertEqual(MergeState.method(allowed: ["rebase"]), "rebase")
        XCTAssertEqual(MergeState.title("squash"), "Squash and merge")
    }
    private func body(of request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }; data.append(buffer, count: count)
        }
        return data
    }
    func testTheCarShowsAConversationInAFewWords() throws {
        let sessions = try JSONDecoder().decode([Session].self, from: Data(#"[{"id":"a","status":"running","title":"Fix login","queued":[{"text":"x"}]},{"id":"b","status":"idle","reviewTriage":{"findings":[{"key":"k"}]}},{"id":"c","status":"closed"}]"#.utf8))
        XCTAssertEqual(sessions.map { CarText.status($0) }, ["Working · 1 queued", "Waiting for you · 1 finding", "Closed"])
        XCTAssertEqual(CarText.status(sessions[1], asking: true), "Asks you a question · 1 finding")
        XCTAssertEqual(CarText.status(sessions[0], asking: true), "Working · Asks you a question · 1 queued")
        let events = try JSONDecoder().decode([Event].self, from: Data(#"[{"seq":1,"kind":"user","text":"Go"},{"seq":2,"kind":"ask","question":"Which **one**, see [docs](https://e.com)?","options":[{"label":"Left"},{"label":"Right"}]},{"seq":3,"kind":"tool","name":"Bash"}]"#.utf8))
        XCTAssertEqual(CarText.openQuestion(events)?.seq, 2)
        XCTAssertEqual(CarText.options(events[1]), ["Left", "Right"])
        XCTAssertEqual(CarText.question(events[1]), "Which one, see docs?")
        let answered = try JSONDecoder().decode([Event].self, from: Data(#"[{"seq":1,"kind":"ask","question":"Sure?"},{"seq":2,"kind":"user","text":"Yes"},{"seq":3,"kind":"result"}]"#.utf8))
        XCTAssertNil(CarText.openQuestion(answered))
        XCTAssertEqual(CarText.inline("a_b_c and *this* and 2 * 3 * 4"), "a_b_c and this and 2 * 3 * 4")
    }
    func testTheCarShowsAPullRequestInAFewWords() throws {
        let pr = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"checks":{"passed":2,"failed":1,"pending":0,"runs":[{"name":"lint","conclusion":"failure"},{"name":"test","conclusion":"success"}]},"reviews":[{"user":"bo","state":"CHANGES_REQUESTED"},{"state":"APPROVED"}]}"#.utf8))
        XCTAssertEqual(CarText.checks(pr["checks"]), "2 passed · 1 failed · 0 running")
        XCTAssertEqual(CarText.checks(.null), "None")
        XCTAssertEqual(CarText.reviews(pr).map { "\($0.user): \($0.state)" }, ["bo: Changes requested"])
        let finding = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"title":"Leak","severity":"high","file":"src/io/file.swift"}"#.utf8))
        XCTAssertEqual(CarText.finding(finding, verdict: "Fix"), "Fix · high · file.swift")
        XCTAssertEqual(CarText.finding(.object(["fixed": .bool(true)]), verdict: "Fix"), "Fixed")
    }
    func testWhatWasDictatedIsShownWholeAndCutShorter() {
        XCTAssertEqual(CarText.title(" Fix  the\nlogin. "), "Fix the login")
        XCTAssertEqual(CarText.variants("Short"), ["“Short”"])
        let long = String(repeating: "word ", count: 40).trimmingCharacters(in: .whitespaces)
        let variants = CarText.variants(long, before: "Send “")
        XCTAssertEqual(variants.count, 3); XCTAssertEqual(variants[0], "Send “\(long)”")
        XCTAssertEqual(variants[2].count, "Send “".count + 59 + 2); XCTAssertTrue(variants[2].hasSuffix("…”"))
    }
}
