import Foundation
import Testing
@testable import HerdrClient

private actor CompletionReadClient: RequestSending {
    let text: String
    private var calls: [(String, JSONValue)] = []

    init(text: String) { self.text = text }

    func request(_ method: String, params: JSONValue,
                 id: String) async throws -> JSONValue {
        calls.append((method, params))
        return .object(["read": .object([
            "pane_id": "w1:p1", "source": "recent_unwrapped", "text": .string(text),
        ])])
    }

    func recordedCalls() -> [(String, JSONValue)] { calls }
}

@Suite("Completion summary extraction")
struct CompletionSummaryTests {
    @Test("captured completed Codex interaction yields its final answer block")
    func capturedCodexSummary() {
        let text = Fixtures.string(
            "interactions/codex-plan-resolved-done-baf7af1f3cc9.fixture/detection.txt")
        #expect(CompletionSummaryExtractor.extract(from: text)
            == "Got it: - Focus: Career - Main obstacle: Unclear direction - Desired outcome: Action plan")
    }

    @Test("plain final paragraph is retained while tool-only output is refused")
    func genericAndToolOnly() {
        let generic = "tool noise\n\nImplemented authentication.\nAdded regression tests.\n\n› Next prompt"
        #expect(CompletionSummaryExtractor.extract(from: generic)
            == "Implemented authentication. Added regression tests.")

        let toolOnly = "• Ran swift test\n  └ all tests passed\n\n› Next prompt"
        #expect(CompletionSummaryExtractor.extract(from: toolOnly) == nil)
    }

    @Test("summary provider performs one bounded unwrapped tail read")
    func providerReadShape() async throws {
        let client = CompletionReadClient(
            text: "Completed the requested change.\n\n› Next prompt")
        let summary = try await ScreenCompletionSummaryProvider(
            client: client, lineLimit: 42).completionSummary(paneID: "w1:p1")
        #expect(summary == "Completed the requested change.")
        let calls = await client.recordedCalls()
        #expect(calls.count == 1)
        #expect(calls[0].0 == "pane.read")
        #expect(calls[0].1["pane_id"]?.stringValue == "w1:p1")
        #expect(calls[0].1["source"]?.stringValue == "recent_unwrapped")
        #expect(calls[0].1["lines"]?.intValue == 42)
        #expect(calls[0].1["strip_ansi"]?.boolValue == true)
    }
}
