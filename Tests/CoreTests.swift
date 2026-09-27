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
    func testOptionalFieldsAndUnknownStatusesDoNotBreakDecoding() throws {
        let result = try JSONDecoder().decode(SessionResult.self, from: Data(#"{"session":{"id":"x","status":"future","title":null,"model":null,"unknown":true},"events":null}"#.utf8))
        XCTAssertEqual(result.session.displayTitle, "New conversation")
        XCTAssertFalse(result.session.isActive); XCTAssertNil(result.events)
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
