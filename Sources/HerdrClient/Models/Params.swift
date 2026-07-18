import Foundation

/// Parameters for `pane.read`.
public struct PaneReadParams: Codable, Sendable {
    public let paneID: String
    public let source: ReadSource
    public let lines: Int?
    public let format: String?
    public let stripAnsi: Bool?

    public init(paneID: String, source: ReadSource, lines: Int? = nil,
                format: String? = nil, stripAnsi: Bool? = nil) {
        self.paneID = paneID
        self.source = source
        self.lines = lines
        self.format = format
        self.stripAnsi = stripAnsi
    }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case source
        case lines
        case format
        case stripAnsi = "strip_ansi"
    }
}

/// Parameters for `pane.send_text` (free-text reply).
public struct PaneSendTextParams: Codable, Sendable {
    public let paneID: String
    public let text: String

    public init(paneID: String, text: String) {
        self.paneID = paneID
        self.text = text
    }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case text
    }
}

/// Parameters for `pane.send_keys`. **Raw keys only** — herdr rejects `prefix+`
/// bindings and invalid keys before writing.
public struct PaneSendKeysParams: Codable, Sendable {
    public let paneID: String
    public let keys: [String]

    public init(paneID: String, keys: [String]) {
        self.paneID = paneID
        self.keys = keys
    }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case keys
    }
}

/// Parameters for `pane.send_input` (text and/or keys in one call).
public struct PaneSendInputParams: Codable, Sendable {
    public let paneID: String
    public let text: String?
    public let keys: [String]?

    public init(paneID: String, text: String? = nil, keys: [String]? = nil) {
        self.paneID = paneID
        self.text = text
        self.keys = keys
    }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case text
        case keys
    }
}

/// Parameters for `pane.focus` / `tab.focus` / `workspace.focus`.
public struct FocusParams: Codable, Sendable {
    public let paneID: String

    public init(paneID: String) {
        self.paneID = paneID
    }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
    }
}

/// Parameters for `notification.show`.
public struct NotificationShowParams: Codable, Sendable {
    public let title: String
    public let body: String?
    public let position: String?
    public let sound: NotificationShowSound

    public init(title: String, body: String? = nil, position: String? = nil,
                sound: NotificationShowSound = .none) {
        self.title = title
        self.body = body
        self.position = position
        self.sound = sound
    }
}

extension Encodable {
    /// Encode a param struct into a `JSONValue` for `HerdrClient.request(params:)`.
    public func asJSONValue() throws -> JSONValue {
        let data = try JSONEncoder().encode(self)
        return try JSONValue.parse(data)
    }
}
