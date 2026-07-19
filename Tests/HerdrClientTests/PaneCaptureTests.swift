import Foundation
import Testing
@testable import HerdrClient

@Suite("Pane capture bundles")
struct PaneCaptureTests {
    private func capture(detection: String = "Question?\r\n1. Yes\n",
                         visible: String = "\u{1b}[32mQuestion?\u{1b}[0m\r\n") -> PaneCaptureBundle {
        let pane = Self.pane(revision: 42)
        let snapshot = Snapshot(version: "0.7.4", protocol: 16,
                                focusedWorkspaceID: "w1", focusedTabID: "w1:t1",
                                focusedPaneID: "w1:p1", workspaces: [], tabs: [],
                                panes: [pane], agents: [])
        return PaneCaptureBundle(paneBefore: pane, paneAfter: pane,
                                 snapshot: snapshot,
                                 capturedAt: "2026-07-18T20:00:00Z",
                                 detectionText: detection, visibleANSIText: visible)
    }

    @Test("writer preserves detection and ANSI bytes and records provenance")
    func writeBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-capture-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let source = capture()
        let destination = try PaneCaptureWriter().write(source, to: root)

        #expect(destination.lastPathComponent == "w1_p2.capture")
        #expect(try Data(contentsOf: destination.appendingPathComponent("detection.txt"))
            == Data(source.detectionText.utf8))
        #expect(try Data(contentsOf: destination.appendingPathComponent("visible.ansi"))
            == Data(source.visibleANSIText.utf8))

        let metadata = try JSONDecoder().decode(
            PaneCaptureMetadata.self,
            from: Data(contentsOf: destination.appendingPathComponent("metadata.json")))
        #expect(metadata == source.metadata)
        #expect(metadata.agent == "codex")
        #expect(metadata.agentStatusBefore == .blocked)
        #expect(metadata.agentStatusAfter == .blocked)
        #expect(metadata.paneRevisionBefore == 42)
        #expect(metadata.paneRevisionAfter == 42)
        #expect(metadata.hasConsistentRevision)
        #expect(metadata.detectionByteCount == source.detectionText.utf8.count)
        #expect(metadata.visibleANSIByteCount == source.visibleANSIText.utf8.count)
        #expect(metadata.detectionSHA256 == SHA256Digest.hex(of: Data(source.detectionText.utf8)))
        #expect(metadata.visibleANSISHA256 == SHA256Digest.hex(of: Data(source.visibleANSIText.utf8)))
        #expect(try PaneCaptureBundle.load(from: destination) == source)
    }

    @Test("writer refuses to replace an existing capture unless explicitly allowed")
    func overwritePolicy() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-capture-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = PaneCaptureWriter()
        _ = try writer.write(capture(detection: "first"), to: root)

        #expect(throws: PaneCaptureError.self) {
            try writer.write(capture(detection: "second"), to: root)
        }

        let destination = try writer.write(capture(detection: "second"), to: root,
                                           overwrite: true)
        #expect(try String(contentsOf: destination.appendingPathComponent("detection.txt"),
                           encoding: .utf8) == "second")
    }

    @Test("pane IDs become safe single path components")
    func safeName() {
        #expect(PaneCaptureWriter.safeFileComponent("w1:p2") == "w1_p2")
        #expect(PaneCaptureWriter.safeFileComponent("../../pane") == ".._.._pane")
    }

    @Test("capturer reads both transport views and brackets them with revisions")
    func acquireBundle() async throws {
        let client = CaptureClient(before: Self.snapshot(revision: 41),
                                   after: Self.snapshot(revision: 42))
        let capture = try await PaneCapturer(client: client).capture(
            paneID: "w1:p2", capturedAt: "2026-07-18T20:00:00Z")

        #expect(capture.detectionText == "detection bytes")
        #expect(capture.visibleANSIText == "\u{1b}[32mvisible bytes\u{1b}[0m")
        #expect(capture.metadata.paneRevisionBefore == 41)
        #expect(capture.metadata.paneRevisionAfter == 42)
        #expect(!capture.metadata.hasConsistentRevision)

        let reads = await client.recordedReads()
        #expect(reads.count == 2)
        let detection = reads.first { $0["source"]?.stringValue == "detection" }
        #expect(detection?["format"] == nil)
        let visible = reads.first { $0["source"]?.stringValue == "visible" }
        #expect(visible?["format"]?.stringValue == "ansi")
        #expect(visible?["strip_ansi"]?.boolValue == false)
    }

    @Test("SHA-256 matches standard vectors")
    func sha256Vectors() {
        #expect(SHA256Digest.hex(of: Data())
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(SHA256Digest.hex(of: Data("abc".utf8))
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("bundle loader rejects byte-preserving tampering by digest")
    func tamperedBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-capture-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = try PaneCaptureWriter().write(capture(detection: "first"), to: root)
        try Data("other".utf8).write(to: destination.appendingPathComponent("detection.txt"))

        #expect(throws: PaneCaptureError.self) {
            try PaneCaptureBundle.load(from: destination)
        }
    }

    @Test("extraction is deterministic, content-addressed, and idempotent")
    func deterministicExtraction() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-capture-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("raw")
        let fixtures = root.appendingPathComponent("fixtures")
        let captureDirectory = try PaneCaptureWriter().write(capture(), to: raw)
        let annotations = PaneFixtureAnnotations(
            name: "codex single/select", interactionKind: "question",
            progress: "Question 1/3", title: "Choose one",
            optionLabels: ["One", "Two", "Three"], observedCursorIndex: 0,
            responseMechanism: "arrow_navigate",
            expectedResponsePlans: ["option_3": ["down", "down", "enter"]],
            manifestRule: "live_strong_blocker")
        let extractor = PaneFixtureExtractor()

        let first = try extractor.extract(captureDirectory: captureDirectory,
                                          annotations: annotations,
                                          outputDirectory: fixtures)
        let second = try extractor.extract(captureDirectory: captureDirectory,
                                           annotations: annotations,
                                           outputDirectory: fixtures)
        #expect(first == second)
        #expect(first.lastPathComponent.hasPrefix("codex_single_select-"))
        #expect(first.lastPathComponent.hasSuffix(".fixture"))

        let metadataData = try Data(contentsOf: first.appendingPathComponent("metadata.json"))
        let metadata = try JSONDecoder().decode(PaneFixtureMetadata.self, from: metadataData)
        #expect(metadata.schemaVersion == 1)
        #expect(metadata.sanitization == .none)
        #expect(metadata.annotations == annotations)
        #expect(metadata.fixtureDetectionSHA256 == capture().metadata.detectionSHA256)
        #expect(metadata.artifactSHA256.count == 64)
        #expect(first.lastPathComponent.contains(String(metadata.artifactSHA256.prefix(12))))
    }

    @Test("explicit sanitization changes fixture bytes, digest, and provenance")
    func explicitSanitization() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-capture-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let captureDirectory = try PaneCaptureWriter().write(capture(), to: root)
        let annotations = PaneFixtureAnnotations(
            name: "redacted", interactionKind: "question",
            responseMechanism: "arrow_navigate")
        let replacement = Data("[REDACTED]\n".utf8)
        let destination = try PaneFixtureExtractor().extract(
            captureDirectory: captureDirectory, annotations: annotations,
            outputDirectory: root.appendingPathComponent("fixtures"),
            replacementDetection: replacement)
        let metadata = try JSONDecoder().decode(
            PaneFixtureMetadata.self,
            from: Data(contentsOf: destination.appendingPathComponent("metadata.json")))

        #expect(metadata.sanitization == .explicitReplacement)
        #expect(metadata.fixtureDetectionSHA256 == SHA256Digest.hex(of: replacement))
        #expect(metadata.fixtureDetectionSHA256 != metadata.sourceCapture.detectionSHA256)
        #expect(try Data(contentsOf: destination.appendingPathComponent("detection.txt"))
            == replacement)
    }

    @Test("active-region extraction uses the last marker and preserves line bytes")
    func activeRegionExtraction() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-capture-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let detection = "old Question 1/3\nold footer\n  Question 1/3\n  Choice\nfooter\ntrailing\n"
        let visible = "old Question 1/3\r\n\u{1b}[2mold footer\u{1b}[0m\r\n"
            + "\u{1b}[48;2;1;2;3m  Question 1/3  \u{1b}[0m\r\n"
            + "\u{1b}[1m  Choice\u{1b}[0m\r\n\u{1b}[2mfooter\u{1b}[0m\r\ntrailing\r\n"
        let captureDirectory = try PaneCaptureWriter().write(
            capture(detection: detection, visible: visible), to: root)
        let annotations = PaneFixtureAnnotations(
            name: "region", interactionKind: "question",
            responseMechanism: "arrow_navigate")
        let region = PaneFixtureRegion(startMarker: "Question 1/3", endMarker: "footer")
        let destination = try PaneFixtureExtractor().extract(
            captureDirectory: captureDirectory, annotations: annotations,
            outputDirectory: root.appendingPathComponent("fixtures"), region: region)

        let extractedDetection = try String(
            contentsOf: destination.appendingPathComponent("detection.txt"), encoding: .utf8)
        let extractedVisible = try String(
            contentsOf: destination.appendingPathComponent("visible.ansi"), encoding: .utf8)
        #expect(extractedDetection == "  Question 1/3\n  Choice\nfooter\n")
        #expect(extractedVisible.hasPrefix("\u{1b}[48;2;1;2;3m  Question 1/3"))
        #expect(extractedVisible.hasSuffix("\u{1b}[2mfooter\u{1b}[0m\r\n"))
        #expect(!extractedVisible.contains("old footer"))
        #expect(!extractedVisible.contains("trailing"))

        let metadata = try JSONDecoder().decode(
            PaneFixtureMetadata.self,
            from: Data(contentsOf: destination.appendingPathComponent("metadata.json")))
        #expect(metadata.region == region)
        #expect(metadata.sanitization == .none)
    }

    @Test("committed Codex interaction corpus verifies provenance and M0C gates")
    func committedCodexCorpus() throws {
        let root = Fixtures.url("interactions")
        let directories = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "fixture" }
        #expect(directories.count == 14)

        let extractor = PaneFixtureExtractor()
        var metadataByName: [String: PaneFixtureMetadata] = [:]
        for directory in directories {
            let metadata = try extractor.verifyFixture(at: directory)
            metadataByName[metadata.annotations.name] = metadata
            #expect(metadata.sourceCapture.agent == "codex")
            #expect(metadata.sourceCapture.herdrVersion == "0.7.4")
            #expect(metadata.sourceCapture.herdrProtocol == 16)
            #expect(metadata.annotations.manifestRule.map {
                ["osc_title_blocked + live_strong_blocker",
                 "resolved_live_approval_evidence"].contains($0)
            } == true)
            let detection = try String(
                contentsOf: directory.appendingPathComponent("detection.txt"),
                encoding: .utf8)
            #expect(!detection.contains("ask me three questions interactively"))
            #expect(!detection.contains("For fixture capture only"))
        }

        let interactive = metadataByName.values.filter {
            $0.annotations.interactionKind != "none"
        }
        #expect(interactive.allSatisfy {
            $0.sourceCapture.agentStatusBefore == .blocked
                && $0.sourceCapture.agentStatusAfter == .blocked
        })
        #expect(interactive.allSatisfy { !$0.annotations.expectedResponsePlans.isEmpty })

        let first = try #require(metadataByName["codex-plan-single-select-q1"])
        let middle = try #require(metadataByName["codex-plan-single-select-q1-cursor2"])
        let last = try #require(metadataByName["codex-plan-single-select-q1-cursor4"])
        #expect(first.annotations.observedCursorIndex == 0)
        #expect(middle.annotations.observedCursorIndex == 1)
        #expect(last.annotations.observedCursorIndex == 3)
        #expect(Set([first.sourceCapture.paneRevisionBefore,
                     middle.sourceCapture.paneRevisionBefore,
                     last.sourceCapture.paneRevisionBefore]).count == 3)
        #expect(last.annotations.expectedResponsePlans["option_1"]
            == ["up", "up", "up", "enter"])

        #expect(ScreenAdapterRegistry.standard.adapterID(
            for: first.sourceCapture.agent) == "codex-screen")
        let routed = PromptClassifier().classifyInteraction(
            paneID: first.sourceCapture.paneID,
            agent: first.sourceCapture.agent,
            text: Fixtures.string("interactions/codex-plan-single-select-q1-df1ba0216047.fixture/detection.txt"),
            paneRevision: first.sourceCapture.paneRevisionBefore)
        #expect(routed.kind == .question)
        #expect(routed.choices.map(\.label) == first.annotations.optionLabels)

        let question2 = try #require(metadataByName["codex-plan-single-select-q2"])
        let question3 = try #require(metadataByName["codex-plan-single-select-q3"])
        #expect(question2.sourceCapture.paneRevisionBefore
            != last.sourceCapture.paneRevisionBefore)
        #expect(question3.sourceCapture.paneRevisionBefore
            != question2.sourceCapture.paneRevisionBefore)
        #expect(metadataByName.values.allSatisfy {
            $0.sourceCapture.paneRevisionBefore == $0.sourceCapture.paneRevisionAfter
        })

        let resolved = try #require(metadataByName["codex-plan-resolved-done"])
        #expect(resolved.sourceCapture.agentStatusBefore == .done)
        #expect(resolved.sourceCapture.agentStatusAfter == .done)
        #expect(resolved.sourceCapture.paneRevisionBefore
            != question3.sourceCapture.paneRevisionBefore)

        let approval = try #require(
            metadataByName["codex-command-approval-explicit-shortcuts"])
        #expect(approval.sanitization == .none)
        #expect(approval.annotations.responseMechanism == "explicit_shortcut")
        #expect(approval.annotations.expectedResponsePlans["approve_once"] == ["y"])
        #expect(approval.annotations.expectedResponsePlans["approve_persist"] == ["p"])
        #expect(approval.annotations.expectedResponsePlans["deny"] == ["esc"])
        let approvalDirectory = try #require(directories.first {
            $0.lastPathComponent.contains("codex-command-approval-explicit-shortcuts-")
        })
        #expect(!String(data: try Data(contentsOf: approvalDirectory
            .appendingPathComponent("detection.txt")), encoding: .utf8)!.contains("ykushch"))

        let once = try #require(metadataByName["codex-command-approval-y-resolved"])
        #expect(once.sourceCapture.agentStatusBefore == .done)
        let onceDirectory = try #require(directories.first {
            $0.lastPathComponent.contains("codex-command-approval-y-resolved-")
        })
        let onceText = try String(contentsOf: onceDirectory.appendingPathComponent(
            "detection.txt"), encoding: .utf8)
        #expect(onceText.contains("approved codex to run"))
        #expect(onceText.contains("this time"))

        let persisted = try #require(metadataByName["codex-command-approval-p-resolved"])
        #expect(persisted.sourceCapture.agentStatusBefore == .done)
        let persistedDirectory = try #require(directories.first {
            $0.lastPathComponent.contains("codex-command-approval-p-resolved-")
        })
        let persistedText = try String(contentsOf: persistedDirectory.appendingPathComponent(
            "detection.txt"), encoding: .utf8)
        #expect(persistedText.contains("approved codex to always run commands that start with"))
        #expect(persistedText.components(separatedBy: "• Ran sh -c").count - 1 == 2)
        #expect(!persistedText.contains("Would you like to run the following command?"))

        let multiselect = try #require(metadataByName["codex-multiselect-not-exposed"])
        #expect(multiselect.annotations.observedCheckedIndexes.isEmpty)
        #expect(multiselect.annotations.responseMechanism == "arrow_navigate")
        #expect(multiselect.annotations.notes.contains { $0.contains("not supported") })
    }

    private static func pane(revision: UInt64) -> PaneInfo {
        PaneInfo(paneID: "w1:p2", terminalID: "term-2",
                 workspaceID: "w1", tabID: "w1:t1", focused: false,
                 agentStatus: .blocked, revision: revision, agent: "codex")
    }

    private static func snapshot(revision: UInt64) -> Snapshot {
        Snapshot(version: "0.7.4", protocol: 16,
                 focusedWorkspaceID: "w1", focusedTabID: "w1:t1",
                 focusedPaneID: "w1:p1", workspaces: [], tabs: [],
                 panes: [pane(revision: revision)], agents: [])
    }
}

private actor CaptureClient: RequestSending {
    private let before: Snapshot
    private let after: Snapshot
    private var snapshotCount = 0
    private var reads: [JSONValue] = []

    init(before: Snapshot, after: Snapshot) {
        self.before = before
        self.after = after
    }

    func request(_ method: String, params: JSONValue, id: String) async throws -> JSONValue {
        switch method {
        case "session.snapshot":
            defer { snapshotCount += 1 }
            let snapshot = snapshotCount == 0 ? before : after
            return .object(["snapshot": try snapshot.asJSONValue()])
        case "pane.read":
            reads.append(params)
            let source = params["source"]?.stringValue
            let text = source == "detection"
                ? "detection bytes"
                : "\u{1b}[32mvisible bytes\u{1b}[0m"
            return .object(["read": .object(["text": .string(text)])])
        default:
            return .null
        }
    }

    func recordedReads() -> [JSONValue] { reads }
}
