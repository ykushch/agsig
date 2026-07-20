import Foundation

/// Provenance for a paired `detection` + ANSI `visible` pane capture.
///
/// Captures are deliberately transport-level evidence: no classifier output is
/// stored here, so future parsers can always be tested against the original
/// bytes returned by herdr.
public struct PaneCaptureMetadata: Codable, Sendable, Equatable {
    public let paneID: String
    public let terminalID: String
    public let agent: String?
    public let agentStatusBefore: AgentStatus
    public let agentStatusAfter: AgentStatus
    public let paneRevisionBefore: UInt64
    public let paneRevisionAfter: UInt64
    public let herdrVersion: String?
    public let herdrProtocol: Int?
    public let capturedAt: String
    public let detectionByteCount: Int
    public let visibleANSIByteCount: Int
    public let detectionSHA256: String
    public let visibleANSISHA256: String

    public var hasConsistentRevision: Bool {
        paneRevisionBefore == paneRevisionAfter
    }

    public init(paneBefore: PaneInfo, paneAfter: PaneInfo,
                herdrVersion: String?, herdrProtocol: Int?,
                capturedAt: String, detectionByteCount: Int,
                visibleANSIByteCount: Int, detectionSHA256: String,
                visibleANSISHA256: String) {
        self.paneID = paneBefore.paneID
        self.terminalID = paneBefore.terminalID
        self.agent = paneBefore.agent
        self.agentStatusBefore = paneBefore.agentStatus
        self.agentStatusAfter = paneAfter.agentStatus
        self.paneRevisionBefore = paneBefore.revision
        self.paneRevisionAfter = paneAfter.revision
        self.herdrVersion = herdrVersion
        self.herdrProtocol = herdrProtocol
        self.capturedAt = capturedAt
        self.detectionByteCount = detectionByteCount
        self.visibleANSIByteCount = visibleANSIByteCount
        self.detectionSHA256 = detectionSHA256
        self.visibleANSISHA256 = visibleANSISHA256
    }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case terminalID = "terminal_id"
        case agent
        case agentStatusBefore = "agent_status_before"
        case agentStatusAfter = "agent_status_after"
        case paneRevisionBefore = "pane_revision_before"
        case paneRevisionAfter = "pane_revision_after"
        case herdrVersion = "herdr_version"
        case herdrProtocol = "herdr_protocol"
        case capturedAt = "captured_at"
        case detectionByteCount = "detection_byte_count"
        case visibleANSIByteCount = "visible_ansi_byte_count"
        case detectionSHA256 = "detection_sha256"
        case visibleANSISHA256 = "visible_ansi_sha256"
    }
}

public struct PaneCaptureBundle: Sendable, Equatable {
    public let metadata: PaneCaptureMetadata
    public let detectionText: String
    public let visibleANSIText: String

    public init(paneBefore: PaneInfo, paneAfter: PaneInfo, snapshot: Snapshot,
                capturedAt: String,
                detectionText: String, visibleANSIText: String) {
        let detectionData = Data(detectionText.utf8)
        let visibleANSIData = Data(visibleANSIText.utf8)
        self.detectionText = detectionText
        self.visibleANSIText = visibleANSIText
        self.metadata = PaneCaptureMetadata(
            paneBefore: paneBefore,
            paneAfter: paneAfter,
            herdrVersion: snapshot.version,
            herdrProtocol: snapshot.protocol,
            capturedAt: capturedAt,
            detectionByteCount: detectionData.count,
            visibleANSIByteCount: visibleANSIData.count,
            detectionSHA256: SHA256Digest.hex(of: detectionData),
            visibleANSISHA256: SHA256Digest.hex(of: visibleANSIData))
    }

    public init(metadata: PaneCaptureMetadata, detectionText: String,
                visibleANSIText: String) {
        self.metadata = metadata
        self.detectionText = detectionText
        self.visibleANSIText = visibleANSIText
    }
}

public enum PaneCaptureError: Error, Sendable, Equatable {
    case bundleAlreadyExists(path: String)
    case paneNotFound(paneID: String)
    case unreadablePane(paneID: String, source: ReadSource)
    case invalidBundle(reason: String)
    case fixtureAlreadyExists(path: String)
}

extension PaneCaptureBundle {
    public static func load(from directory: URL) throws -> PaneCaptureBundle {
        let detectionData = try Data(contentsOf: directory.appendingPathComponent("detection.txt"))
        let visibleData = try Data(contentsOf: directory.appendingPathComponent("visible.ansi"))
        let metadataData = try Data(contentsOf: directory.appendingPathComponent("metadata.json"))
        let metadata = try JSONDecoder().decode(PaneCaptureMetadata.self, from: metadataData)

        guard detectionData.count == metadata.detectionByteCount,
              visibleData.count == metadata.visibleANSIByteCount else {
            throw PaneCaptureError.invalidBundle(reason: "byte count mismatch")
        }
        guard SHA256Digest.hex(of: detectionData) == metadata.detectionSHA256,
              SHA256Digest.hex(of: visibleData) == metadata.visibleANSISHA256 else {
            throw PaneCaptureError.invalidBundle(reason: "SHA-256 mismatch")
        }
        guard let detectionText = String(data: detectionData, encoding: .utf8),
              let visibleANSIText = String(data: visibleData, encoding: .utf8) else {
            throw PaneCaptureError.invalidBundle(reason: "capture is not valid UTF-8")
        }
        return PaneCaptureBundle(metadata: metadata, detectionText: detectionText,
                                 visibleANSIText: visibleANSIText)
    }
}

/// Acquires both transport views and brackets them with snapshots so captures
/// that span a terminal redraw are explicitly marked by their revisions.
public struct PaneCapturer: Sendable {
    private let client: any RequestSending

    public init(client: any RequestSending) {
        self.client = client
    }

    public func capture(paneID: String, capturedAt: String) async throws -> PaneCaptureBundle {
        let snapshotBefore = try await snapshot()
        guard let paneBefore = snapshotBefore.uniquePanes.first(where: { $0.paneID == paneID }) else {
            throw PaneCaptureError.paneNotFound(paneID: paneID)
        }

        async let detection = read(paneID: paneID, source: .detection)
        async let visible = read(paneID: paneID, source: .visible,
                                 format: "ansi", stripAnsi: false)
        let (detectionText, visibleANSIText) = try await (detection, visible)

        let snapshotAfter = try await snapshot()
        guard let paneAfter = snapshotAfter.uniquePanes.first(where: { $0.paneID == paneID }) else {
            throw PaneCaptureError.paneNotFound(paneID: paneID)
        }
        return PaneCaptureBundle(paneBefore: paneBefore, paneAfter: paneAfter,
                                 snapshot: snapshotBefore, capturedAt: capturedAt,
                                 detectionText: detectionText,
                                 visibleANSIText: visibleANSIText)
    }

    private func snapshot() async throws -> Snapshot {
        let result = try await client.request("session.snapshot")
        return try (result["snapshot"] ?? result).decode(Snapshot.self)
    }

    private func read(paneID: String, source: ReadSource, format: String? = nil,
                      stripAnsi: Bool? = nil) async throws -> String {
        let params = try PaneReadParams(paneID: paneID, source: source,
                                        format: format, stripAnsi: stripAnsi).asJSONValue()
        let result = try await client.request("pane.read", params: params)
        guard let value = result["read"],
              let read = try? value.decode(PaneReadResult.self) else {
            throw PaneCaptureError.unreadablePane(paneID: paneID, source: source)
        }
        return read.text
    }
}

/// Writes a capture into one self-contained directory. The directory is built
/// under a temporary sibling and renamed only after all three files are ready,
/// avoiding a half-written fixture bundle after a failed write.
public struct PaneCaptureWriter: Sendable {
    public init() {}

    @discardableResult
    public func write(_ capture: PaneCaptureBundle, to outputDirectory: URL,
                      overwrite: Bool = false) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: outputDirectory,
                                        withIntermediateDirectories: true)

        let bundleName = Self.safeFileComponent(capture.metadata.paneID) + ".capture"
        let destination = outputDirectory.appendingPathComponent(bundleName, isDirectory: true)
        let destinationExists = fileManager.fileExists(atPath: destination.path)
        if destinationExists {
            guard overwrite else {
                throw PaneCaptureError.bundleAlreadyExists(path: destination.path)
            }
        }

        let temporary = outputDirectory.appendingPathComponent(
            ".\(bundleName).tmp-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporary,
                                        withIntermediateDirectories: false)
        do {
            try Data(capture.detectionText.utf8).write(
                to: temporary.appendingPathComponent("detection.txt"), options: .atomic)
            try Data(capture.visibleANSIText.utf8).write(
                to: temporary.appendingPathComponent("visible.ansi"), options: .atomic)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var metadata = try encoder.encode(capture.metadata)
            metadata.append(0x0A)
            try metadata.write(to: temporary.appendingPathComponent("metadata.json"),
                               options: .atomic)
            if destinationExists {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
        return destination
    }

    static func safeFileComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let mapped = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        let result = String(mapped)
        return result.isEmpty ? "pane" : result
    }
}
