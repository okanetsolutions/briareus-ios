import XCTest
@testable import BriareusMacCore

final class ConnectionTests: XCTestCase {
    func testAddress() {
        XCTAssertEqual(ServerAddress("https://Example.com/api/v1")?.baseURL, "https://example.com/api/v1/")
        XCTAssertEqual(ServerAddress("https://example.com:443/")?.origin, "https://example.com")
        XCTAssertEqual(ServerAddress("https://example.com:8443")?.origin, "https://example.com:8443")
        XCTAssertNil(ServerAddress("http://example.com"))
        XCTAssertNil(ServerAddress("https://u:p@example.com"))
        XCTAssertNil(ServerAddress("https://example.com/other"))
        XCTAssertNil(ServerAddress("https://example.com/?a=1"))
    }
    func testPreviewAccess() {
        XCTAssertTrue(previewAccessApplies(url: "https://pr-1.preview.example.com/x", hostSuffix: "preview.example.com"))
        XCTAssertFalse(previewAccessApplies(url: "https://preview.example.com/x", hostSuffix: "preview.example.com"))
        XCTAssertFalse(previewAccessApplies(url: "https://a@pr.preview.example.com", hostSuffix: "preview.example.com"))
        XCTAssertFalse(previewAccessApplies(url: "http://pr.preview.example.com", hostSuffix: "preview.example.com"))
    }
    func testRoutesAllow() {
        let routes = [Route(method: "GET", path: "/sessions/{id}", access: "read"), Route(method: "DELETE", path: "/sessions/{id}", access: "manage"),
                      Route(method: "PUT", path: "/settings/projects/order", access: "admin"), Route(method: "PUT", path: "/settings/projects/{id}", access: "manage")]
        XCTAssertTrue(Route.allow(routes, method: "GET", path: "sessions/{sessionId}", permission: "read"))
        XCTAssertFalse(Route.allow(routes, method: "DELETE", path: "sessions/{sessionId}", permission: "read"))
        XCTAssertFalse(Route.allow(routes, method: "PUT", path: "settings/projects/order", permission: "manage"))
        XCTAssertTrue(Route.allow(routes, method: "PUT", path: "settings/projects/{id}", permission: "manage"))
        XCTAssertFalse(Route.allow(routes, method: "POST", path: "sessions", permission: "admin"))
    }
    func testResolve() throws {
        let r = try APIClient.resolve(APIRoute.named("drop_message")!, ["sessionId": "a b", "index": 2, "x": true])
        XCTAssertEqual(r.path, "sessions/a%20b/queue/2")
        XCTAssertEqual(r.rest["x"], .bool(true))
        XCTAssertThrowsError(try APIClient.resolve(APIRoute.named("session")!, [:]))
    }
    func testJSON() {
        let j = JSON.parse(#"{"a":[1,true,"x",null],"b":{"c":1.5}}"#)!
        XCTAssertEqual(j["a"][1], .bool(true))
        XCTAssertEqual(j["a"][0].int, 1)
        XCTAssertEqual(j.serialized(), #"{"a":[1,true,"x",null],"b":{"c":1.5}}"#)
        XCTAssertTrue(j["b"].isSet); XCTAssertFalse(j["z"].isSet)
    }
    func testToken() {
        XCTAssertTrue(apiTokenValid("brm_" + String(repeating: "a", count: 43)))
        XCTAssertFalse(apiTokenValid("brm_short"))
    }
}
