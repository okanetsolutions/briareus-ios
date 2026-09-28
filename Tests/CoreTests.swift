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
    func testSetupEventsAreHidden() throws {
        let data = Data(#"[{"seq":1,"kind":"setup","text":"Installing dependencies"},{"seq":2,"kind":"text","text":"Done"}]"#.utf8)
        let events = try JSONDecoder().decode([Event].self, from: data)
        XCTAssertEqual(events.filter(\.visible).map(\.seq), [2])
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
        XCTAssertEqual(transcript.events[0].text, "Hi\nthere"); XCTAssertEqual(transcript.events[1].detail, "ls")
        XCTAssertEqual(transcript.events[2].costUsd, 0.5)
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
}
