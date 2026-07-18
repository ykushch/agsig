import Foundation

public struct PaneFixtureAnnotations: Codable, Sendable, Equatable {
    public let name: String
    public let interactionKind: String
    public let progress: String?
    public let title: String?
    public let optionLabels: [String]
    public let optionDescriptions: [String]
    public let observedCursorIndex: Int?
    public let observedCheckedIndexes: [Int]
    public let responseMechanism: String
    public let expectedResponsePlans: [String: [String]]
    public let manifestRule: String?
    public let notes: [String]

    public init(name: String, interactionKind: String, progress: String? = nil,
                title: String? = nil, optionLabels: [String] = [],
                optionDescriptions: [String] = [], observedCursorIndex: Int? = nil,
                observedCheckedIndexes: [Int] = [], responseMechanism: String,
                expectedResponsePlans: [String: [String]] = [:],
                manifestRule: String? = nil, notes: [String] = []) {
        self.name = name
        self.interactionKind = interactionKind
        self.progress = progress
        self.title = title
        self.optionLabels = optionLabels
        self.optionDescriptions = optionDescriptions
        self.observedCursorIndex = observedCursorIndex
        self.observedCheckedIndexes = observedCheckedIndexes
        self.responseMechanism = responseMechanism
        self.expectedResponsePlans = expectedResponsePlans
        self.manifestRule = manifestRule
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case name
        case interactionKind = "interaction_kind"
        case progress
        case title
        case optionLabels = "option_labels"
        case optionDescriptions = "option_descriptions"
        case observedCursorIndex = "observed_cursor_index"
        case observedCheckedIndexes = "observed_checked_indexes"
        case responseMechanism = "response_mechanism"
        case expectedResponsePlans = "expected_response_plans"
        case manifestRule = "manifest_rule"
        case notes
    }
}

public enum PaneFixtureSanitization: String, Codable, Sendable, Equatable {
    case none
    case explicitReplacement = "explicit_replacement"
}

public struct PaneFixtureRegion: Codable, Sendable, Equatable {
    public let startMarker: String
    public let endMarker: String?

    public init(startMarker: String, endMarker: String? = nil) {
        self.startMarker = startMarker
        self.endMarker = endMarker
    }

    enum CodingKeys: String, CodingKey {
        case startMarker = "start_marker"
        case endMarker = "end_marker"
    }
}

public struct PaneFixtureMetadata: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let artifactSHA256: String
    public let sanitization: PaneFixtureSanitization
    public let region: PaneFixtureRegion?
    public let fixtureDetectionSHA256: String
    public let fixtureVisibleANSISHA256: String
    public let sourceCapture: PaneCaptureMetadata
    public let annotations: PaneFixtureAnnotations

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case artifactSHA256 = "artifact_sha256"
        case sanitization
        case region
        case fixtureDetectionSHA256 = "fixture_detection_sha256"
        case fixtureVisibleANSISHA256 = "fixture_visible_ansi_sha256"
        case sourceCapture = "source_capture"
        case annotations
    }
}

/// Converts a verified raw capture into a content-addressed fixture directory.
/// Optional replacement data is the only sanitization path and is recorded in
/// metadata; extraction never edits or normalizes terminal bytes implicitly.
public struct PaneFixtureExtractor: Sendable {
    public init() {}

    /// Verifies the files, hashes, content-addressed directory name, and the
    /// canonical artifact digest of an extracted fixture.
    public func verifyFixture(at directory: URL) throws -> PaneFixtureMetadata {
        let detection = try Data(contentsOf: directory.appendingPathComponent("detection.txt"))
        let visibleANSI = try Data(contentsOf: directory.appendingPathComponent("visible.ansi"))
        let metadataData = try Data(contentsOf: directory.appendingPathComponent("metadata.json"))
        let metadata = try JSONDecoder().decode(PaneFixtureMetadata.self, from: metadataData)
        guard metadata.schemaVersion == 1 else {
            throw PaneCaptureError.invalidBundle(reason: "unsupported fixture schema")
        }
        guard SHA256Digest.hex(of: detection) == metadata.fixtureDetectionSHA256,
              SHA256Digest.hex(of: visibleANSI) == metadata.fixtureVisibleANSISHA256 else {
            throw PaneCaptureError.invalidBundle(reason: "fixture SHA-256 mismatch")
        }
        let annotationData = try Self.canonicalJSON(metadata.annotations)
        let captureMetadataData = try Self.canonicalJSON(metadata.sourceCapture)
        let regionData = try metadata.region.map { try Self.canonicalJSON($0) }
            ?? Data("null".utf8)
        let artifactDigest = Self.artifactDigest(
            detection: detection, visibleANSI: visibleANSI,
            annotations: annotationData, captureMetadata: captureMetadataData,
            sanitization: metadata.sanitization, region: regionData)
        guard artifactDigest == metadata.artifactSHA256 else {
            throw PaneCaptureError.invalidBundle(reason: "artifact SHA-256 mismatch")
        }
        guard directory.lastPathComponent.hasSuffix(
            "-\(artifactDigest.prefix(12)).fixture") else {
            throw PaneCaptureError.invalidBundle(reason: "fixture directory is not content-addressed")
        }
        return metadata
    }

    @discardableResult
    public func extract(captureDirectory: URL, annotations: PaneFixtureAnnotations,
                        outputDirectory: URL, replacementDetection: Data? = nil,
                        replacementVisibleANSI: Data? = nil,
                        region: PaneFixtureRegion? = nil) throws -> URL {
        let capture = try PaneCaptureBundle.load(from: captureDirectory)
        let rawDetection = Data(capture.detectionText.utf8)
        let rawVisible = Data(capture.visibleANSIText.utf8)
        let sanitizationInputDetection = replacementDetection ?? rawDetection
        let sanitizationInputVisible = replacementVisibleANSI ?? rawVisible
        let fixtureDetection = try region.map {
            try Self.extractRegion(sanitizationInputDetection, $0)
        } ?? sanitizationInputDetection
        let fixtureVisible = try region.map {
            try Self.extractRegion(sanitizationInputVisible, $0)
        } ?? sanitizationInputVisible
        guard String(data: fixtureDetection, encoding: .utf8) != nil,
              String(data: fixtureVisible, encoding: .utf8) != nil else {
            throw PaneCaptureError.invalidBundle(reason: "fixture replacement is not valid UTF-8")
        }

        let sanitization: PaneFixtureSanitization =
            replacementDetection == nil && replacementVisibleANSI == nil
                ? .none : .explicitReplacement
        let annotationData = try Self.canonicalJSON(annotations)
        let captureMetadataData = try Self.canonicalJSON(capture.metadata)
        let regionData = try region.map { try Self.canonicalJSON($0) } ?? Data("null".utf8)
        let artifactDigest = Self.artifactDigest(
            detection: fixtureDetection, visibleANSI: fixtureVisible,
            annotations: annotationData, captureMetadata: captureMetadataData,
            sanitization: sanitization, region: regionData)
        let metadata = PaneFixtureMetadata(
            schemaVersion: 1,
            artifactSHA256: artifactDigest,
            sanitization: sanitization,
            region: region,
            fixtureDetectionSHA256: SHA256Digest.hex(of: fixtureDetection),
            fixtureVisibleANSISHA256: SHA256Digest.hex(of: fixtureVisible),
            sourceCapture: capture.metadata,
            annotations: annotations)
        var metadataData = try Self.canonicalJSON(metadata, prettyPrinted: true)
        metadataData.append(0x0A)

        let baseName = PaneCaptureWriter.safeFileComponent(annotations.name)
        let directoryName = "\(baseName)-\(artifactDigest.prefix(12)).fixture"
        let destination = outputDirectory.appendingPathComponent(directoryName,
                                                                 isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: outputDirectory,
                                        withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            if try Self.matches(destination: destination, detection: fixtureDetection,
                                visibleANSI: fixtureVisible, metadata: metadataData) {
                return destination
            }
            throw PaneCaptureError.fixtureAlreadyExists(path: destination.path)
        }

        let temporary = outputDirectory.appendingPathComponent(
            ".\(directoryName).tmp-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: false)
        do {
            try fixtureDetection.write(to: temporary.appendingPathComponent("detection.txt"),
                                       options: .atomic)
            try fixtureVisible.write(to: temporary.appendingPathComponent("visible.ansi"),
                                     options: .atomic)
            try metadataData.write(to: temporary.appendingPathComponent("metadata.json"),
                                   options: .atomic)
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
        return destination
    }

    private static func canonicalJSON<T: Encodable>(_ value: T,
                                                     prettyPrinted: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func artifactDigest(detection: Data, visibleANSI: Data,
                                       annotations: Data, captureMetadata: Data,
                                       sanitization: PaneFixtureSanitization,
                                       region: Data) -> String {
        var input = Data("notchagent-fixture-v1\0".utf8)
        for component in [detection, visibleANSI, annotations, captureMetadata, region,
                          Data(sanitization.rawValue.utf8)] {
            var size = UInt64(component.count).bigEndian
            withUnsafeBytes(of: &size) { input.append(contentsOf: $0) }
            input.append(component)
        }
        return SHA256Digest.hex(of: input)
    }

    private static func extractRegion(_ data: Data, _ region: PaneFixtureRegion) throws -> Data {
        let startMarker = Data(region.startMarker.utf8)
        guard let markerRange = data.range(of: startMarker, options: .backwards) else {
            throw PaneCaptureError.invalidBundle(
                reason: "start marker not found: \(region.startMarker)")
        }
        let prefix = data[..<markerRange.lowerBound]
        let lineStart = prefix.lastIndex(of: 0x0A).map { data.index(after: $0) }
            ?? data.startIndex
        guard let endMarker = region.endMarker else {
            return Data(data[lineStart...])
        }
        let endMarkerData = Data(endMarker.utf8)
        guard let endRange = data.range(of: endMarkerData,
                                        in: markerRange.lowerBound..<data.endIndex) else {
            throw PaneCaptureError.invalidBundle(reason: "end marker not found: \(endMarker)")
        }
        let lineEnd = data[endRange.upperBound...].firstIndex(of: 0x0A)
            .map { data.index(after: $0) } ?? data.endIndex
        return Data(data[lineStart..<lineEnd])
    }

    private static func matches(destination: URL, detection: Data, visibleANSI: Data,
                                metadata: Data) throws -> Bool {
        try Data(contentsOf: destination.appendingPathComponent("detection.txt")) == detection
            && Data(contentsOf: destination.appendingPathComponent("visible.ansi")) == visibleANSI
            && Data(contentsOf: destination.appendingPathComponent("metadata.json")) == metadata
    }
}
