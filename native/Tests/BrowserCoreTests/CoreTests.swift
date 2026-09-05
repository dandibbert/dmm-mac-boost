import XCTest
@testable import BrowserCore

final class CoreTests: XCTestCase {
    func testAddress() {
        XCTAssertEqual(Address.resolve("example.com/a")?.absoluteString, "https://example.com/a")
        XCTAssertEqual(Address.resolve("localhost:8080/a")?.absoluteString, "http://localhost:8080/a")
        XCTAssertEqual(Address.resolve("https://example.com:8443")?.port, 8443)
        XCTAssertEqual(Address.resolve(" hello game ")?.host, "duckduckgo.com")
        for value in ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,test", "https://user:pass@example.com", "https://", ""] { XCTAssertNil(Address.resolve(value), value) }
    }
    func testHostBoundary() {
        XCTAssertTrue(Address.isDMM(URL(string: "https://play.games.dmm.com/a")))
        XCTAssertFalse(Address.isDMM(URL(string: "https://notdmm.com/a")))
        XCTAssertFalse(Address.isDMM(URL(string: "https://dmm.com.attacker.test/a")))
    }
    func testPrivacyKey() { XCTAssertEqual(Address.pageKey(URL(string: "https://example.com/game?token=secret#password")), "example.com/game") }
    func testOriginBoundary() {
        XCTAssertEqual(Address.originKey(URL(string: "https://example.com/game")), "https://example.com:443")
        XCTAssertNotEqual(Address.originKey(URL(string: "http://example.com")), Address.originKey(URL(string: "https://example.com")))
        XCTAssertNotEqual(Address.originKey(URL(string: "https://example.com:8443")), Address.originKey(URL(string: "https://example.com")))
    }
    func testSessionRoundTrip() throws {
        let tab = TabRecord(url: "https://example.com", mode: .continuous, muted: true, autoFocus: true, pinned: true)
        let record = SessionRecord(windows: [WindowRecord(tabs: [tab], selected: tab.id)])
        let decoded = try JSONDecoder().decode(SessionRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded.windows[0].tabs, [tab]); XCTAssertEqual(decoded.windows[0].selected, tab.id)
    }
    func testProbeDoesNotDivideByZero() {
        XCTAssertEqual(ProbeSample(elapsed: 0, ticks: 4, frames: 5, largestGap: 0).framesPerSecond, 0)
        XCTAssertTrue(ProbeSample(elapsed: 60, ticks: 2, frames: 0, largestGap: 59).stalled)
        XCTAssertFalse(ProbeSample(elapsed: 60, ticks: 600, frames: 3600, largestGap: 0.1).stalled)
    }
    func testMoveForward() {
        let a = TabRecord(), b = TabRecord(), c = TabRecord()
        XCTAssertEqual(TabOrder.moving([a,b,c], id: a.id, before: c.id).map(\.id), [b.id,a.id,c.id])
    }
    func testMoveBackward() {
        let a = TabRecord(), b = TabRecord(), c = TabRecord()
        XCTAssertEqual(TabOrder.moving([a,b,c], id: c.id, before: a.id).map(\.id), [c.id,a.id,b.id])
    }
    func testMoveUnknownIsNoOp() {
        let a = TabRecord(), b = TabRecord()
        XCTAssertEqual(TabOrder.moving([a,b], id: UUID(), before: b.id), [a,b])
    }
}
