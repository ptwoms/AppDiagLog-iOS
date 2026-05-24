import XCTest
@testable import AppDiagLog

final class RedactionEngineTests: XCTestCase {

    func testStripsQueryAndMasksIds() {
        let input = "https://api.example.com/users/12345/orders/0c8e2c70-3a0d-4f66-b8aa-45f42a2f1234?token=abc"
        let redacted = RedactionEngine.redactUrl(input)
        XCTAssertEqual(redacted, "https://api.example.com/users/{id}/orders/{id}")
    }

    func testMasksEmailsInUrls() {
        let redacted = RedactionEngine.redactUrl("https://api/verify/alice@example.com")
        XCTAssertEqual(redacted, "https://api/verify/{email}")
    }

    func testAuthHeaderValuesBecomeRedactedMarker() {
        let engine = RedactionEngine()
        let envelope = TestHelpers.makeEnvelope(props: [
            "Authorization": "Bearer abc",
            "other": "keep"
        ])
        let out = engine.redact(envelope)
        XCTAssertEqual(out.props["Authorization"], "<redacted>")
        XCTAssertEqual(out.props["other"], "keep")
    }

    func testCustomRedactorRunsLast() {
        let engine = RedactionEngine(custom: { ev in
            var p = ev.props
            p["mark"] = "custom"
            return EventEnvelope(
                seq: ev.seq, ts: ev.ts, sessionId: ev.sessionId, screen: ev.screen,
                event: ev.event, level: ev.level, props: p
            )
        })
        let out = engine.redact(TestHelpers.makeEnvelope(props: ["url": "https://x/y?z=1"]))
        XCTAssertEqual(out.props["url"], "https://x/y", "built-in URL redaction must run before custom")
        XCTAssertEqual(out.props["mark"], "custom", "custom redactor must run last")
    }

    func testFragmentIsAlsoStripped() {
        let redacted = RedactionEngine.redactUrl("https://api/path#section?x=1")
        XCTAssertEqual(redacted, "https://api/path")
    }

    func testNoOpWhenNoRedactionNeeded() {
        let engine = RedactionEngine()
        let original = TestHelpers.makeEnvelope(props: ["k": "v"])
        let out = engine.redact(original)
        XCTAssertEqual(out, original)
    }
}
